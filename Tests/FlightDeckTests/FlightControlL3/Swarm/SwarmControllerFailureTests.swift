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
}
