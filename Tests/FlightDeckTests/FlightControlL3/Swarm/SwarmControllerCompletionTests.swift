import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 "Completion": the watcher's in-progress set drives it; `br show` decides what a
/// disappearance means. Two Review Focus items live here.
@MainActor
final class SwarmControllerCompletionTests: XCTestCase {
    private func working(_ rig: SwarmRig) async -> (SwarmController, UUID) {
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        return (c, c.record.agents[0].session)
    }

    func testAClosedTaskFreesTheSlotAndTheAgentIsReusedForTheNext() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        await c.taskSetChanged(inProgress: [])
        await c.settle()
        XCTAssertEqual(c.record.agent(a)?.lastTask, "fx-1")
        XCTAssertEqual(rig.launcher.resets, [a])
        XCTAssertEqual(c.record.agent(a)?.task, "fx-2")
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .close && $0.task == "fx-1" })
    }

    func testATaskStillInProgressIsLeftAlone() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        await c.taskSetChanged(inProgress: ["fx-1"])
        XCTAssertEqual(c.record.agent(a)?.state, .working)
    }

    func testATaskMissingFromTheWatcherButStillOursIsLeftAlone() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)   // the fake's claim set fx-1 in_progress by Agent1
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.agent(a)?.state, .working, "a watcher snapshot older than the claim is not a completion")
    }

    func testATaskBackToOpenIsLoggedAndTheAgentTreatedAsIdle() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "open", assignee: nil)
        // A task on another config with no lease waits, which keeps the swarm from stopping
        // itself (Task 7e) once the agent goes idle.
        rig.backend.ready = [SwarmFixtures.task("fx-9", SwarmFixtures.block("other"))]
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.agent(a)?.state, .idle)
        XCTAssertNil(c.record.agent(a)?.task)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .reopen && $0.task == "fx-1" })
    }

    func testHumanClosedTaskDoesNotReuseABusyAgent() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.host.busy.insert(a)                          // its turn is still running
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        await c.taskSetChanged(inProgress: [])
        await c.settle()
        XCTAssertTrue(rig.launcher.resets.isEmpty, "no /clear into a running turn")
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1", "fx-2"])
    }

    func testClosedTabReturnsItsClaimAndFreesItsSlot() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        let lease = c.record.agent(a)?.lease?.lease
        rig.host.existing.remove(a)                      // the user closed the tab
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        await rig.run(c)
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertEqual(c.record.agent(a)?.state, .done)
        XCTAssertEqual(c.record.agent(a)?.marker, "tab closed")
        XCTAssertTrue(rig.allocator.released.contains(lease!))
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1", "fx-2"], "the freed slot is filled in the same tick")
    }

    func testAClosedTabWhoseTaskIsAlreadyClosedReturnsNothing() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.host.existing.remove(a)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        await rig.run(c)
        XCTAssertTrue(rig.backend.returned.isEmpty)
    }
}
