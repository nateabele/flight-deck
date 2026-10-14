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
///
/// That narrowness is why a feature landing new mutation sites has to bring the check to
/// them rather than assume it is already there. Agent accounts is the worked example:
/// signing in, refusing a launch, restoring a tab whose login was deleted, and tearing down
/// a per-account watcher are all new ways `repos`/`statuses` move, and none of the account
/// suites attach a replicator — `FleetAccountEmissionTests` exists solely to run those four
/// paths under this check.
@MainActor
final class FleetReplicator: FleetRecording {
    typealias Resume = FleetEventLog.Resume

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let project: @MainActor () -> FleetSnapshot
    /// The ring, the mirror and the sequence. A value, so `FleetService` can hand the socket
    /// queue a copy and keep it in step batch by batch — see `onResync`.
    private(set) var log: FleetEventLog

    var seq: Int { log.seq }

    #if DEBUG
    /// Every event recorded so far, for tests that assert the emission itself rather than
    /// its effect. Unbounded, unlike `ring` — a test wants the whole history of the mutation
    /// it just performed, and a test's fleet does not run for hours. DEBUG-only: nothing in
    /// the app has any business reading the log back.
    private(set) var recorded: [FleetEvent] = []
    #endif

    /// Delivered to every attached client. Set by `FleetService` (Task 12).
    var onEvents: (([SequencedEvent]) -> Void)?

    /// The log was replaced rather than appended to: `reset()`, or the drift check
    /// resynchronising the mirror. Anyone holding a copy of `log` must take this one, because
    /// replaying `onEvents` batches onto the old copy no longer reproduces it.
    var onResync: ((FleetEventLog) -> Void)?

    /// Called when the mirror and a fresh projection disagree — i.e. a mutation happened
    /// without its event. `nil` means "trap", which is what a DEBUG build wants; the tests
    /// that prove this net actually fires install a spy instead, because an
    /// `assertionFailure` would take the runner down with it.
    var onDrift: ((_ mirrored: FleetSnapshot, _ actual: FleetSnapshot) -> Void)?

    init(capacity: Int = 4096, project: @escaping @MainActor () -> FleetSnapshot) {
        self.project = project
        self.log = FleetEventLog(capacity: capacity, mirror: project())
    }

    func record(_ events: [FleetEvent]) {
        guard !events.isEmpty else { return }
        #if DEBUG
        recorded.append(contentsOf: events)
        #endif
        let batch = log.append(events)
        checkForDrift()
        onEvents?(batch)
    }

    func snapshot() -> (seq: Int, fleet: FleetSnapshot) { log.snapshot() }

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
        log.reset(mirror: project())
        onResync?(log)
    }

    func resume(from lastSeq: Int) -> Resume { log.resume(from: lastSeq) }

    private func checkForDrift() {
        #if DEBUG
        let actual = project()
        guard actual != log.mirror else { return }
        Self.logger.error(
            "fleet event log drifted from the store — a mutation recorded no event"
        )
        if let onDrift {
            onDrift(log.mirror, actual)
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
        log.mirror = actual
        onResync?(log)
        #endif
    }
}

/// What a client resumes from: the folded mirror to hand out at connect time, the bounded ring
/// to replay across a gap, and the sequence. A value with no isolation of its own, so the
/// replicator keeps one on the main actor and `FleetService` keeps a copy on the socket queue
/// — a `hello` is answered there, from that copy, without waiting for the main thread.
struct FleetEventLog: Sendable {
    enum Resume: Equatable {
        case replay([SequencedEvent])
        case resnapshot(SnapshotReason)
    }

    let capacity: Int
    private(set) var ring: [SequencedEvent] = []
    var mirror: FleetSnapshot
    private(set) var seq = 0
    /// Names this run of the log, and so which run counted any given `seq`. Sent on every
    /// snapshot and echoed back in `hello` (see `ClientFrame.hello`'s `epoch`).
    ///
    /// **Why a sequence alone is not a resume point:** `seq` starts again at zero on every
    /// launch, so a phone holding seq 300 from yesterday's run, resuming against a run that
    /// has since reached 900, passes every range check `resume(from:)` makes and is replayed
    /// 301...900 — another run's events — onto yesterday's fleet. The `lastSeq <= seq` guard
    /// only catches the restart while the new run is still behind the old one. Fresh per
    /// value constructed, kept across copies and across `reset()`, which already strands
    /// every old cursor by emptying the ring.
    let epoch: String

    init(capacity: Int, mirror: FleetSnapshot, epoch: String = UUID().uuidString) {
        self.capacity = capacity
        self.mirror = mirror
        self.epoch = epoch
    }

    /// Numbers `events`, folds them into the mirror and the ring, and returns them numbered.
    mutating func append(_ events: [FleetEvent]) -> [SequencedEvent] {
        let batch = events.enumerated().map { SequencedEvent(seq: seq + 1 + $0.offset, event: $0.element) }
        apply(batch)
        return batch
    }

    /// Folds an already-numbered batch in: what a copy of the log does with the batches the
    /// original numbered. Entries at or below `seq` are skipped, because a resync can land
    /// ahead of the batch it already holds — the drift check runs before `onEvents`.
    mutating func apply(_ batch: [SequencedEvent]) {
        let fresh = batch.filter { $0.seq > seq }
        guard let last = fresh.last else { return }
        for entry in fresh { mirror.apply(entry.event) }
        seq = last.seq
        ring.append(contentsOf: fresh)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
    }

    mutating func reset(mirror: FleetSnapshot) {
        self.mirror = mirror
        ring.removeAll()
        seq += 1
    }

    func snapshot() -> (seq: Int, fleet: FleetSnapshot) { (seq, mirror) }

    /// `epoch` is the one the client claimed for `lastSeq`. `nil` — every client built before
    /// epochs, and the CLI's `--since` — keeps the old range-only judgement; a claimed epoch
    /// that is not this log's is a cursor from another run, whatever its number.
    func resume(from lastSeq: Int, epoch claimed: String? = nil) -> Resume {
        // "I have nothing" is a snapshot, not a replay of the whole ring: the ring is
        // bounded, so replaying it would silently deliver a partial fleet that looks whole.
        guard lastSeq > 0 else { return .resnapshot(.initial) }
        // `.seqTooOld` rather than a new reason: an older phone decodes `SnapshotReason`
        // strictly, and a value it has never heard of would end its socket. "Your cursor is
        // not one I can serve" is exactly what this is.
        if let claimed, claimed != epoch { return .resnapshot(.seqTooOld) }
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
}
