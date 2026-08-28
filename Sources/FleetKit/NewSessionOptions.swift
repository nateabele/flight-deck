import Foundation

/// One row of the phone's New Session menu, as the Mac describes it.
///
/// **No account id, and no account home path.** `FleetAccountEmissionTests` asserts that
/// neither ever reaches an encoded frame, and it asserts it about the id specifically because
/// an id resolves to a home — sending one would be sending the other in two hops. So a row is
/// identified by the agent, which is already public (`WireSession.agent` is a plain `String`),
/// plus its **position among that agent's accounts**. The Mac re-resolves the menu when the tap
/// comes back and picks by that position.
///
/// The first version of this feature put these rows in `FleetSnapshot` instead, and three Mac
/// tests were right to fail. See the spec: `docs/superpowers/specs/2026-08-24-phone-new-session-menu.md`.
public struct WireNewSessionOption: Codable, Equatable, Sendable {
    /// The agent's wire id, matching `WireSession.agent`.
    public let agent: String
    /// What to call it — "Claude", "Codex" — since the phone has no agent table of its own.
    public let agentName: String
    /// This row's position among `agent`'s live accounts. Meaningful only against the list the
    /// Mac resolved at the moment it answered; see `isStale` on the command side.
    public let index: Int
    /// The account's name, or **nil for a flat row** — an agent with exactly one account, which
    /// the desktop draws as "New <Agent> Session" rather than as a submenu of one.
    public let accountName: String?
    /// Whether a plain tap would use this account. Drawn as a tick, and **only inside a
    /// submenu**: on an agent's only account it would mark a choice that was never offered.
    public let isDefault: Bool

    public init(agent: String, agentName: String, index: Int, accountName: String?, isDefault: Bool) {
        self.agent = agent
        self.agentName = agentName
        self.index = index
        self.accountName = accountName
        self.isDefault = isDefault
    }
}

/// The answer to `FleetRequest.newSessionOptions`.
///
/// **A request's answer, not fleet state.** Menu rows derive from preferences, and preferences
/// emit no fleet events — so putting them in the snapshot made it change with nothing recorded,
/// and `FleetReplicator`'s drift check failed exactly as it is meant to. Answered like a
/// transcript page instead: correlated by `cid`, nothing entering `FleetSnapshot`, and a
/// reconnect replaying precisely what it replayed before.
///
/// **An empty `options` is a real answer and means something.** It is a project every one of
/// whose agents was omitted for having no live account, and the phone greys the `+` out rather
/// than offering a row whose only possible outcome is a refusal from the far end. That is a
/// different state from never having been answered, which falls back to the project's default —
/// and is what a Mac older than this feature produces forever.
public struct WireNewSessionOptions: Codable, Equatable, Sendable {
    public let project: UUID
    public let options: [WireNewSessionOption]

    public init(project: UUID, options: [WireNewSessionOption]) {
        self.project = project
        self.options = options
    }
}
