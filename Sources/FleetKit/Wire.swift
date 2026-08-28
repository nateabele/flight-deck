import Foundation

/// The whole fleet as a client sees it: the sidebar, flattened to values.
///
/// Deliberately not `[Repo]`. `Repo` and `Session` live in the app module and carry fields
/// that exist only to derive paths on the Mac — `transcriptDirectory`, `transcriptPath`,
/// `pinnedConversationID`. Shipping them would put the Mac's filesystem layout on a phone's
/// disk for no rendering benefit, and would drag the app module across a boundary FleetKit
/// exists to hold.
public struct FleetSnapshot: Codable, Equatable, Sendable {
    public var projects: [WireProject]

    public init(projects: [WireProject] = []) {
        self.projects = projects
    }

    public static let empty = FleetSnapshot()
}

public struct WireProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// The project root, shown as a subtitle and used for nothing else. A client never
    /// opens it — it has no filesystem in common with the Mac.
    public var path: String
    public var isCollapsed: Bool
    public var sessions: [WireSession]

    public init(
        id: UUID, name: String, path: String, isCollapsed: Bool = false,
        sessions: [WireSession] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isCollapsed = isCollapsed
        self.sessions = sessions
    }
}

public struct WireSession: Codable, Equatable, Sendable, Identifiable {
    /// The tab's id, which is the only stable key a client may hold. Never the conversation
    /// id: that is not stable across a re-pin and, for codex, differs from the tab id from
    /// birth.
    public let id: UUID
    public var title: String
    /// `AgentID.rawValue`, carried as a plain `String` on purpose. A client-side enum would
    /// throw on an agent added after the client shipped, taking the entire snapshot down
    /// with it; an unrecognised string just renders without a glyph.
    public var agent: String
    /// `SessionActivity.rawValue`, or `nil` for "no agent process registered".
    /// `nil` is NOT `"idle"` — a statusless tab renders nothing where an idle one renders a
    /// dot, and collapsing the two makes every dead tab look alive.
    public var activity: String?
    /// Why the session is blocked, verbatim from the agent, when `activity == "waiting"`.
    public var waitingFor: String?
    public var subagentCount: Int
    public var isUnread: Bool
    /// A background task is running under this tab's agent. Orthogonal to `activity`, not a
    /// value of it: the Mac reports `activity: "idle"` and this together for a tab sitting at
    /// its prompt with a dev server up.
    public var hasBackgroundWork: Bool

    public init(
        id: UUID, title: String, agent: String,
        activity: String? = nil, waitingFor: String? = nil,
        subagentCount: Int = 0, isUnread: Bool = false,
        hasBackgroundWork: Bool = false
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.activity = activity
        self.waitingFor = waitingFor
        self.subagentCount = subagentCount
        self.isUnread = isUnread
        self.hasBackgroundWork = hasBackgroundWork
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        agent = try c.decode(String.self, forKey: .agent)
        let decodedActivity = try c.decodeIfPresent(String.self, forKey: .activity)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        subagentCount = try c.decode(Int.self, forKey: .subagentCount)
        isUnread = try c.decode(Bool.self, forKey: .isUnread)
        // Absent from an older Mac's snapshot, and that is a meaningful value, not an error.
        let decodedBackgroundWork = try c.decodeIfPresent(
            Bool.self, forKey: .hasBackgroundWork
        ) ?? false
        // The wire version was deliberately not bumped for the `hasBackgroundWork` split, so
        // an older Mac can still send the pre-decomposition `"shell"` string here. That is
        // this skew's other direction from the `hasBackgroundWork` key being absent above:
        // rather than an error state, `"shell"` decodes to exactly what a newer Mac would
        // have sent for the same fact — `activity: "idle"` plus the flag — so an old Mac and
        // a new one render identically on this build.
        if decodedActivity == "shell" {
            activity = "idle"
            hasBackgroundWork = true
        } else {
            activity = decodedActivity
            hasBackgroundWork = decodedBackgroundWork
        }
    }
}
