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

        case .promptExpired:
            // Nothing. The snapshot describes the fleet — projects, sessions, their status —
            // and a prompt that timed out changes none of that. It is addressed to one
            // screen's outbox, which is not snapshot state and is deliberately not replayed:
            // a reconnect that re-folded this would re-fail a row the reader had already
            // dismissed, or one whose message they had since re-sent successfully.
            return

        case .sessionsReordered(let project, let order):
            guard let p = projects.firstIndex(where: { $0.id == project }) else { return }
            projects[p].sessions = Self.reorder(projects[p].sessions, by: order)

        case .renamed(let id, let title, _):
            mutate(id) { $0.title = title }

        case .activityChanged(let id, let activity, let waitingFor, let subagentCount,
                              let hasBackgroundWork, let openPromptCall):
            // The wire version was deliberately not bumped for the `hasBackgroundWork`
            // split, so an older Mac can still send the pre-decomposition `"shell"` string
            // here, on the incremental path rather than a fresh snapshot. Same
            // normalization `WireSession.init(from:)` applies on decode, so an old Mac's
            // live update renders identically to its full snapshot rather than falling
            // through to "Unrecognized status".
            let isLegacyShell = activity == "shell"
            mutate(id) {
                $0.activity = isLegacyShell ? "idle" : activity
                $0.waitingFor = waitingFor
                $0.subagentCount = subagentCount
                $0.hasBackgroundWork = isLegacyShell ? true : hasBackgroundWork
                // Overwritten unconditionally, including with `.unreported`. An older Mac
                // sends that in its snapshot too, so a fold that preserved the previous value
                // would let one build's assertion survive into a stream that has stopped
                // making it — a client left holding a call id nothing will ever retire.
                $0.openPromptCall = openPromptCall
            }

        case .unreadChanged(let id, let isUnread):
            mutate(id) { $0.isUnread = isUnread }

        case .apiErrorChanged(let id, let error):
            mutate(id) { $0.apiError = error }

        case .planGateChanged(let id, let gate):
            mutate(id) { $0.planGate = gate }
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
