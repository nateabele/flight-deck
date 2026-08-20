import FleetKit
import Foundation
import OSLog

/// The sink `SessionStore` reports every fleet-state change to.
///
/// A protocol, and optional on the store, for the same reason `Notifying` is: the overwhelming
/// majority of tests construct a store that has no client attached and must not be made to
/// care.
@MainActor
protocol FleetRecording: AnyObject {
    func record(_ events: [FleetEvent])
    /// The fleet was replaced wholesale rather than changed — `SessionStore.restore` is the
    /// only caller. There is no sensible event sequence for "everything is different now",
    /// so this discards the replay history and forces every client behind the current
    /// sequence to re-snapshot.
    func reset()
}

/// Turns the store's change log into something a client can follow: a mirror to hand out at
/// connect time, and a bounded ring to replay across a gap.
///
/// **The drift check is load-bearing, not diagnostics.** Until `SessionStore`'s fleet state
/// is encapsulated (specs/2026-08-18-fleet-state-encapsulation-design.md), nothing stops a
/// new mutation site from changing `repos`, `statuses` or `unreadIdle` without recording its
/// event — and the consequence is not a crash but a client that is silently and permanently
/// wrong until it reconnects. Comparing the folded mirror against a fresh projection after
/// every batch is what turns that into a test failure in any test that attaches a replicator.
/// Only the fleet test files do that, out of roughly a hundred `SessionStore(...)`
/// constructions across the suite — so a mutation is caught immediately if the code path
/// that exercises it also runs under one of those files, and not otherwise. Do not remove
/// it before the encapsulation replaces it.
@MainActor
final class FleetReplicator: FleetRecording {
    enum Resume: Equatable {
        case replay([SequencedEvent])
        case resnapshot(SnapshotReason)
    }

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let capacity: Int
    private let project: @MainActor () -> FleetSnapshot
    private var ring: [SequencedEvent] = []
    private var mirror: FleetSnapshot

    private(set) var seq = 0

    #if DEBUG
    /// Every event recorded so far, for tests that assert the emission itself rather than
    /// its effect. Unbounded, unlike `ring` — a test wants the whole history of the mutation
    /// it just performed, and a test's fleet does not run for hours. DEBUG-only: nothing in
    /// the app has any business reading the log back.
    private(set) var recorded: [FleetEvent] = []
    #endif

    /// Delivered to every attached client. Set by `FleetService` (Task 12).
    var onEvents: (([SequencedEvent]) -> Void)?

    /// Called when the mirror and a fresh projection disagree — i.e. a mutation happened
    /// without its event. `nil` means "trap", which is what a DEBUG build wants; the tests
    /// that prove this net actually fires install a spy instead, because an
    /// `assertionFailure` would take the runner down with it.
    var onDrift: ((_ mirrored: FleetSnapshot, _ actual: FleetSnapshot) -> Void)?

    init(capacity: Int = 4096, project: @escaping @MainActor () -> FleetSnapshot) {
        self.capacity = capacity
        self.project = project
        self.mirror = project()
    }

    func record(_ events: [FleetEvent]) {
        guard !events.isEmpty else { return }
        var batch: [SequencedEvent] = []
        batch.reserveCapacity(events.count)
        for event in events {
            seq += 1
            mirror.apply(event)
            #if DEBUG
            recorded.append(event)
            #endif
            batch.append(SequencedEvent(seq: seq, event: event))
        }
        ring.append(contentsOf: batch)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        checkForDrift()
        onEvents?(batch)
    }

    func snapshot() -> (seq: Int, fleet: FleetSnapshot) { (seq, mirror) }

    /// Re-read the store and throw the replay history away.
    ///
    /// The sequence still advances, and that is the load-bearing part: a client sitting on
    /// the old sequence must not be told "you are current" when the entire fleet was just
    /// replaced underneath it. Bumping past it, with an empty ring, is what routes that
    /// client to `.resnapshot` instead.
    ///
    /// Does **not** notify anyone attached right now — only a client that reconnects (and so
    /// asks `resume(from:)` again) sees the bump. Unreachable today (`restore()` runs inside
    /// `SessionStore.init`, before any service exists to be attached to), but a caller that
    /// invokes this while clients are attached must broadcast a fresh snapshot itself, or
    /// they stay silently stale until they happen to drop.
    func reset() {
        mirror = project()
        ring.removeAll()
        seq += 1
    }

    func resume(from lastSeq: Int) -> Resume {
        // "I have nothing" is a snapshot, not a replay of the whole ring: the ring is
        // bounded, so replaying it would silently deliver a partial fleet that looks whole.
        guard lastSeq > 0 else { return .resnapshot(.initial) }
        // A client claiming a sequence we have never issued has been talking to a different
        // Flight Deck — a relaunch, or a restored backup.
        guard lastSeq <= seq else { return .resnapshot(.seqTooOld) }
        guard lastSeq < seq else { return .replay([]) }
        // `floor - 1` is the newest sequence a client could have applied and still be
        // servable: the ring's first entry is the next one it needs.
        let floor = ring.first?.seq ?? (seq + 1)
        guard lastSeq >= floor - 1 else { return .resnapshot(.seqTooOld) }
        return .replay(FleetReplay.fold(ring.filter { $0.seq > lastSeq }))
    }

    private func checkForDrift() {
        #if DEBUG
        let actual = project()
        guard actual != mirror else { return }
        Self.logger.error(
            "fleet event log drifted from the store — a mutation recorded no event"
        )
        if let onDrift {
            onDrift(mirror, actual)
        } else {
            assertionFailure("""
                Fleet event log drifted from SessionStore.

                Some mutation changed repos/statuses/unreadIdle without recording its \
                FleetEvent. Every attached client is now wrong until it reconnects. Find the \
                write that has no `emit(...)` beside it — see \
                docs/superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md.
                """)
        }
        // Resynchronise so one missing line does not make every later snapshot wrong too.
        mirror = actual
        #endif
    }
}
