import FleetKit
import XCTest
@testable import FlightDeck

@MainActor
final class FleetLocalControlTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient?
    private var path = ""

    override func setUp() async throws {
        harness = FleetTestHarness()
        path = "/tmp/fdfs-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
    }

    override func tearDown() async throws {
        client?.disconnect()
        harness.service.stop()
        harness = nil
    }

    /// Connects locally and returns once the initial snapshot arrives.
    private func attach(caller: String? = nil, onFrame: @escaping (ServerFrame) -> Void = { _ in })
        async -> FleetClient {
        let client = FleetClient(localCaller: caller)
        self.client = client
        let ready = expectation(description: "snapshot")
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            onFrame(frame)
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ready], timeout: 5)
        return client
    }

    func testALocalClientSeesTheFleetAndItsChanges() async throws {
        let store = harness.store
        let renamed = expectation(description: "renamed event")
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        _ = await attach { frame in
            if case .event(_, .renamed(let id, "Renamed", _)) = frame, id == session.id { renamed.fulfill() }
        }
        XCTAssertTrue(store.rename(session.id, to: "Renamed"))
        await fulfillment(of: [renamed], timeout: 5)
    }

    func testAScopedAgentIsRefusedAnotherTabButMayMarkItsOwn() async throws {
        let store = harness.store
        let mine = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let theirs = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        store.markUnread(mine.id); store.markUnread(theirs.id)
        harness.service.scopeLevel = { .ownSession }
        let token = ControlEnvironment.token(for: mine.id, secret: harness.service.controlSecret)
        var replies: [Int: ServerFrame] = [:]
        let two = expectation(description: "two replies"); two.expectedFulfillmentCount = 2
        let client = await attach(caller: token) { frame in
            if let cid = frame.correlationID { replies[cid] = frame; two.fulfill() }
        }
        let refused = client.send(FleetCommand.markRead(id: theirs.id))
        let allowed = client.send(FleetCommand.markRead(id: mine.id))
        await fulfillment(of: [two], timeout: 5)
        XCTAssertEqual(replies[refused], .err(cid: refused, code: "out_of_scope"))
        XCTAssertEqual(replies[allowed], .ack(cid: allowed))
    }

    func testAScopedAgentCannotOpenAConversation() async throws {
        harness.service.scopeLevel = { .readOnly }
        let token = ControlEnvironment.token(for: UUID(), secret: harness.service.controlSecret)
        let refused = expectation(description: "refused")
        var cid = 0
        let client = await attach(caller: token) { frame in
            if case .err(let got, "out_of_scope", _) = frame, got == cid { refused.fulfill() }
        }
        cid = client.send(FleetRequest.openConversation(conversationID: UUID().uuidString, projectPath: "/w"))
        await fulfillment(of: [refused], timeout: 5)
    }

    func testALocalViewingDoesNotLightThePhoneBadge() async throws {
        let session = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let acked = expectation(description: "ack")
        var cid = 0
        let client = await attach { if case .ack(let got) = $0, got == cid { acked.fulfill() } }
        cid = client.send(FleetCommand.viewing(session: session.id))
        await fulfillment(of: [acked], timeout: 5)
        XCTAssertTrue(harness.service.phoneActiveSessions.isEmpty)
    }

    func testAPhoneKeyReloadDoesNotDropALocalClient() async throws {
        _ = try await harness.start()           // the phone listener
        var disconnected = false
        let client = await attach()
        client.onDisconnect = { _ in disconnected = true }
        _ = try await harness.service.start()   // what every arm/expiry/revoke does
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(disconnected)
    }
}
