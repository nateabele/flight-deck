import Foundation

/// Collapses a replay window to the shortest sequence with the same outcome.
///
/// Why this is on the resume path rather than an optimisation: without it, a phone that was
/// away for an hour is handed every status flap the fleet produced, which is thousands of
/// frames for a fleet that is doing its job. That is not slow-but-correct — it is the
/// difference between a gap being resumable and the server having to force a re-snapshot,
/// which is the expensive path this exists to avoid.
public enum FleetReplay {
    public static func fold(_ events: [FleetEvent]) -> [FleetEvent] {
        keptIndices(events).map { events[$0] }
    }

    /// The indices `fold` keeps, in order.
    ///
    /// Exposed as the primitive because the resume path folds events that carry sequence
    /// numbers and must not lose them (`FleetReplicator.resume(from:)`). Returning positions
    /// rather than values is what lets that caller reuse this policy instead of
    /// reimplementing it against a second type — and two copies of a fold that must agree
    /// exactly is the bug this avoids.
    public static func keptIndices(_ events: [FleetEvent]) -> [Int] {
        let doomed = subjectsRemovedInWindow(events)
        let survivors = events.indices.filter { survives(events[$0], doomed) }
        return collapseLastWriteWins(survivors, in: events)
    }

    /// A removal is the one event about a doomed subject that still matters — and only if
    /// the client had the subject before the window opened. A subject that was both created
    /// and destroyed in the gap never reached the client at all.
    private static func survives(_ event: FleetEvent, _ doomed: Doomed) -> Bool {
        if let id = event.sessionID, doomed.sessions.contains(id) {
            guard case .sessionRemoved = event else { return false }
            return !doomed.sessionsBornInWindow.contains(id)
        }
        if let id = event.projectID, doomed.projects.contains(id) {
            guard case .projectRemoved = event else { return false }
            return !doomed.projectsBornInWindow.contains(id)
        }
        return true
    }

    // MARK: Removals

    private struct Doomed {
        var sessions: Set<UUID> = []
        var projects: Set<UUID> = []
        var sessionsBornInWindow: Set<UUID> = []
        var projectsBornInWindow: Set<UUID> = []
    }

    private static func subjectsRemovedInWindow(_ events: [FleetEvent]) -> Doomed {
        var doomed = Doomed()
        for event in events {
            switch event {
            case .sessionRemoved(let id): doomed.sessions.insert(id)
            case .projectRemoved(let id): doomed.projects.insert(id)
            case .sessionAdded(let s, _, _): doomed.sessionsBornInWindow.insert(s.id)
            case .projectAdded(let p, _): doomed.projectsBornInWindow.insert(p.id)
            default: continue
            }
        }
        // A session removed and then re-added under the same id is not doomed — its final
        // state is "present". `repos` never reuses a tab id, so this is defensive rather
        // than expected, but the alternative is silently dropping a live session.
        for event in events.reversed() {
            if case .sessionAdded(let s, _, _) = event, doomed.sessions.contains(s.id) {
                if lastIndexOfRemoval(of: s.id, in: events) < lastIndexOfAdd(of: s.id, in: events) {
                    doomed.sessions.remove(s.id)
                }
            }
        }
        return doomed
    }

    private static func lastIndexOfRemoval(of id: UUID, in events: [FleetEvent]) -> Int {
        events.lastIndex { if case .sessionRemoved(let r) = $0 { return r == id }; return false } ?? -1
    }

    private static func lastIndexOfAdd(of id: UUID, in events: [FleetEvent]) -> Int {
        events.lastIndex { if case .sessionAdded(let s, _, _) = $0 { return s.id == id }; return false } ?? -1
    }

    // MARK: Last-write-wins collapsing

    /// The kinds where only the final value can matter, keyed by what they are final *for*.
    /// Anything not listed here is positional and is left exactly where it is.
    private enum FoldKey: Hashable {
        case activity(UUID), rename(UUID), unread(UUID)
        case collapsed(UUID), sessionsOrder(UUID), projectsOrder
    }

    private static func key(_ event: FleetEvent) -> FoldKey? {
        switch event {
        case .activityChanged(let id, _, _, _): return .activity(id)
        case .renamed(let id, _, _): return .rename(id)
        case .unreadChanged(let id, _): return .unread(id)
        case .projectCollapsed(let id, _): return .collapsed(id)
        case .sessionsReordered(let id, _): return .sessionsOrder(id)
        case .projectsReordered: return .projectsOrder
        default: return nil
        }
    }

    /// Walks backwards keeping the first sighting of each key — i.e. the *last* occurrence
    /// in the original order — then restores the order. Keeping the last rather than
    /// rewriting the first in place is what preserves ordering against neighbouring events:
    /// a rename that happened after a move must still be applied after it.
    private static func collapseLastWriteWins(_ indices: [Int], in events: [FleetEvent]) -> [Int] {
        var seen: Set<FoldKey> = []
        var reversed: [Int] = []
        for i in indices.reversed() {
            if let key = key(events[i]) {
                guard seen.insert(key).inserted else { continue }
            }
            reversed.append(i)
        }
        return reversed.reversed()
    }
}
