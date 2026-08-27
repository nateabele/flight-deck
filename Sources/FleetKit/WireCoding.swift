import Foundation

/// The type tags that appear as `"t"` on the wire. Spelled out as a table rather than
/// derived from the case names, because a case rename must not silently become a protocol
/// break — changing a wire tag has to be a deliberate edit to this file.
enum FleetEventTag: String, Codable {
    case projectAdded = "project.added"
    case projectRemoved = "project.removed"
    case projectCollapsed = "project.collapsed"
    case projectsReordered = "projects.reordered"
    case sessionAdded = "session.added"
    case sessionRemoved = "session.removed"
    case sessionMoved = "session.moved"
    case sessionsReordered = "sessions.reordered"
    case renamed = "session.renamed"
    case activityChanged = "session.activity"
    case unreadChanged = "session.unread"
    case promptExpired = "prompt.expired"
}

extension FleetEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case t, id, at, order, title, origin, token
        case project, session, projectId
        case activity, waitingFor, subagentCount, isUnread, isCollapsed, hasBackgroundWork
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .projectAdded(let project, let at):
            try c.encode(FleetEventTag.projectAdded, forKey: .t)
            try c.encode(project, forKey: .project)
            try c.encode(at, forKey: .at)
        case .projectRemoved(let id):
            try c.encode(FleetEventTag.projectRemoved, forKey: .t)
            try c.encode(id, forKey: .id)
        case .projectCollapsed(let id, let isCollapsed):
            try c.encode(FleetEventTag.projectCollapsed, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(isCollapsed, forKey: .isCollapsed)
        case .projectsReordered(let order):
            try c.encode(FleetEventTag.projectsReordered, forKey: .t)
            try c.encode(order, forKey: .order)
        case .sessionAdded(let session, let project, let at):
            try c.encode(FleetEventTag.sessionAdded, forKey: .t)
            try c.encode(session, forKey: .session)
            try c.encode(project, forKey: .projectId)
            try c.encode(at, forKey: .at)
        case .sessionRemoved(let id):
            try c.encode(FleetEventTag.sessionRemoved, forKey: .t)
            try c.encode(id, forKey: .id)
        case .sessionMoved(let id, let project, let at):
            try c.encode(FleetEventTag.sessionMoved, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(project, forKey: .projectId)
            try c.encode(at, forKey: .at)
        case .sessionsReordered(let project, let order):
            try c.encode(FleetEventTag.sessionsReordered, forKey: .t)
            try c.encode(project, forKey: .projectId)
            try c.encode(order, forKey: .order)
        case .renamed(let id, let title, let origin):
            try c.encode(FleetEventTag.renamed, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(origin, forKey: .origin)
        case .activityChanged(let id, let activity, let waitingFor, let subagentCount,
                              let hasBackgroundWork):
            try c.encode(FleetEventTag.activityChanged, forKey: .t)
            try c.encode(id, forKey: .id)
            // `encode` not `encodeIfPresent`: an absent key and an explicit null are the
            // same to a decoder here, but a packet dump that shows `"activity": null` says
            // "no agent process" out loud, and this is the field most likely to be
            // misread as "idle".
            try c.encode(activity, forKey: .activity)
            try c.encodeIfPresent(waitingFor, forKey: .waitingFor)
            try c.encode(subagentCount, forKey: .subagentCount)
            try c.encode(hasBackgroundWork, forKey: .hasBackgroundWork)
        case .unreadChanged(let id, let isUnread):
            try c.encode(FleetEventTag.unreadChanged, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(isUnread, forKey: .isUnread)
        case .promptExpired(let id, let token):
            try c.encode(FleetEventTag.promptExpired, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(FleetEventTag.self, forKey: .t) {
        case .projectAdded:
            self = .projectAdded(try c.decode(WireProject.self, forKey: .project),
                                 at: try c.decode(Int.self, forKey: .at))
        case .projectRemoved:
            self = .projectRemoved(id: try c.decode(UUID.self, forKey: .id))
        case .projectCollapsed:
            self = .projectCollapsed(id: try c.decode(UUID.self, forKey: .id),
                                     isCollapsed: try c.decode(Bool.self, forKey: .isCollapsed))
        case .projectsReordered:
            self = .projectsReordered(order: try c.decode([UUID].self, forKey: .order))
        case .sessionAdded:
            self = .sessionAdded(try c.decode(WireSession.self, forKey: .session),
                                 project: try c.decode(UUID.self, forKey: .projectId),
                                 at: try c.decode(Int.self, forKey: .at))
        case .sessionRemoved:
            self = .sessionRemoved(id: try c.decode(UUID.self, forKey: .id))
        case .sessionMoved:
            self = .sessionMoved(id: try c.decode(UUID.self, forKey: .id),
                                 project: try c.decode(UUID.self, forKey: .projectId),
                                 at: try c.decode(Int.self, forKey: .at))
        case .sessionsReordered:
            self = .sessionsReordered(project: try c.decode(UUID.self, forKey: .projectId),
                                      order: try c.decode([UUID].self, forKey: .order))
        case .renamed:
            self = .renamed(id: try c.decode(UUID.self, forKey: .id),
                            title: try c.decode(String.self, forKey: .title),
                            origin: try c.decode(RenameOrigin.self, forKey: .origin))
        case .activityChanged:
            self = .activityChanged(
                id: try c.decode(UUID.self, forKey: .id),
                activity: try c.decodeIfPresent(String.self, forKey: .activity),
                waitingFor: try c.decodeIfPresent(String.self, forKey: .waitingFor),
                subagentCount: try c.decode(Int.self, forKey: .subagentCount),
                hasBackgroundWork: try c.decodeIfPresent(
                    Bool.self, forKey: .hasBackgroundWork) ?? false
            )
        case .unreadChanged:
            self = .unreadChanged(id: try c.decode(UUID.self, forKey: .id),
                                  isUnread: try c.decode(Bool.self, forKey: .isUnread))
        case .promptExpired:
            self = .promptExpired(id: try c.decode(UUID.self, forKey: .id),
                                  token: try c.decode(UUID.self, forKey: .token))
        }
    }
}

extension RenameOrigin: Codable {}
