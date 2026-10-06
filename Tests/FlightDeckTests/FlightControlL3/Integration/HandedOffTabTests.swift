import XCTest
import IntakeKit
@testable import FlightDeck

/// After a hand-off the old tab is finished as far as Flight Control goes: the row says so, and
/// the swarm never drives it again. Ruling: "read-only" means Flight Control's own hands are off
/// that tab (no prompt, claim, reuse or second hand-off); the user's keyboard is not blocked.
@MainActor
final class HandedOffTabTests: XCTestCase {
    private var rig: L3IntegrationRig!

    override func setUp() async throws { rig = try L3IntegrationRig.standard() }
    override func tearDown() async throws {
        await rig?.swarm.settle()
        rig = nil
    }

    func testHandedOffTabShowsMarkerAndIsNoLongerDriven() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 2)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertEqual(rig.spawns.count, 2, "the hand-off spawned the successor")
        let successor = try XCTUnwrap(rig.spawns.last)

        // The marker, through the same read the sidebar row uses.
        XCTAssertEqual(rig.swarm.annotation(for: first.session.id)?.marker, "handed off →")
        XCTAssertEqual(rig.swarm.agentRecord(first.session.id)?.1.handedOffTo, successor.session.id)

        // Excluded from what the hand-off driver is shown.
        let snapshots = rig.swarm.agentSnapshots(project: rig.project).map(\.session.id)
        XCTAssertFalse(snapshots.contains(first.session.id), "a handed-off agent is not a hand-off candidate")
        XCTAssertTrue(snapshots.contains(successor.session.id))

        // A new task becomes ready with a free slot (cap 2, one active) and the old tab idle,
        // under the same config: reuse must not pick it, nor may the swarm claim for it. Work
        // drops back under soft first: while it is over hard, headroom alone refuses reuse, so
        // the state check would go unproven (an agent wrongly left .idle would still not be reused).
        rig.feed(account: "Work", utilization: 0.30)
        try rig.release("fx-two")
        let before = rig.runner.argv.count
        await rig.tick()
        await rig.tick()
        XCTAssertEqual(rig.spawns.count, 3, "fx-two got a fresh tab")
        XCTAssertNotEqual(rig.spawns.last?.session.id, first.session.id)
        let after = Array(rig.runner.argv.dropFirst(before))
        let oldName = try XCTUnwrap(first.session.agentName)
        XCTAssertFalse(after.contains { $0.contains("--actor") && $0.contains(oldName) },
                       "nothing is claimed for the old agent: \(after)")
        XCTAssertEqual(rig.launcher.delivered.filter { $0.session == first.session.id }.count, 1,
                       "the old tab only ever got its original prompt")
        XCTAssertEqual(rig.swarm.annotation(for: first.session.id)?.marker, "handed off →", "still finished")
    }
}
