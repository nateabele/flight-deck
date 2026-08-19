import Foundation

extension FleetSnapshot {
    /// Fold one event in.
    ///
    /// Every lookup failure is a silent no-op, and that is a contract rather than laziness:
    /// the resume path (§4) hands a client events about ids it may never have held — a
    /// session added and closed inside a gap, or a project the client dropped on a
    /// re-snapshot. Trapping on those would turn an ordinary reconnect into a crash on the
    /// device furthest from a debugger.
    public mutating func apply(_ event: FleetEvent) {
        switch event {
        case .projectAdded(let project, let at):
            guard !projects.contains(where: { $0.id == project.id }) else { return }
            projects.insert(project, at: min(max(at, 0), projects.count))

        case .projectRemoved(let id):
            projects.removeAll { $0.id == id }

        case .projectCollapsed(let id, let isCollapsed):
            guard let p = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[p].isCollapsed = isCollapsed

        case .projectsReordered(let order):
            projects = Self.reorder(projects, by: order)

        case .sessionAdded(let session, let project, let at):
            guard let p = projects.firstIndex(where: { $0.id == project }) else { return }
            guard !projects[p].sessions.contains(where: { $0.id == session.id }) else { return }
            projects[p].sessions.insert(session, at: min(max(at, 0), projects[p].sessions.count))

        case .sessionRemoved(let id):
            for p in projects.indices { projects[p].sessions.removeAll { $0.id == id } }

        case .sessionMoved(let id, let project, let at):
            guard
                let destination = projects.firstIndex(where: { $0.id == project }),
                let found = locate(id)
            else { return }
            let session = projects[found.project].sessions.remove(at: found.session)
            let clamped = min(max(at, 0), projects[destination].sessions.count)
            projects[destination].sessions.insert(session, at: clamped)

        case .sessionsReordered(let project, let order):
            guard let p = projects.firstIndex(where: { $0.id == project }) else { return }
            projects[p].sessions = Self.reorder(projects[p].sessions, by: order)

        case .renamed(let id, let title, _):
            mutate(id) { $0.title = title }

        case .activityChanged(let id, let activity, let waitingFor, let subagentCount):
            mutate(id) {
                $0.activity = activity
                $0.waitingFor = waitingFor
                $0.subagentCount = subagentCount
            }

        case .unreadChanged(let id, let isUnread):
            mutate(id) { $0.isUnread = isUnread }
        }
    }

    public func applying(_ events: [FleetEvent]) -> FleetSnapshot {
        var copy = self
        for event in events { copy.apply(event) }
        return copy
    }

    private func locate(_ id: UUID) -> (project: Int, session: Int)? {
        for p in projects.indices {
            if let s = projects[p].sessions.firstIndex(where: { $0.id == id }) {
                return (p, s)
            }
        }
        return nil
    }

    private mutating func mutate(_ id: UUID, _ body: (inout WireSession) -> Void) {
        guard let at = locate(id) else { return }
        body(&projects[at.project].sessions[at.session])
    }

    /// Reorder by the given ids, keeping anything the order does not mention **in place at
    /// the end**. An order naming rows the client never received is the normal case across a
    /// resume gap; dropping the unmentioned rows would delete sessions nobody asked to close.
    private static func reorder<T: Identifiable>(_ items: [T], by order: [T.ID]) -> [T] {
        var remaining = items
        var result: [T] = []
        for id in order {
            guard let at = remaining.firstIndex(where: { $0.id == id }) else { continue }
            result.append(remaining.remove(at: at))
        }
        return result + remaining
    }
}
