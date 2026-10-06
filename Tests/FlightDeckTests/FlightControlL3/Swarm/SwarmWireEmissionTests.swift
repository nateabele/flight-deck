import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// The swarm projection is fleet state, so it goes through the replicator's drift check like
/// every other field — and it is the only place an account's display name reaches the wire.
@MainActor
final class SwarmWireEmissionTests: XCTestCase {
    private func setUp(_ rig: SwarmRig) -> (SessionStore, SwarmService, UUID) {
        let store = SessionStore(provider: nil, persistence: nil)
        let session = store.newSession(in: URL(fileURLWithPath: SwarmFixtures.project, isDirectory: true))
        let repo = store.repos.first { $0.sessions.contains { $0.id == session.id } }!.id
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        service.dependencies = SwarmDependencies(makeRouter: { [router = rig.router] in router }, kinds: rig.kinds, allocator: rig.allocator, capacity: rig.capacity)
        store.useSwarmService(service)
        return (store, service, repo)
    }

    func testLaunchingASwarmIsAnEventAndLeavesNoDrift() async {
        let rig = SwarmRig(); rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()), SwarmFixtures.task("fx-2", SwarmFixtures.block("other"))]
        let (store, service, repo) = setUp(rig)
        let replicator = attachedReplicator(to: store)
        store.startSwarmSummaries()
        _ = service.launch(project: SwarmFixtures.project, cap: 2, poolCaps: [:], filter: .allReady)
        await service.settle()
        store.refreshSwarmSummaries()
        XCTAssertTrue(replicator.recorded.contains {
            if case .projectSwarm(repo, let swarm?) = $0 { return swarm.agents.count == 1 && swarm.waiting == 1 }
            return false
        })
        XCTAssertEqual(replicator.snapshot().fleet, FleetProjection.snapshot(of: store))
    }

    func testTheAccountNameTravelsButNeverItsID() async throws {
        let rig = SwarmRig()
        let accountID = UUID()
        let lease = AccountLease(pool: "codex-subs", account: AccountRef(harness: "codex", id: accountID, label: "Work Account"))
        let agent = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        rig.store.save([rig.record(state: .paused, agents: [agent])])
        let (store, _, _) = setUp(rig)
        store.startSwarmSummaries()
        let encoded = String(decoding: try JSONEncoder().encode(FleetProjection.snapshot(of: store)), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Work Account"))
        XCTAssertFalse(encoded.contains(accountID.uuidString), "an account id resolves to a home and may not travel")
    }

    func testPauseResumeAndHandoffOverTheLocalSocket() async throws {
        let rig = SwarmRig(); rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let (store, service, repo) = setUp(rig)
        _ = service.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady)
        await service.settle()
        let harness = FleetTestHarness(store: store)
        let path = "/tmp/fdsw-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
        defer { harness.service.stop() }
        let client = FleetClient(localCaller: nil)
        defer { client.disconnect() }
        var replies: [Int: ServerFrame] = [:]
        let ready = expectation(description: "snapshot")
        let three = expectation(description: "three replies"); three.expectedFulfillmentCount = 3
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            if let cid = frame.correlationID { replies[cid] = frame; three.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ready], timeout: 5)
        let pause = client.send(FleetCommand.swarmPause(project: repo))
        let unknown = client.send(FleetCommand.swarmResume(project: UUID()))
        let handoff = client.send(FleetCommand.handoffConfirm(id: UUID()))
        await fulfillment(of: [three], timeout: 5)
        XCTAssertEqual(replies[pause], .ack(cid: pause))
        XCTAssertEqual(service.record(forProject: SwarmFixtures.project)?.state, .paused)
        XCTAssertEqual(replies[unknown], .err(cid: unknown, code: "unknown_project"))
        XCTAssertEqual(replies[handoff], .err(cid: handoff, code: "no_handoff"))
    }
}
