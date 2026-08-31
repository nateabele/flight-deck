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

    /// A removal is the only event about a doomed subject that still matters. Everything
    /// earlier is superseded by it, and everything later cannot exist.
    ///
    /// The removal is kept unconditionally, even when this window also contains the subject's
    /// creation. An earlier version dropped it in that case, reasoning that a client which
    /// never saw the subject need not hear it left — but the fold sees only events, never the
    /// snapshot, so it cannot distinguish a genesis add from a redundant add on something the
    /// client already holds, and guessing wrong left the client holding a deleted session.
    /// Applying a removal for an unknown id is a silent no-op by contract, so keeping it costs
    /// one inert frame and makes the property hold unconditionally.
    private static func survives(_ event: FleetEvent, _ doomed: Doomed) -> Bool {
        if let id = event.sessionID, doomed.sessions.contains(id) {
            guard case .sessionRemoved = event else { return false }
            return true
        }
        if let id = event.projectID, doomed.projects.contains(id) {
            guard case .projectRemoved = event else { return false }
            return true
        }
        return true
    }

    // MARK: Removals

    private struct Doomed {
        var sessions: Set<UUID> = []
        var projects: Set<UUID> = []
    }

    /// One forward pass recording, per subject, where it was last added and last removed.
    ///
    /// A subject is doomed only when its last removal comes *after* its last addition. That
    /// ordering test is what lets a remove-then-re-add under the same id survive intact:
    /// dropping both events would leave the client holding the subject's pre-window contents,
    /// which is stale data rather than a missing frame — the worse of the two failures.
    ///
    /// The symmetry between sessions and projects is load-bearing. An earlier version
    /// defended sessions only, and a project removed and re-added inside one window
    /// resurrected every session it used to hold.
    private static func subjectsRemovedInWindow(_ events: [FleetEvent]) -> Doomed {
        var lastSessionAdd: [UUID: Int] = [:], lastSessionRemove: [UUID: Int] = [:]
        var lastProjectAdd: [UUID: Int] = [:], lastProjectRemove: [UUID: Int] = [:]
        for (index, event) in events.enumerated() {
            switch event {
            case .sessionAdded(let session, _, _): lastSessionAdd[session.id] = index
            case .sessionRemoved(let id): lastSessionRemove[id] = index
            case .projectAdded(let project, _): lastProjectAdd[project.id] = index
            case .projectRemoved(let id): lastProjectRemove[id] = index
            default: continue
            }
        }

        var doomed = Doomed()
        for (id, removedAt) in lastSessionRemove where (lastSessionAdd[id] ?? -1) < removedAt {
            doomed.sessions.insert(id)
        }
        for (id, removedAt) in lastProjectRemove where (lastProjectAdd[id] ?? -1) < removedAt {
            doomed.projects.insert(id)
        }
        return doomed
    }

    // MARK: Last-write-wins collapsing

    /// The kinds where only the final value can matter, keyed by what they are final *for*.
    ///
    /// Reorders and moves are deliberately absent, and that is a correctness requirement
    /// rather than caution. `reorder` leaves any id its order does not mention "in place", so
    /// a reorder's result depends on the list it runs against — it is a state-dependent
    /// transform, not a field. Collapsing two reorders that straddle an insertion silently
    /// changes the surviving order: with [A,B], `reorder→[B,A]`, `add C at 1`, `reorder
    /// pinning only A` yields [A,B,C] raw and [A,C,B] folded. There is nothing to gain by
    /// collapsing them either — reorders are human drag gestures, while the volume this fold
    /// exists to absorb is machine-generated status flaps.
    private enum FoldKey: Hashable {
        case activity(UUID), rename(UUID), unread(UUID), collapsed(UUID), planGate(UUID)
    }

    private static func key(_ event: FleetEvent) -> FoldKey? {
        switch event {
        case .activityChanged(let id, _, _, _, _): return .activity(id)
        case .renamed(let id, _, _): return .rename(id)
        case .unreadChanged(let id, _): return .unread(id)
        case .projectCollapsed(let id, _): return .collapsed(id)
        // Same rationale as `.activity`: a gate can flap open/closed/superseded several
        // times inside one resume gap, and only the final value is real by the time a
        // reconnecting phone would see it — the intermediate frames are indistinguishable
        // from a status flap to a fold that only sees events, never a screen.
        case .planGateChanged(let id, _): return .planGate(id)
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
