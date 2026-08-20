import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetReplicatorTests: XCTestCase {
    private let projectID = UUID()
    private let sessionID = UUID()

    /// The replicator is driven against a closure, not a store, so these tests describe the
    /// ring and the mirror without standing up surfaces or processes. The store-level
    /// coupling is Tasks 9 and 10's subject.
    private func makeReplicator(
        capacity: Int = 4096, truth: @escaping @MainActor () -> FleetSnapshot
    ) -> FleetReplicator {
        FleetReplicator(capacity: capacity, project: truth)
    }

    private func session(_ id: UUID, _ title: String = "s") -> WireSession {
        WireSession(id: id, title: title, agent: "claude")
    }

    private func fleet(titled title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd",
                        sessions: [session(sessionID, title)])
        ])
    }

    // MARK: Sequencing and the mirror

    func testSequenceNumbersAdvanceOncePerEventNotOncePerBatch() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "c")
        replicator.record([
            .renamed(id: sessionID, title: "b", origin: .user),
            .renamed(id: sessionID, title: "c", origin: .user)
        ])
        XCTAssertEqual(replicator.seq, 2)
    }

    func testTheSnapshotIsTheFoldedMirrorNotAReprojection() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(replicator.snapshot().fleet, fleet(titled: "b"))
        XCTAssertEqual(replicator.snapshot().seq, 1)
    }

    func testRecordingNothingChangesNothing() {
        let replicator = makeReplicator { .empty }
        replicator.record([])
        XCTAssertEqual(replicator.seq, 0)
    }

    func testSubscribersSeeEachBatchWithItsSequenceNumbers() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        var delivered: [SequencedEvent] = []
        replicator.onEvents = { delivered.append(contentsOf: $0) }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(delivered.map(\.seq), [1])
    }

    // MARK: Resume

    func testAClientAlreadyCurrentGetsAnEmptyReplay() {
        let replicator = makeReplicator { .empty }
        XCTAssertEqual(replicator.resume(from: 0), .resnapshot(.initial))
        var truth = fleet(titled: "a")
        let live = makeReplicator { truth }
        truth = fleet(titled: "b")
        live.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(live.resume(from: 1), .replay([]))
    }

    /// `lastSeq == 0` is "I have nothing", which is a snapshot rather than a replay of the
    /// whole ring — the ring is bounded and would silently under-deliver.
    func testAClientWithNothingIsSnapshotted() {
        XCTAssertEqual(makeReplicator { .empty }.resume(from: 0), .resnapshot(.initial))
    }

    func testAGapInsideTheRingIsReplayedWithItsOriginalSequenceNumbers() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        truth = FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd", sessions: [])
        ])
        replicator.record([.sessionRemoved(id: sessionID)])
        guard case .replay(let events) = replicator.resume(from: 1) else {
            return XCTFail("a gap inside the ring must replay")
        }
        XCTAssertEqual(events, [SequencedEvent(seq: 2, event: .sessionRemoved(id: sessionID))])
    }

    /// The replay is folded, which is what makes an hour offline resumable at all. Fifty
    /// flaps must arrive as one frame, still carrying a real sequence number.
    func testAReplayIsFoldedAndKeepsTheSurvivingEventsSequence() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        for i in 0..<50 {
            // Kept in sync with the mirror so this loop exercises fold/resume mechanics
            // only, and does not also trip the drift check it is not testing.
            let event = FleetEvent.activityChanged(
                id: sessionID, activity: i.isMultiple(of: 2) ? "busy" : "idle",
                waitingFor: nil, subagentCount: 0
            )
            truth.apply(event)
            replicator.record([event])
        }
        guard case .replay(let events) = replicator.resume(from: 0 + 1) else {
            return XCTFail("expected a replay")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.seq, 50)
    }

    /// A client asking from before the ring's floor cannot be served, and must be told so
    /// rather than quietly resumed from wherever the ring happens to start — that is how a
    /// phone ends up confidently displaying a fleet that no longer exists.
    func testAGapOlderThanTheRingForcesAReSnapshot() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator(capacity: 4) { truth }
        for i in 0..<10 {
            // Kept in sync with the mirror; see the comment in the fold test above.
            let event = FleetEvent.renamed(id: sessionID, title: "t\(i)", origin: .user)
            truth.apply(event)
            replicator.record([event])
        }
        XCTAssertEqual(replicator.resume(from: 1), .resnapshot(.seqTooOld))
    }

    /// A client that claims a sequence the Mac has never issued has been talking to a
    /// different Flight Deck — a relaunch, or a restored backup. Snapshot it.
    func testAClientFromTheFutureIsSnapshotted() {
        XCTAssertEqual(makeReplicator { .empty }.resume(from: 99), .resnapshot(.seqTooOld))
    }

    func testTheRingIsBounded() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator(capacity: 4) { truth }
        for i in 0..<100 {
            // Kept in sync with the mirror; see the comment in the fold test above.
            let event = FleetEvent.renamed(id: sessionID, title: "t\(i)", origin: .user)
            truth.apply(event)
            replicator.record([event])
        }
        guard case .replay(let events) = replicator.resume(from: 99) else {
            return XCTFail("the newest events must still be replayable")
        }
        XCTAssertEqual(events.map(\.seq), [100])
    }

    /// After a wholesale restore there is no event sequence that describes what happened,
    /// so a client on the old sequence must be sent back for a snapshot rather than told it
    /// is current.
    func testAResetSendsEveryTrailingClientBackForASnapshot() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        truth = FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "restored", path: "/w/restored")
        ])
        replicator.reset()
        XCTAssertEqual(replicator.snapshot().fleet, truth)
        XCTAssertEqual(replicator.resume(from: 1), .resnapshot(.seqTooOld))
    }

    // MARK: Drift — the safety net itself

    /// The failure this whole mechanism exists to catch: a mutation happened, and whoever
    /// wrote it forgot to record its event. The mirror and the store disagree, and every
    /// connected client is now permanently wrong.
    func testAMutationWithNoEventIsReportedAsDrift() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        var drifts: [(FleetSnapshot, FleetSnapshot)] = []
        replicator.onDrift = { drifts.append(($0, $1)) }

        // The store moved on — a rename happened — but the event recorded alongside it was
        // about something else entirely.
        truth = fleet(titled: "renamed-but-unreported")
        replicator.record([.unreadChanged(id: sessionID, isUnread: true)])

        XCTAssertEqual(drifts.count, 1)
        XCTAssertEqual(drifts.first?.1, truth, "drift must report the store's actual state")
    }

    func testAFaithfulRecordingReportsNoDrift() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        var drifted = false
        replicator.onDrift = { _, _ in drifted = true }
        truth = fleet(titled: "b")
        replicator.record([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertFalse(drifted)
    }

    /// After reporting, the mirror resynchronises. A replicator that kept serving a mirror
    /// it already knows is wrong would turn one missing line into every subsequent snapshot
    /// being wrong too.
    func testTheMirrorResynchronisesAfterDrift() {
        var truth = fleet(titled: "a")
        let replicator = makeReplicator { truth }
        replicator.onDrift = { _, _ in }
        truth = fleet(titled: "actual")
        replicator.record([.unreadChanged(id: sessionID, isUnread: true)])
        XCTAssertEqual(replicator.snapshot().fleet, truth)
    }
}
