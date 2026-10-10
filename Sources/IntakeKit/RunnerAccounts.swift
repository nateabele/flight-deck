import Foundation

/// `<intake>/accounts.json`: which account each agent bills for this runner's life (unify brief
/// R9). The APP writes it immediately before it spawns `flightdeck intake run`, from the
/// project's assignments — leasing from a pool where the project names one — and the runner
/// only reads it. The runner is a separate process with no preferences, no Accounts list and no
/// `CapacityLedger`, so resolution cannot happen on its side; a file rather than argv because
/// the app must read it back too: after a relaunch it re-registers a live runner's leases from
/// here (`IntakeRunnerController.syncAccountLeases`), and argv is not something it can read off
/// a daemon it did not spawn this launch.
///
/// Rewritten on every spawn, never edited in place: each runner start is the rollover point,
/// where a pool's lease is taken afresh and may land on a different account.
public struct RunnerAccounts: Codable, Equatable, Sendable {
    /// One agent's billing.
    public struct Entry: Codable, Equatable, Sendable {
        /// The Accounts-list id, credited by usage attribution (`SeatActivity.accountID`). nil for
        /// an agent with no account record at all (grok/gemini on an install that never seeded
        /// one), which runs in the CLI's built-in home.
        public var accountID: UUID?
        /// The home the CLI is bound to. nil leaves the CLI's own default home in force — the
        /// built-in account, run exactly as before accounts reached planning (no home variable
        /// set), which matters for claude: binding `CLAUDE_CONFIG_DIR` to `~/.claude` explicitly
        /// changes the Keychain entry it reads its login from.
        public var home: URL?
        /// What the Rounds editor showed this agent billing ("Work pool", "Personal").
        public var label: String
        /// The pool lease this entry holds, released when the runner exits.
        public var lease: StoredLease?
        public init(accountID: UUID?, home: URL?, label: String, lease: StoredLease? = nil) {
            self.accountID = accountID; self.home = home; self.label = label; self.lease = lease
        }

        /// What a headless request binds: nil runs the built-in home.
        public var ref: AgentAccountRef? {
            home.map { AgentAccountRef(id: accountID?.uuidString ?? $0.path, home: $0) }
        }
    }

    public var agents: [AgentID: Entry]
    public init(agents: [AgentID: Entry] = [:]) { self.agents = agents }

    public static let fileName = "accounts.json"

    public static func url(in intakeDirectory: URL) -> URL {
        intakeDirectory.appendingPathComponent(fileName)
    }

    /// nil when there is no file (a runner spawned by a build before this existed) or it does
    /// not decode. The caller treats nil as "every agent on its built-in home", the behaviour
    /// such a runner always had.
    public static func load(from intakeDirectory: URL) -> RunnerAccounts? {
        guard let data = try? Data(contentsOf: url(in: intakeDirectory)) else { return nil }
        return try? IntakeJSON.decoder.decode(RunnerAccounts.self, from: data)
    }

    public func write(to intakeDirectory: URL) throws {
        try FileManager.default.createDirectory(at: intakeDirectory, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(self).write(to: Self.url(in: intakeDirectory), options: .atomic)
    }

    /// Every lease the file holds, for release or re-adoption.
    public var leases: [AccountLease] { agents.values.compactMap { $0.lease?.lease } }
}

public extension RoundConfig {
    /// Every agent any seat of this config can run — fallbacks and the cross-check reviewer
    /// included, since a fallback that fires mid-round needs its account resolved already: the
    /// runner cannot ask the app for one then.
    var agents: Set<AgentID> {
        var choices: [ModelChoice] = [integrator, encoder]
        if let polisher { choices.append(polisher) }
        for slot in drafters + [synthesizer, reviewer, crossReviewer].compactMap({ $0 }) {
            choices.append(slot.choice)
            if let fallback = slot.fallback { choices.append(fallback) }
        }
        return Set(choices.map(\.agent))
    }
}
