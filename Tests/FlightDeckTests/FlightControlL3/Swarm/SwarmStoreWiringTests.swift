import XCTest
import IntakeKit
@testable import FlightDeck

/// The store is the swarm's host and the owner of its service. A swarm on disk must come back
/// paused at launch, and the store must answer the host questions from its real state.
@MainActor
final class SwarmStoreWiringTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-wiring-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func saveASwarm() {
        SwarmStore(root: root).save([SwarmRecord(id: UUID(), project: "/tmp/p", cap: 2, poolCaps: [:],
                                                 filter: .allReady, state: .running, agents: [],
                                                 createdAt: Date(timeIntervalSince1970: 1_790_000_000))])
    }

    func testTheStoreRestoresSwarmsFromItsRoot() {
        saveASwarm()
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        XCTAssertEqual(store.swarmService.record(forProject: "/tmp/p")?.state, .paused)
    }

    func testASwarmOnDiskBuildsAndRestoresTheServiceAtLaunch() {
        saveASwarm()
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        store.restoreSwarmsIfPresent()
        XCTAssertEqual(store.swarmServiceIfBuilt?.record(forProject: "/tmp/p")?.state, .paused)
    }

    func testAStoreWithNoSwarmsDoesNotBuildTheServiceAtLaunch() {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        store.restoreSwarmsIfPresent()
        XCTAssertNil(store.swarmServiceIfBuilt)
    }

    func testDependenciesReachTheService() {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        let service = store.swarmService
        XCTAssertNil(service.dependencies)
        store.swarmDependencies = SwarmDependencies(makeRouter: { FakeRouter() }, kinds: FakeKindRegistry(),
                                                    allocator: FakePoolAllocator(), capacity: FakeCapacityReader())
        XCTAssertNotNil(service.dependencies)
    }

    func testAnInstalledServiceIsForwardedAsTheStoresChange() {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        let rig = SwarmRig()
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: store, registry: store.routingCapabilities, clock: nil)
        store.useSwarmService(service)
        XCTAssertTrue(store.swarmServiceIfBuilt === service)
        var changes = 0
        let sink = store.objectWillChange.sink { changes += 1 }
        service.objectWillChange.send()
        XCTAssertEqual(changes, 1)
        sink.cancel()
    }

    func testTheStoreAnswersAsASwarmHost() {
        let store = SessionStore(provider: nil, persistence: nil)
        let identity = FlywheelIdentity(agentName: "BlueLake", project: "/tmp/p")
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true), flywheelIdentity: identity)
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .idle)])
        XCTAssertTrue(store.isAgentIdle(s.id))
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        XCTAssertFalse(store.isAgentIdle(s.id))
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .waiting)])
        XCTAssertFalse(store.isAgentIdle(s.id), "a tab on a dialog is not idle")
        let agents = store.flywheelAgents(inProject: "/tmp/p/")
        XCTAssertEqual(agents.map(\.agentName), ["BlueLake"])
        XCTAssertEqual(agents.map(\.session), [s.id])
    }

    /// The live spawner is L3-U's hand-off path; its claim must reach the service's backend.
    func testTheInstalledSpawnerClaimsThroughTheServicesBackend() async throws {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        let rig = SwarmRig()
        let spawner = StoreSwarmSpawner.live(store: store)
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: spawner, spawner: spawner,
                                   host: store, registry: store.routingCapabilities, clock: nil)
        store.useSwarmService(service)
        let claim = try XCTUnwrap(spawner.claim)
        let outcome = await claim(TaskRef(id: "fx-1", project: URL(fileURLWithPath: "/tmp/p", isDirectory: true)), "BlueLake")
        XCTAssertEqual(outcome, .claimed)
        XCTAssertEqual(rig.backend.claims, [FakeSwarmBackend.ClaimCall(task: "fx-1", actor: "BlueLake")])
    }

    func testTheBuiltServicesSpawnerCanClaim() {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        XCTAssertNotNil((store.swarmService.spawner as? StoreSwarmSpawner)?.claim)
    }
}
