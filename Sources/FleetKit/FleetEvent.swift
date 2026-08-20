import Foundation

/// Who changed a title. Carried because the desktop and the client want it for different
/// reasons and a diff cannot supply it: a user rename and an agent's self-rename produce
/// an identical `title` field and are different facts. Slice 3 decides notification
/// eligibility from this; the timeline will show it.
public enum RenameOrigin: String, Equatable, Sendable {
    /// The user typed it, on either machine.
    case user
    /// The agent renamed its own conversation and the sidebar followed.
    case agent
}

/// One change to the fleet, as it goes on the wire.
///
/// An enum of intents rather than a diff, for the reason the spec gives in §5: a diff
/// carries the outcome and loses why it happened, and `renamed(origin:)` is the case that
/// makes that concrete. The replay ring simply *is* this log.
public enum FleetEvent: Equatable, Sendable {
    case projectAdded(WireProject, at: Int)
    case projectRemoved(id: UUID)
    case projectCollapsed(id: UUID, isCollapsed: Bool)
    case projectsReordered(order: [UUID])

    case sessionAdded(WireSession, project: UUID, at: Int)
    case sessionRemoved(id: UUID)
    case sessionMoved(id: UUID, project: UUID, at: Int)
    case sessionsReordered(project: UUID, order: [UUID])

    case renamed(id: UUID, title: String, origin: RenameOrigin)
    /// The whole status triple at once, never one field of it. `SessionStatus` is committed
    /// as a unit by `commitStatuses`, and splitting it here would let a client render a
    /// `waitingFor` string against an activity that had already moved on.
    case activityChanged(id: UUID, activity: String?, waitingFor: String?, subagentCount: Int)
    case unreadChanged(id: UUID, isUnread: Bool)
}

extension FleetEvent {
    /// The session this event is about, if any. Used by the replay fold (Task 4) to decide
    /// what a removal makes redundant.
    var sessionID: UUID? {
        switch self {
        case .sessionAdded(let s, _, _): return s.id
        case .sessionRemoved(let id), .sessionMoved(let id, _, _),
             .renamed(let id, _, _), .activityChanged(let id, _, _, _),
             .unreadChanged(let id, _):
            return id
        case .projectAdded, .projectRemoved, .projectCollapsed,
             .projectsReordered, .sessionsReordered:
            return nil
        }
    }

    /// The project this event is about, if any.
    var projectID: UUID? {
        switch self {
        case .projectAdded(let p, _): return p.id
        case .projectRemoved(let id), .projectCollapsed(let id, _),
             .sessionsReordered(let id, _):
            return id
        case .sessionAdded, .sessionRemoved, .sessionMoved, .projectsReordered,
             .renamed, .activityChanged, .unreadChanged:
            return nil
        }
    }
}
