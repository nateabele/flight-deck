import XCTest
import IntakeKit
@testable import FlightDeck

/// Every controller path that awaits br can be overtaken by another: `stop()` from the menu or
/// Turn Off, or a sweep that finds the agent's tab closed. Whatever the path held before its
/// await may be stale after it. These pin that an agent `stop()` retired or a sweep marked done
/// is never revived, typed into, or has its lease released a second time.
@MainActor
final class SwarmControllerLivenessTests: XCTestCase {
    /// The Turn Off race: stop() lands while `br update --claim` runs. Before, the claim's success
    /// set the task, typed the prompt and marked a retired agent working — a task in progress
    /// and prompted after Flight Control was off.
    func testAClaimThatLandsAfterStopIsReturnedAndNothingIsTyped() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        rig.backend.onClaim = { _ in c.stop(reason: "Flight Control turned off") }
        await rig.run(c)
        XCTAssertTrue(rig.launcher.delivered.isEmpty, "no prompt for an agent stop() retired")
        XCTAssertEqual(rig.backend.returned, ["fx-1"], "the claim that landed late goes back to open")
        XCTAssertEqual(rig.allocator.released, [lease], "released once, by stop()")
        let agent = c.record.agents.first
        XCTAssertEqual(agent?.state, .done)
        XCTAssertNil(agent?.task)
        XCTAssertNil(agent?.pendingClaim)
    }

    func testAConflictAfterStopDoesNotReviveTheAgent() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        rig.backend.claimResults["fx-1"] = .conflict
        let c = rig.controller(rig.record(cap: 1))
        rig.backend.onClaim = { _ in c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        XCTAssertTrue(rig.backend.returned.isEmpty, "a conflict claimed nothing, so nothing is returned")
    }

    /// stop() retires the agent (releasing its lease) while the sweep reads its task's status.
    func testAClosedTabStoppedMidSweepReleasesItsLeaseOnce() async {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "A")
        let a = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        rig.host.existing.remove(a.session)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        rig.backend.onStatus = { _ in c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertEqual(rig.allocator.released, [lease])
        XCTAssertEqual(c.record.agent(a.session)?.state, .done)
        XCTAssertEqual(rig.backend.returned, ["fx-1"], "the closed tab's claim still goes back")
        XCTAssertNil(c.record.agent(a.session)?.task)
    }

    /// The user closes the tab while `taskSetChanged` reads the agent's task, and a tick's sweep
    /// marks it done inside that await. Before, `taskSetChanged` then set it idle with its old
    /// lease, and the next sweep released that lease a second time.
    func testASweepDuringTaskSetChangedIsNotUndone() async {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "A")
        let a = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "BlueLake")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        rig.backend.onStatus = { [backend = rig.backend, host = rig.host] _ in
            backend.onStatus = nil
            host.existing.remove(a.session)
            await c.tick()
        }
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.agent(a.session)?.state, .done, "the sweep's done is not revived to idle")
        await rig.run(c)
        XCTAssertEqual(rig.allocator.released, [lease], "the next sweep does not release it again")
    }
}
