import XCTest
@testable import FlightDeck

/// `SessionStore` wires Observe's `enrich` hook: a busy agent is active now, an idle one is as
/// active as its last transition, and with no swarm built the snapshot passes through untouched.
@MainActor
final class StoreObserveEnrichTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var project: String { SwarmFixtures.project }

    private func rigStore() -> (SessionStore, UUID, UUID, () -> Date) {
        var clock = t0
        let store = SessionStore(provider: nil, persistence: nil)
        store.now = { clock }
        let url = URL(fileURLWithPath: project, isDirectory: true)
        let busy = store.newSession(in: url, flywheelIdentity: FlywheelIdentity(agentName: "GreenFox", project: project))
        let idle = store.newSession(in: url, flywheelIdentity: FlywheelIdentity(agentName: "BlueLake", project: project))
        store.applyRegistryForTesting([busy.id: SessionStatus(activity: .busy), idle.id: SessionStatus(activity: .busy)])
        clock += 600
        store.applyRegistryForTesting([busy.id: SessionStatus(activity: .busy), idle.id: SessionStatus(activity: .idle)])
        clock += 600
        return (store, busy.id, idle.id, { clock })
    }

    private var empty: FlywheelSnapshot {
        FlywheelSnapshot(agents: [], beads: [], reservations: [], depEdges: [], events: nil)
    }

    func testBusyAgentIsActiveNowAndIdleAgentIsActiveAtItsLastTransition() throws {
        let (store, _, _, clock) = rigStore()
        let rig = SwarmRig()
        store.useSwarmService(SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                           host: store, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now }))
        let enrich = try XCTUnwrap(store.observeService.enrich)
        let events = try XCTUnwrap(enrich(FlywheelObserveService.key(project), empty).events)
        XCTAssertEqual(events.first { $0.agent == "GreenFox" }?.at, clock())
        XCTAssertEqual(events.first { $0.agent == "BlueLake" }?.at, t0 + 600)
    }

    func testWithoutASwarmTheSnapshotPassesThrough() throws {
        let (store, _, _, _) = rigStore()
        let enrich = try XCTUnwrap(store.observeService.enrich)
        XCTAssertEqual(enrich(FlywheelObserveService.key(project), empty), empty)
    }
}
