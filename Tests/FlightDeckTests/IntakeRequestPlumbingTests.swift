import Network
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// `intake.detail` / `intake.plan` end to end: the connector's two request methods against a
/// real listener with a scripted `onRequest`, then the real `FleetService` arm over a real
/// socket with an intake seeded on disk.
@MainActor
final class IntakeRequestPlumbingTests: XCTestCase {
    private var server: FleetSocketServer!
    private var connector: FleetConnector!
    private var client: FleetClient!
    private var harness: FleetTestHarness!
    private var root: URL!
    private let key = FleetDeviceKey.mint()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeRequestPlumbing-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        connector?.stop()
        connector = nil
        client?.disconnect()
        client = nil
        server?.stop()
        server = nil
        harness = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func detail(_ etag: String) -> WireIntakeDetail {
        WireIntakeDetail(
            etag: etag, project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "T", state: "needsAnswers",
                                       needsAttention: true, createdAt: Date(timeIntervalSince1970: 1)),
            intent: "Plan the thing", servedAt: Date(timeIntervalSince1970: 2))
    }

    private func startConnector() async throws -> FleetConnector {
        server.onHello = { _, _ in [.snapshot(seq: 0, fleet: .empty, reason: .initial)] }
        let port = try await server.start(keys: [key], port: nil)
        let mac = PairedMac(
            key: key, macName: "Test", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"], lastSeq: 0
        )
        let store = InMemoryPairedMacStore()
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        let connected = expectation(description: "connected")
        connector.onState = { if case .connected = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 10)
        return connector
    }

    func testTheConnectorResolvesDetailPlanAndRefusalsThroughTheirOwnTables() async throws {
        let served = detail("e1")
        server.onRequest = { _, cid, request, reply in
            switch request {
            case .intakeDetail(_, let ifNot):
                reply(.intakeDetail(cid: cid, ifNot == "same" ? nil : served))
            case .intakePlan:
                reply(.err(cid: cid, code: "unknown_intake"))
            default: reply(.err(cid: cid, code: "unhandled"))
            }
        }
        let connector = try await startConnector()

        let unchanged = expectation(description: "unchanged")
        var first: Result<WireIntakeDetail?, FleetRequestError>?
        connector.requestIntakeDetail(id: UUID(), ifNot: "same") { first = $0; unchanged.fulfill() }
        let changed = expectation(description: "changed")
        var second: Result<WireIntakeDetail?, FleetRequestError>?
        connector.requestIntakeDetail(id: UUID(), ifNot: nil) { second = $0; changed.fulfill() }
        let refused = expectation(description: "refused")
        var third: Result<WireIntakePlan, FleetRequestError>?
        connector.requestIntakePlan(id: UUID(), checkpoint: nil, changes: false) { third = $0; refused.fulfill() }
        await fulfillment(of: [unchanged, changed, refused], timeout: 10)

        XCTAssertEqual(first, .success(nil))
        XCTAssertEqual(second, .success(served))
        XCTAssertEqual(third, .failure(.server(code: "unknown_intake")))
    }

    func testAPendingIntakeRequestFailsDisconnectedWhenTheConnectorStops() async throws {
        server.onRequest = { _, _, _, _ in }   // never answered
        let connector = try await startConnector()
        var detailResult: Result<WireIntakeDetail?, FleetRequestError>?
        var planResult: Result<WireIntakePlan, FleetRequestError>?
        connector.requestIntakeDetail(id: UUID(), ifNot: nil) { detailResult = $0 }
        connector.requestIntakePlan(id: UUID(), checkpoint: 1, changes: true) { planResult = $0 }
        XCTAssertNil(detailResult)
        connector.stop()
        XCTAssertEqual(detailResult, .failure(.disconnected))
        XCTAssertEqual(planResult, .failure(.disconnected))
    }

    // MARK: FleetService

    private func ask(_ request: FleetRequest, harness: FleetTestHarness) async throws -> ServerFrame {
        let answered = expectation(description: "answered")
        var reply: ServerFrame?
        var asked = 0
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            if let cid = frame.correlationID, cid == asked { reply = frame; answered.fulfill() }
        }
        client.onReady = { [weak self] in asked = self?.client.send(request) ?? 0 }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        client.disconnect()
        return try XCTUnwrap(reply)
    }

    func testTheServiceAnswersDetailHonoursIfNotAndRefusesUnknownIntakes() async throws {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        let repo = store.repos[0]
        var i = Intake(projectPath: repo.url.standardizedFileURL.path, intent: "Plan the thing")
        i.state = .needsAnswers
        i.exchanges = [TriageExchange(questions: ["Which README?"])]
        // Saved BEFORE the first touch of `store.intakeService`, which loads what is on disk
        // when it is built. `needsAnswers` has no tape, so no runner is ever spawned.
        try IntakeStore(root: root).save(i)
        harness = FleetTestHarness(store: store)
        try await harness.start()

        guard case .intakeDetail(_, let served?) = try await ask(.intakeDetail(id: i.id, ifNot: nil), harness: harness)
        else { return XCTFail("a seeded intake must be answered with its detail") }
        XCTAssertEqual(served.project, repo.id)
        XCTAssertEqual(served.intent, "Plan the thing")

        guard case .intakeDetail(_, let again) = try await ask(.intakeDetail(id: i.id, ifNot: served.etag), harness: harness)
        else { return XCTFail("wrong reply") }
        XCTAssertNil(again, "a matching etag is answered with nil")

        let unknown = try await ask(.intakeDetail(id: UUID(), ifNot: nil), harness: harness)
        guard case .err(_, let code, _) = unknown else { return XCTFail("expected err, got \(unknown)") }
        XCTAssertEqual(code, "unknown_intake")

        let plan = try await ask(.intakePlan(id: UUID(), checkpoint: nil, changes: false), harness: harness)
        guard case .err(_, let planCode, _) = plan else { return XCTFail("expected err, got \(plan)") }
        XCTAssertEqual(planCode, "unknown_intake")
    }
}
