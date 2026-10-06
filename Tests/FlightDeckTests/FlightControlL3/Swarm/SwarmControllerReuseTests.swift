import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 step 4 and §10: reuse before spawn, the config-key match, the soft-limit check, and
/// the reset-failure fallback. The ordering test is a Review Focus item.
@MainActor
final class SwarmControllerReuseTests: XCTestCase {
    func testAnIdleAgentWithTheSameConfigIsReusedAfterAReset() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty, "reuse, not spawn")
        XCTAssertEqual(rig.launcher.resets, [a.session])
        XCTAssertEqual(rig.backend.claims.map(\.actor), ["BlueLake"])
        XCTAssertEqual(c.record.agent(a.session)?.state, .working)
        XCTAssertEqual(c.record.agent(a.session)?.task, "fx-1")
    }

    func testReuseReleasesReservationsBeforeResettingContext() async throws {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1, agents: [a])))
        let release = try XCTUnwrap(rig.log.index(of: "release BlueLake"))
        let reset = try XCTUnwrap(rig.log.index(of: "reset BlueLake"))
        let claim = try XCTUnwrap(rig.log.index(of: "claim fx-1 BlueLake"))
        let prompt = try XCTUnwrap(rig.log.index(of: "prompt BlueLake"))
        XCTAssertLessThan(release, reset, "stale reservations must go before the next task starts")
        XCTAssertLessThan(reset, claim)
        XCTAssertLessThan(claim, prompt)
    }

    func testASleepingAgentIsWokenBeforeItsReset() async throws {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1, agents: [a])))
        XCTAssertEqual(rig.host.woken, [a.session])
        XCTAssertLessThan(try XCTUnwrap(rig.log.index(of: "wake")), try XCTUnwrap(rig.log.index(of: "reset BlueLake")))
    }

    func testADifferentConfigIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let other = rig.agent("BlueLake", block: SwarmFixtures.block(model: "gpt-6-terra"))
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [other])))
        XCTAssertTrue(rig.launcher.resets.isEmpty)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
    }

    func testAnAgentWhoseAccountIsPastSoftIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let lease = SwarmFixtures.lease("codex-subs", "Busy")
        rig.capacity.byPool["codex-subs"] = [AccountHeadroom(account: lease.account, worstUtilization: 0.85, state: .overSoft, resetsAt: nil)]
        let a = rig.agent("BlueLake", lease: lease)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [a])))
        XCTAssertTrue(rig.launcher.resets.isEmpty)
        XCTAssertEqual(rig.launcher.created.count, 1)
    }

    func testAnExcludedAgentIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        var a = rig.agent("BlueLake"); a.excludedFromReuse = true
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [a])))
        XCTAssertTrue(rig.launcher.resets.isEmpty)
    }

    func testABusyTabIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let a = rig.agent("BlueLake")
        rig.host.busy.insert(a.session)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [a])))
        XCTAssertTrue(rig.launcher.resets.isEmpty, "a /clear typed into a running turn queues behind it")
        XCTAssertEqual(rig.launcher.created.count, 1)
    }

    func testAResetFailureSpawnsAFreshAgentAndRetiresTheOldOne() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let a = rig.agent("BlueLake")
        rig.launcher.resetResults[a.session] = false
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
        XCTAssertEqual(c.record.agent(a.session)?.excludedFromReuse, true)
        XCTAssertEqual(c.record.agent(a.session)?.marker, "reset failed")
        XCTAssertEqual(rig.backend.claims.map(\.actor), ["Agent1"])
    }

    func testTheLongestIdleAgentIsPickedFirst() {
        let at = SwarmFixtures.at
        var older = SwarmAgentRecord(session: UUID(), agentName: "Old", block: SwarmFixtures.block(), lease: nil,
                                     task: nil, state: .idle, stateSince: at)
        older.stateSince = at.addingTimeInterval(-600)
        let newer = SwarmAgentRecord(session: UUID(), agentName: "New", block: SwarmFixtures.block(), lease: nil,
                                     task: nil, state: .idle, stateSince: at)
        let pick = SwarmPlanner.reuseCandidate(for: ConfigKey(SwarmFixtures.block()), in: [newer, older],
                                               isAvailable: { _ in true }, headroom: { _ in .underSoft })
        XCTAssertEqual(pick?.agentName, "Old")
    }
}
