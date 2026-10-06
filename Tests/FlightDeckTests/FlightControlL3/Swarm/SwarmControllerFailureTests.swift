import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §10. A config that keeps failing pauses the swarm with a banner instead of burning
/// through every ready task; an agent that never shows a composer gives its claim back and is
/// never typed into again.
@MainActor
final class SwarmControllerFailureTests: XCTestCase {
    func testThreeSpawnFailuresInARowOnOneConfigPauseTheSwarm() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.launcher.createResults = Array(repeating: .failure(.launchFailed("Agent Mail boot failed")), count: 3)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .paused)
        XCTAssertEqual(c.record.banner,
                       "Paused: 3 launches in a row failed for codex|gpt-6-sol||codex-subs — Agent Mail boot failed")
        XCTAssertTrue(rig.backend.claims.isEmpty)
    }

    func testASuccessResetsTheCount() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.launcher.createResults = [.failure(.launchFailed("x")), .failure(.launchFailed("x"))]
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .running)
        XCTAssertNil(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue])
    }

    func testFailuresOnDifferentConfigsDoNotAddUp() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2); rig.leases("other", 1)
        rig.launcher.createResults = Array(repeating: .failure(.launchFailed("x")), count: 3)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()),
                             SwarmFixtures.task("fx-2", SwarmFixtures.block()),
                             SwarmFixtures.task("fx-3", SwarmFixtures.block("other"))]
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .running)
    }

    func testNoComposerWithinTwoMinutesReturnsTheClaimAndMarksStuck() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        rig.launcher.createResults = [.success(ref)]
        rig.launcher.deliverFailures[ref.id] = .composerTimeout
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        let agent = c.record.agent(ref.id)
        XCTAssertEqual(agent?.state, .idle)
        XCTAssertEqual(agent?.marker, "stuck at start")
        XCTAssertEqual(agent?.excludedFromReuse, true)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .stuck && $0.task == "fx-1" })
    }

    // MARK: review follow-ups

    func testAStoppedSwarmIsNeverPausedByLateSpawnFailures() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.launcher.createResults = Array(repeating: .failure(.launchFailed("x")), count: 3)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        rig.launcher.onCreateAttempt = { c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertNil(c.record.banner)
    }

    func testAnAgentNameLessLaunchIsALaunchFailure() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.launcher.createResults = [.success(SessionRef(id: UUID(), agentName: nil))]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty, "never claim as an empty actor")
        XCTAssertTrue(c.record.agents.isEmpty)
        XCTAssertEqual(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue], 1)
        XCTAssertTrue(rig.allocator.released.contains(lease))
    }

    func testStoppingDuringAReuseLeavesTheAgentDoneAndTypesNothing() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        rig.backend.onReleaseReservations = { c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertEqual(c.record.agent(a.session)?.state, .done)
        XCTAssertTrue(rig.launcher.resets.isEmpty, "no reset typed into a retired agent")
        XCTAssertTrue(rig.host.woken.isEmpty)
        XCTAssertTrue(rig.launcher.delivered.isEmpty)
    }

    func testAResetFailureDoesNotResurrectAnAgentStopRetired() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.launcher.resetResults[a.session] = false
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        rig.launcher.onReset = { c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertEqual(c.record.agent(a.session)?.state, .done)
        XCTAssertTrue(rig.launcher.created.isEmpty)
    }

    func testDrainingDuringAnInFlightLaunchStopsWhenTheLaunchCompletes() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        rig.launcher.onCreate = { [host = rig.host] ref in host.existing.insert(ref.id); c.drain() }
        await rig.run(c)
        XCTAssertEqual(c.record.state, .stopped)
    }

    func testTheResetFailureFallbackSpawnIsSkippedWhenTheSwarmIsNotRunning() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let a = rig.agent("BlueLake")
        rig.launcher.resetResults[a.session] = false
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        rig.launcher.onReset = { c.pause() }
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertEqual(c.record.state, .paused)
    }

    func testStoppingDuringADeliveryLeavesTheAgentDoneAndReturnsTheClaim() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        rig.launcher.createResults = [.success(ref)]
        rig.launcher.deliverFailures[ref.id] = .composerTimeout
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        rig.launcher.onDeliver = { c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertEqual(c.record.agent(ref.id)?.state, .done)
        XCTAssertNotEqual(c.record.agent(ref.id)?.marker, "stuck at start")
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertEqual(rig.allocator.released.filter { $0 == lease }.count, 1)
    }

    func testASpillIsNotLeasedWhenTheSwarmPausesWhileCatalogsLoad() async {
        let rig = SwarmRig()
        let spilled = SwarmFixtures.block("claude-subs", model: "opus", harness: "claude")
        rig.leases("claude-subs", 1)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        rig.onCatalogs = { c.pause() }
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertFalse(rig.allocator.leaseCalls.contains("claude-subs"), "no lease taken for a spill the swarm can no longer start")
    }

    // MARK: final review

    /// A composer that never appears is deterministic more often than not (a blocked login, a
    /// first-run dialog). Before, the spawn's success reset the count before the prompt failed,
    /// so a stuck config opened a fresh tab every two minutes per slot forever.
    func testThreeStuckAtStartsInARowPauseTheSwarm() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        let refs = (1...3).map { SessionRef(id: UUID(), agentName: "Agent\($0)") }
        rig.launcher.createResults = refs.map { .success($0) }
        for ref in refs { rig.launcher.deliverFailures[ref.id] = .composerTimeout }
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 1))
        for _ in 0..<3 { await rig.run(c) }
        XCTAssertEqual(c.record.state, .paused)
        XCTAssertEqual(c.record.banner,
                       "Paused: 3 launches in a row failed for codex|gpt-6-sol||codex-subs — no composer within two minutes")
        XCTAssertEqual(rig.launcher.created.count, 3)
    }

    func testAPromptThatLandsResetsTheFailureCount() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        let stuck = SessionRef(id: UUID(), agentName: "Agent1")
        rig.launcher.createResults = [.success(stuck), .success(SessionRef(id: UUID(), agentName: "Agent2"))]
        rig.launcher.deliverFailures[stuck.id] = .composerTimeout
        rig.backend.ready = ["fx-1", "fx-2"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue], 1)
        await rig.run(c)
        XCTAssertNil(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue])
    }

    /// An agent excluded from reuse never takes work again, so the account it leased must go
    /// back now — and exactly once: stop() later must not release it a second time.
    func testAStuckAgentGivesUpItsLeaseExactlyOnce() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        rig.launcher.createResults = [.success(ref)]
        rig.launcher.deliverFailures[ref.id] = .composerTimeout
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertNil(c.record.agent(ref.id)?.lease)
        XCTAssertEqual(rig.allocator.released, [lease])
        c.stop(reason: "stopped from the menu")
        XCTAssertEqual(rig.allocator.released, [lease])
    }

    func testAResetFailedAgentGivesUpItsLeaseExactlyOnce() async {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "A")
        let a = rig.agent("BlueLake", lease: lease)
        rig.launcher.resetResults[a.session] = false
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        await rig.run(c)
        XCTAssertEqual(c.record.agent(a.session)?.excludedFromReuse, true)
        XCTAssertNil(c.record.agent(a.session)?.lease)
        XCTAssertEqual(rig.allocator.released, [lease])
        c.stop(reason: "stopped from the menu")
        XCTAssertEqual(rig.allocator.released, [lease])
    }

    /// Pause means no new work: a reuse the pause overtook must not wake the tab or type `/clear`.
    func testPausingDuringAReuseWakesAndTypesNothing() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        rig.backend.onReleaseReservations = { c.pause() }
        await rig.run(c)
        XCTAssertTrue(rig.host.woken.isEmpty)
        XCTAssertTrue(rig.launcher.resets.isEmpty)
        XCTAssertTrue(rig.launcher.delivered.isEmpty)
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle, "back to idle, reusable on resume")
    }

    /// A launch task runs after the tick that started it; a pause (or stop) in between must not
    /// open a tab.
    func testPausingBeforeALaunchRunsOpensNoTab() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await c.tick()
        c.pause()
        await c.settle()
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertEqual(rig.allocator.released, [lease], "the unused lease goes back")
        XCTAssertEqual(c.freeSlots, 1, "and the slot it held is free again")
        XCTAssertEqual(c.record.state, .paused)
    }
}
