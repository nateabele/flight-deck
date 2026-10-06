import Foundation
import IntakeKit

/// Folds the swarm's knowledge into an Observe snapshot before it is projected. Pure.
enum ObserveEnrichment {
    static func enrich(_ snapshot: FlywheelSnapshot, contests: [String: Contest], activity: [String: Date],
                       blocked: Set<String>) -> FlywheelSnapshot {
        var out = snapshot
        // am knows holders, not waiters; a guard block names both.
        out.reservations = snapshot.reservations?.map { reservation in
            let held = HeldReservation(pattern: reservation.file, holder: reservation.holder, since: reservation.since)
            let waiters = contests.filter { _, contest in
                contest.holder == reservation.holder && held.covers(file: contest.file)
            }.map(\.key).sorted()
            return FlywheelReadCommands.RawReservation(file: reservation.file, holder: reservation.holder,
                                                       since: reservation.since, waiters: waiters)
        }
        // Without an events lane (still a stub) every holder of a contended file read as stalled
        // and the collision trigger fired on every block. A tab's own activity is the stand-in.
        // Synthesizing events from tab activity deliberately makes the Activity lane available.
        if snapshot.events == nil, !activity.isEmpty {
            out.events = activity.sorted { $0.key < $1.key }.map {
                FlywheelReadCommands.RawEvent(agent: $0.key, kind: "activity", at: $0.value)
            }
        }
        out.declaredBlocked = blocked
        return out
    }
}
