import XCTest
import IntakeKit
@testable import FlightDeck

/// The service is the swarm's single owner: one swarm per project, restored swarms reconciled
/// once, clock ticks throttled, the Observe task set routed to the right controller, and the
/// record updates L3-U's hand-off driver needs.
@MainActor
final class SwarmServiceTests: XCTestCase {
    private func service(_ rig: SwarmRig, clock: WatchClock? = nil) -> SwarmService {
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher,
                                   spawner: FakeSwarmSpawner(), host: rig.host,
                                   registry: RoutingCapabilityRegistry([]), clock: clock,
                                   now: { [unowned rig] in rig.now })
        service.dependencies = SwarmDependencies(makeRouter: { [router = rig.router] in router }, kinds: rig.kinds,
                                                 allocator: rig.allocator, capacity: rig.capacity)
        return service
    }

    func testLaunchCreatesARunningSwarmAndFillsIt() async throws {
        let rig = SwarmRig(); rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let s = service(rig)
        let record = try XCTUnwrap(s.launch(project: SwarmFixtures.project, cap: 2, poolCaps: [:], filter: .allReady))
        await s.settle()
        XCTAssertEqual(record.state, .running)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"])
        XCTAssertEqual(rig.store.load().first?.agents.count, 1, "every change is persisted")
    }

    func testAtMostOneLiveSwarmPerProject() async {
        let rig = SwarmRig(); rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let s = service(rig)
        XCTAssertNotNil(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
        XCTAssertNil(s.launch(project: SwarmFixtures.project + "/", cap: 1, poolCaps: [:], filter: .allReady),
                     "the same project by another spelling is still the same project")
        await s.settle()   // the launch's tick reads `rig`; it must finish before the rig goes
    }

    func testARelaunchAfterStopReplacesTheStoppedSwarm() async throws {
        let rig = SwarmRig()
        let s = service(rig)
        let first = try XCTUnwrap(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
        await s.settle()
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.state, .stopped, "nothing ready: it stopped itself")
        let second = try XCTUnwrap(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
        XCTAssertNotEqual(first.id, second.id)
        await s.settle()
    }

    func testWithoutDependenciesNothingLaunches() {
        let rig = SwarmRig()
        let s = service(rig); s.dependencies = nil
        XCTAssertNil(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
    }

    func testRestoredSwarmsArePausedAndReconciledOnce() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting); a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        rig.store.save([rig.record(state: .running, agents: [a])])
        let s = service(rig)
        await s.settle()
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.state, .paused)
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.banner, SwarmStore.restartBanner)
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        let again = s.dependencies; s.dependencies = again   // a re-set must not reconcile again
        await s.settle()
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
    }

    func testProjectionsDriveCompletion() async throws {
        let rig = SwarmRig(); rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let s = service(rig)
        _ = s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady)
        await s.settle()
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        let projection = FlywheelProjection.project(
            FlywheelSnapshot(agents: [], beads: [], reservations: nil, depEdges: nil, events: nil),
            now: rig.now, stallThreshold: 600, previous: nil)
        await s.applyProjections([FlywheelObserveService.key(SwarmFixtures.project): projection])
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.agents.first?.lastTask, "fx-1")
    }

    func testClockTicksAreThrottled() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]   // no lease: waits, keeps running
        let clock = WatchClock(appIsActive: { true })
        let s = service(rig, clock: clock)
        _ = s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady)
        await s.settle()
        let afterLaunch = rig.backend.readyCalls
        clock.fire(); await s.settle()
        clock.fire(); await s.settle()
        XCTAssertEqual(rig.backend.readyCalls, afterLaunch + 1, "two beats inside five seconds tick once")
        rig.now += SwarmService.tickInterval
        clock.fire(); await s.settle()
        XCTAssertEqual(rig.backend.readyCalls, afterLaunch + 2)
    }

    func testHandoffMovesTheTaskToTheNewAgent() async throws {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "Old")
        let a = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        rig.store.save([rig.record(state: .paused, agents: [a])])
        let s = service(rig)
        await s.settle()
        let new = SessionRef(id: UUID(), agentName: "GreenFox")
        XCTAssertTrue(s.recordHandoff(project: SwarmFixtures.project, from: a.session, to: new,
                                      block: SwarmFixtures.block(), lease: nil))
        let record = try XCTUnwrap(s.record(forProject: SwarmFixtures.project))
        XCTAssertEqual(record.agent(a.session)?.state, .handedOff)
        XCTAssertEqual(record.agent(a.session)?.handedOffTo, new.id)
        XCTAssertEqual(record.agent(new.id)?.task, "fx-1")
        XCTAssertEqual(record.agent(new.id)?.handedOffFrom, a.session)
        XCTAssertEqual(rig.allocator.released, [lease])
    }

    func testAgentSnapshotsListWorkingAgents() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        let b = rig.agent("GreenFox", state: .idle)
        rig.store.save([rig.record(state: .paused, agents: [a, b])])
        let s = service(rig)
        await s.settle()
        let snapshots = s.agentSnapshots(project: SwarmFixtures.project)
        XCTAssertEqual(snapshots.map(\.agentName), ["BlueLake"])
        XCTAssertEqual(snapshots.first?.task?.id, "fx-1")
    }

    func testHandoffDecisionsGoToTheSink() async {
        final class Sink: HandoffDecisionSink {
            var pendingHandoffs: Set<UUID> = []
            var confirmed: [UUID] = []
            func confirmHandoff(session: UUID) -> Bool { confirmed.append(session); return true }
            func declineHandoff(session: UUID) -> Bool { false }
        }
        let rig = SwarmRig(); let s = service(rig)
        XCTAssertFalse(s.confirmHandoff(session: UUID()), "no driver wired: nothing to confirm")
        let sink = Sink(); s.handoffDecisions = sink
        let id = UUID()
        XCTAssertTrue(s.confirmHandoff(session: id))
        XCTAssertEqual(sink.confirmed, [id])
    }

    /// `rebuildControllers` orphans the old controller, which may still have launches in flight;
    /// its late `onChange` must not overwrite the record the new controller owns.
    func testAnOrphanedControllersChangeDoesNotOverwriteTheRecord() async throws {
        let rig = SwarmRig()
        rig.store.save([rig.record(state: .paused)])
        let s = service(rig)
        await s.settle()
        let old = try XCTUnwrap(s.controller(forProject: SwarmFixtures.project))
        s.dependencies = SwarmDependencies(makeRouter: { [router = rig.router] in router }, kinds: rig.kinds,
                                           allocator: rig.allocator, capacity: rig.capacity)
        let new = try XCTUnwrap(s.controller(forProject: SwarmFixtures.project))
        XCTAssertFalse(old === new)
        var stale = old.record; stale.cap = 99
        old.onChange(stale)
        XCTAssertNotEqual(s.record(forProject: SwarmFixtures.project)?.cap, 99)
        var fresh = new.record; fresh.cap = 7
        new.onChange(fresh)
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.cap, 7)
    }

    /// The store owns the service; the service must not own the store back.
    func testTheServiceDoesNotRetainItsHost() {
        let rig = SwarmRig()
        let log = SwarmCallLog()
        var host: FakeSwarmHost? = FakeSwarmHost(log: log)
        weak var weakHost = host
        var s: SwarmService? = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher,
                                            spawner: nil, host: host!, registry: RoutingCapabilityRegistry([]),
                                            clock: nil)
        s?.dependencies = SwarmDependencies(makeRouter: { [router = rig.router] in router }, kinds: rig.kinds,
                                            allocator: rig.allocator, capacity: rig.capacity)
        host = nil
        XCTAssertNil(weakHost, "neither the service nor its controllers keep the host alive")
        s = nil
    }
}
