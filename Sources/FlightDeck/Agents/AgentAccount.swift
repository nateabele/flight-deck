import Foundation
import IntakeKit

extension AgentID {
    /// The config directory the agent uses when no environment variable names one. Spelled
    /// out rather than treated as "no account": `CLAUDE_CONFIG_DIR=$HOME/.claude` is exactly
    /// equivalent to setting nothing, so making it a concrete home removes a "nil means
    /// default" branch from every watcher and every launch path.
    var builtInHome: URL {
        builtInHome(under: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    /// The built-in home below an arbitrary root — the user's home in production, a temp
    /// directory in tests. Spelled as a path RELATIVE to that root because not every agent's
    /// home is a direct child of it: OpenCode's is two levels down, and code that rebuilt a
    /// home from `builtInHome.lastPathComponent` alone put it at `~/share`.
    func builtInHome(under home: URL) -> URL {
        switch self {
        case .claude: return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:  return home.appendingPathComponent(".codex", isDirectory: true)
        // grok keeps its login, config and sessions under `$GROK_HOME`, default `~/.grok`
        // (`GrokProfile.environment`).
        case .grok:   return home.appendingPathComponent(".grok", isDirectory: true)
        // agy's own files live under `~/.gemini/antigravity-cli`, but `~/.gemini` is the
        // directory a migration seeds from (it must be a direct child of `$HOME`, see
        // `Preferences.migrateAccountsIfNeeded`). Its login is in the keyring, not here — which
        // is why gemini has exactly one account (unify brief R5).
        case .gemini: return home.appendingPathComponent(".gemini", isDirectory: true)
        // OpenCode's home is an XDG DATA ROOT, not its own dot-directory (see
        // `OpenCodeProfile.homeEnvironmentKey`): two levels down, which is why
        // `builtInHome(under:)` exists.
        case .opencode: return home.appendingPathComponent(".local/share", isDirectory: true)
        }
    }

    /// The variable that binds a process to a home, or nil for an agent that has none. Read by
    /// `AgentAdapter.environment(for:)` and `PreferencesStore.sessionEnvironment`, and nowhere
    /// else — callers name accounts, never variables. Spelled by the CLI's profile, which
    /// planning seats bind through too, so a tab and a seat on one account can never name its
    /// home differently.
    ///
    /// nil is gemini's honest answer: `agy` has no home-relocation variable and signs in through
    /// the OS keyring (`GeminiProfile.environment`), so there is nothing to bind and only its
    /// built-in account exists. Optional rather than a made-up name, which would be set on every
    /// gemini launch and bind nothing.
    var homeEnvironmentKey: String? {
        switch self {
        case .claude: return ClaudeProfile.homeEnvironmentKey
        case .codex:  return CodexProfile.homeEnvironmentKey
        case .grok:   return GrokProfile.homeEnvironmentKey
        case .gemini: return nil
        case .opencode: return OpenCodeProfile.homeEnvironmentKey
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

    /// When the user removed this account, or nil while it is live.
    ///
    /// Removal is a soft delete because a hard one moves a running tab's identity. A tab keys
    /// its status watcher and its codex stack on `resolvedAccountID`, which answers nil for an
    /// id that no longer exists — so dropping the record mid-run strands those watchers under
    /// a key nothing can match again, and the next lookup builds a SECOND codex app-server at
    /// the nil key, tailing the built-in home's `session_index.jsonl` instead of this one's.
    /// A tombstone still resolves by id, so the key never moves.
    ///
    /// Purged at launch (`Preferences.purgeRemovedAccounts`), where there are no live tabs
    /// left to protect.
    var removedAt: Date?

    /// Reads better than `removedAt != nil` at the call sites that only ask the question.
    var isRemoved: Bool { removedAt != nil }

    init(
        id: UUID = UUID(),
        agent: AgentID,
        displayName: String,
        home: URL,
        cachedIdentity: AccountIdentity? = nil,
        removedAt: Date? = nil
    ) {
        self.id = id
        self.agent = agent
        self.displayName = displayName
        self.home = home
        self.cachedIdentity = cachedIdentity
        self.removedAt = removedAt
    }

    /// Computed, never stored. A stored flag would go stale the moment a relocate moved the
    /// directory, and this predicate is what protects the account `Session.accountID == nil`
    /// resolves to from being deleted.
    var isBuiltIn: Bool { Self.key(home) == Self.key(agent.builtInHome) }

    /// The comparison key for "same home". Standardised and trailing-slash-insensitive, so
    /// `~/.claude` and `~/./.claude/` are one home — the duplicate-home rejection depends on it.
    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
