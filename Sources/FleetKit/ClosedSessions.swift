import Foundation

/// One reopenable tab, as the Mac describes it for the phone's Recently Closed section.
///
/// **Identity and label, and nothing that derives a path.** `FleetSnapshot`'s doc comment gives
/// the rule this follows: `pinnedConversationID`, `transcriptDirectory` and
/// `transcriptPath` exist to resolve files on the Mac, and shipping them would put the Mac's
/// filesystem layout on a phone's disk for no rendering benefit. The Mac keeps the whole
/// recorded `Session` and looks it up again by `id` when a reopen comes back.
///
/// `projectPath` is already public — `WireProject.path` carries it today — and is here so the
/// phone can bucket one global list into per-project menus without a second request per
/// project.
public struct WireClosedSession: Codable, Equatable, Sendable, Identifiable {
    /// The tab's id, which is what `FleetCommand.reopenClosed` names. Never the conversation
    /// id, for `WireSession.id`'s reason.
    public let id: UUID
    public let title: String
    /// `AgentID.rawValue`, carried as a plain `String` for `WireSession.agent`'s reason: a
    /// client-side enum would throw on an agent added after the client shipped.
    public let agent: String
    /// The sidebar project this tab was filed under, matched against `WireProject.path`.
    public let projectPath: String

    public init(id: UUID, title: String, agent: String, projectPath: String) {
        self.id = id
        self.title = title
        self.agent = agent
        self.projectPath = projectPath
    }
}
