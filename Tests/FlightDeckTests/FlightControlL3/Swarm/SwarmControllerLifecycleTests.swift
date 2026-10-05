import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 "Stopping". Pause must take effect before the next claim; drain ends in stopped only
/// when the last working agent goes idle; a swarm with nothing left stops itself.
@MainActor
final class SwarmControllerLifecycleTests: XCTestCase {
    func testPauseStopsNewClaimsOnTheNextTick() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 2))
        c.pause()
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty)
        XCTAssertEqual(c.record.state, .paused)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .pause })
    }

    func testResumeClaimsAgainAndClearsTheBannerAndFailureCount() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        var record = rig.record(cap: 1, state: .paused)
        record.banner = SwarmStore.restartBanner
        record.spawnFailures = ["k": 3]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(record)
        await c.resume(); await c.settle()
        XCTAssertEqual(c.record.state, .running)
        XCTAssertNil(c.record.banner)
        XCTAssertEqual(c.record.spawnFailures, [:])
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"])
    }

    func testDrainStopsWhenTheLastWorkingAgentGoesIdle() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        c.drain()
        XCTAssertEqual(c.record.state, .draining)
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"], "draining claims nothing new")
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        XCTAssertEqual(rig.allocator.released.count, 1)
    }

    func testAutoStopsWhenNothingIsReadyWaitingOrWorking() async {
        let rig = SwarmRig()
        let c = rig.controller(rig.record(cap: 2))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .stop && $0.detail == "nothing left to do" })
    }

    func testAWaitingTaskKeepsTheSwarmRunning() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .running)
    }

    func testOnlyUnroutableWorkStopsTheSwarm() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-none", nil)]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .stopped)
    }

    func testAWorkingAgentKeepsTheSwarmRunning() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 2))
        await rig.run(c)
        await rig.run(c)            // fx-1 claimed; ready is now empty
        XCTAssertEqual(c.record.state, .running)
    }

    func testStopReleasesLeasesAndRetiresAgents() async {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "A")
        let a = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        let c = rig.controller(rig.record(agents: [a]))
        c.stop(reason: "stopped from the menu")
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        XCTAssertEqual(rig.allocator.released, [lease])
    }

    /// Controller ruling R4: the state is rechecked after the spawn returns, before the claim.
    func testPauseBetweenCreateAndClaimLeavesTheAgentIdleWithoutClaiming() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        rig.launcher.onCreate = { [host = rig.host] ref in host.existing.insert(ref.id); c.pause() }
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty)
        XCTAssertEqual(c.record.state, .paused)
        XCTAssertEqual(c.record.agents.map(\.state), [.idle])
        XCTAssertNil(c.record.agents.first?.pendingClaim)
        XCTAssertTrue(rig.allocator.released.isEmpty, "a paused agent keeps its lease")
    }

    func testStopDuringAnInFlightSpawnReleasesTheLeaseAndRetiresTheAgent() async {
        let rig = SwarmRig()
        let leases = rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        rig.launcher.onCreate = { [host = rig.host] ref in host.existing.insert(ref.id); c.stop(reason: "stopped from the menu") }
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty)
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        XCTAssertEqual(rig.allocator.released, leases)
    }

    func testAClosedThenStoppedAgentsLeaseIsReleasedExactlyOnce() async {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "A")
        let a = rig.agent("BlueLake", lease: lease, state: .idle)
        rig.host.existing.remove(a.session)              // the user closed the tab
        let c = rig.controller(rig.record(agents: [a]))
        rig.backend.ready = [SwarmFixtures.task("fx-w", SwarmFixtures.block("other"))]   // keeps the swarm alive
        await rig.run(c)
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        c.stop(reason: "stopped from the menu")
        XCTAssertEqual(rig.allocator.released, [lease])
    }
}
