import Foundation

extension AgentID {
    /// The config directory the agent uses when no environment variable names one. Spelled
    /// out rather than treated as "no account": `CLAUDE_CONFIG_DIR=$HOME/.claude` is exactly
    /// equivalent to setting nothing, so making it a concrete home removes a "nil means
    /// default" branch from every watcher and every launch path.
    var builtInHome: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch self {
        case .claude: return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:  return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    /// The variable that binds a process to a home. Read by `AgentAdapter.environment(for:)`,
    /// and nowhere else — callers name accounts, never variables.
    var homeEnvironmentKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_HOME"
        }
    }
}

/// Who an account is, read from its home. Display only, and deliberately so: a menu must not
/// touch disk, and a stale email must never affect which process is spawned.
struct AccountIdentity: Codable, Equatable, Sendable {
    var email: String?
    var organization: String?
    var readAt: Date

    init(email: String? = nil, organization: String? = nil, readAt: Date = Date()) {
        self.email = email
        self.organization = organization
        self.readAt = readAt
    }
}

/// One logged-in identity for one agent.
///
/// `id` is opaque and permanent. Renaming the label or relocating the directory never changes
/// what sessions and projects point at, which is what makes rename free and relocate a
/// one-field edit rather than a migration.
struct AgentAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var agent: AgentID
    var displayName: String
    var home: URL
    var cachedIdentity: AccountIdentity?

    init(
        id: UUID = UUID(),
        agent: AgentID,
        displayName: String,
        home: URL,
        cachedIdentity: AccountIdentity? = nil
    ) {
        self.id = id
        self.agent = agent
        self.displayName = displayName
        self.home = home
        self.cachedIdentity = cachedIdentity
    }

    /// Computed, never stored. A stored flag would go stale the moment a relocate moved the
    /// directory, and this predicate is what protects the account `Session.accountID == nil`
    /// resolves to from being deleted.
    var isBuiltIn: Bool { Self.key(home) == Self.key(agent.builtInHome) }

    /// The comparison key for "same home". Standardised and trailing-slash-insensitive, so
    /// `~/.claude` and `~/./.claude/` are one home — the duplicate-home rejection depends on it.
    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
