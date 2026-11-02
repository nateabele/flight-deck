import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's cloud path end to end against an in-process Mac (a real `FleetSocketServer` on
/// loopback, the pattern `FleetModelTests` uses): a `session.cloud` event drives the row icon's
/// data, and `infra.down`/`infra.extend` stream progress to their terminal frame.
@MainActor
final class CloudWiringTests: XCTestCase {
    private var server: FleetSocketServer!
    private let sessionID = UUID()

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    private static func wireMachine(_ name: String) -> WireInfraMachine {
        WireInfraMachine(name: name, cloud: "aws", instanceType: "g5.xlarge", region: "us-east-1", state: "ready",
                         network: "tailnet", hourlyUsd: 1.2, spentUsd: 3, ttlRemaining: 7200, monthUsd: 10,
                         monthCapUsd: nil, failure: nil, costLine: "")
    }

    private func connectedModel(
        cloud: WireSessionCloud? = nil, onInfra: @escaping (Int, InfraRequest, @escaping (ServerFrame) -> Void) -> Void = { _, _, _ in }
    ) async throws -> FleetModel {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        self.server = server
        let fleet = FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "me", path: "/Users/me",
                        sessions: [WireSession(id: sessionID, title: "Home", agent: "claude", cloud: cloud)])
        ])
        server.onHello = { _, _ in [.snapshot(seq: 0, fleet: fleet, reason: .initial)] }
        server.onCommand = { _, cid, _, reply in reply(.ack(cid: cid)) }
        server.onRequest = { _, cid, request, reply in
            switch request {
            case .infra(let infra): onInfra(cid, infra, reply)
            case .newSessionOptions(let project): reply(.newSessionOptions(cid: cid, WireNewSessionOptions(project: project, options: [])))
            case .conversations: reply(.conversations(cid: cid, WireConversationCatalogue(conversations: [], sessionActivity: [:])))
            case .recentlyClosed: reply(.recentlyClosed(cid: cid, []))
            default: break
            }
        }
        let port = try await server.start(keys: [key], port: nil)
        let store = InMemoryPairedMacStore()
        store.save(PairedMac(key: key, macName: "Studio", serviceName: "studio-cloud-tests._flightdeck._tcp",
                             endpoints: ["127.0.0.1:\(port.rawValue)"]))
        let model = FleetModel(store: store)
        try await waitUntil { model.fleet.projects.first?.sessions.count == 1 }
        XCTAssertEqual(model.fleet.projects.first?.sessions.count, 1, "the fixture fleet never arrived")
        return model
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func cloud(of model: FleetModel) -> WireSessionCloud? {
        model.fleet.projects.flatMap(\.sessions).first { $0.id == sessionID }?.cloud
    }

    func testThePhoneAsksForTheCloudCapabilityInItsHello() {
        XCTAssertTrue(FleetCapability.supported.contains(FleetCapability.cloud))
    }

    func testASnapshotWithCloudShowsTheIconAndACloudEventTogglesIt() async throws {
        let model = try await connectedModel(cloud: CloudFixtures.healthy)
        XCTAssertNotNil(cloud(of: model), "a snapshot carrying cloud draws the icon")

        server.broadcast(.event(seq: 1, .sessionCloudChanged(id: sessionID, cloud: nil)))
        try await waitUntil { cloud(of: model) == nil }
        XCTAssertNil(cloud(of: model), "the last machine going removes the icon")

        server.broadcast(.event(seq: 2, .sessionCloudChanged(id: sessionID, cloud: CloudFixtures.failed)))
        try await waitUntil { cloud(of: model) != nil }
        XCTAssertEqual(cloud(of: model)?.badge, .failed)
    }

    func testDestroyStreamsItsProgressLinesThenEndsOnInfraDone() async throws {
        let model = try await connectedModel { cid, request, reply in
            guard case .down(let name, nil) = request else { return XCTFail("wrong verb \(request)") }
            reply(.infraProgress(cid: cid, line: "destroying \(name)"))
            reply(.infraProgress(cid: cid, line: "removing firewall"))
            reply(.infraDone(cid: cid))
        }
        let cloudModel = SessionCloudModel(commander: model)
        var seen: [String] = []
        let result = await model.infra(.down(name: "gpu", orphanID: nil)) { seen.append($0) }
        XCTAssertEqual(result, .success(.done))
        XCTAssertEqual(seen, ["destroying gpu", "removing firewall"])
        await cloudModel.destroy("gpu")
        XCTAssertNil(cloudModel.activity["gpu"])
    }

    func testExtendEndsOnTheMachineAsItNowIs() async throws {
        let model = try await connectedModel { cid, request, reply in
            guard case .extend("gpu", 3600) = request else { return XCTFail("wrong verb \(request)") }
            reply(.infraMachine(cid: cid, Self.wireMachine("gpu")))
        }
        let result = await model.infra(.extend(name: "gpu", seconds: 3600)) { _ in }
        XCTAssertEqual(result, .success(.machine(Self.wireMachine("gpu"))))
    }

    func testAnErrCarriesItsCodeAndMessageAndAnOlderMacIsRecognised() async throws {
        let model = try await connectedModel { cid, request, reply in
            if case .extend = request {
                reply(.err(cid: cid, code: "infra_refused", message: "past the machine's own timer"))
            } else {
                reply(.err(cid: cid, code: "out_of_scope"))
            }
        }
        let refused = await model.infra(.extend(name: "gpu", seconds: 3600)) { _ in }
        XCTAssertEqual(refused, .failure(.server(code: "infra_refused", message: "past the machine's own timer")))
        let old = await model.infra(.down(name: "gpu", orphanID: nil)) { _ in }
        XCTAssertEqual(old, .failure(.server(code: "out_of_scope", message: nil)))
        if case .failure(let error) = old { XCTAssertTrue(error.isMacTooOld) }
    }

    func testWithNoMacTheRequestAnswersDisconnectedRatherThanHanging() async {
        let model = FleetModel.fixture()
        let result = await model.infra(.list(orphans: false)) { _ in }
        XCTAssertEqual(result, .failure(.disconnected))
    }
}
