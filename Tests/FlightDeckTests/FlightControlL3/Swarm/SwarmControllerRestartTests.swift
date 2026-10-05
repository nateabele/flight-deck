import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §2 and the crash-mid-claim Review Focus item. A launch the crash interrupted never
/// reached its prompt, so the agent never heard about the task: whatever claim landed goes back
/// to open, and the agent is idle and reusable.
@MainActor
final class SwarmControllerRestartTests: XCTestCase {
    func testRestoreReopensAClaimThatLandedBeforeTheCrash() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting)
        a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
        XCTAssertNil(c.record.agent(a.session)?.pendingClaim)
    }

    func testRestoreDropsAPendingClaimThatNeverLanded() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting)
        a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "open", assignee: nil)
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertTrue(rig.backend.returned.isEmpty, "a task that is already open needs no reopening")
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
        XCTAssertNil(c.record.agent(a.session)?.pendingClaim)
    }

    func testRestoreNeverTouchesAClaimAnotherAgentHolds() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting)
        a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "RedFox")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertTrue(rig.backend.returned.isEmpty)
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
    }

    func testAnUnreadableClaimIsLeftForALaterRetry() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting)
        a.pendingClaim = "fx-1"
        // No status scripted: the read returns nil.
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertTrue(rig.backend.returned.isEmpty, "an unreadable status is never a reason to reopen")
        XCTAssertEqual(c.record.agent(a.session)?.pendingClaim, "fx-1", "and the claim is not dropped")
        XCTAssertEqual(c.record.agent(a.session)?.state, .starting)
    }

    func testAClaimedButUnpromptedStarterAlsoGivesItsClaimBack() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .starting, task: "fx-1")
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertNil(c.record.agent(a.session)?.task)
    }

    func testWorkingAgentsAreLeftWorking() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertEqual(c.record.agent(a.session)?.state, .working)
        XCTAssertTrue(rig.backend.returned.isEmpty)
    }

    func testARestoredSwarmClaimsNothingUntilResumed() async throws {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.store.save([rig.record(cap: 1, state: .running)])
        let restored = try XCTUnwrap(rig.store.restore().first)
        XCTAssertEqual(restored.banner, SwarmStore.restartBanner)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(restored)
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty)
        await c.resume(); await c.settle()
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"])
    }
}
