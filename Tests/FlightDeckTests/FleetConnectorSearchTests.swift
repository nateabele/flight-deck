import Network
import XCTest
import FleetKit

/// `requestConversations`, `requestSearch` and `requestOpenConversation` — the connector's
/// own half of Task 6's three frames. Harness shape copied from
/// `FleetConnectorEndpointTests`, the closest existing analogue: each of these is a further
/// `pending*` table tested the same way the endpoint one already is — a reply must land on
/// its own `cid`, and a socket that dies mid-request must complete with `.disconnected`
/// rather than never at all.
@MainActor
final class FleetConnectorSearchTests: XCTestCase {
    private var servers: [FleetSocketServer] = []
    private var connector: FleetConnector?

    override func tearDown() {
        connector?.stop()
        servers.forEach { $0.stop() }
        servers = []
        connector = nil
        super.tearDown()
    }

    private func snapshot() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [])
        ])
    }

    /// `onRequest` never answers — the server holds the request open while the client tears
    /// down, the same shape
    /// `FleetConnectorEndpointTests.testADeadSocketFailsAnOutstandingEndpointRequest` uses.
    private func startUnansweredServer(key: FleetDeviceKey) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, _, _, _ in }
        servers.append(server)
        return try await server.start(keys: [key], port: nil)
    }

    private func connect(
        key: FleetDeviceKey, endpoints: [String], store: InMemoryPairedMacStore
    ) async -> FleetConnector {
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: endpoints
        )
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        let up = expectation(description: "connected")
        up.assertForOverFulfill = false
        connector.onState = { if case .connected = $0 { up.fulfill() } }
        connector.start()
        await fulfillment(of: [up], timeout: 5)
        return connector
    }

    // MARK: requestConversations

    func testAConversationsReplyLandsOnItsCid() async throws {
        let key = FleetDeviceKey.mint()
        let catalogue = WireConversationCatalogue(
            conversations: [WireConversation(id: "c1", name: "one", projectPath: "/w/fd")],
            sessionActivity: [:]
        )
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            guard case .conversations = request else {
                return reply(.err(cid: cid, code: "unhandled"))
            }
            reply(.conversations(cid: cid, catalogue))
        }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        let connector = await connect(
            key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store
        )

        let done = expectation(description: "answered")
        var received: WireConversationCatalogue?
        connector.requestConversations { result in
            if case .success(let value) = result { received = value }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(received, catalogue)
    }

    func testADeadSocketFailsAnOutstandingConversationsRequest() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startUnansweredServer(key: key)
        let store = InMemoryPairedMacStore()
        let connector = await connect(
            key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store
        )

        let drained = expectation(description: "drained")
        var received: FleetRequestError?
        connector.requestConversations { result in
            if case .failure(let error) = result { received = error }
            drained.fulfill()
        }
        connector.stop()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(received, .disconnected)
    }

    // MARK: requestSearch

    func testASearchReplyLandsOnItsCid() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            guard case .search = request else {
                return reply(.err(cid: cid, code: "unhandled"))
            }
            reply(.searchHits(cid: cid, WireSearchHits(hits: [], indexing: nil)))
        }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        let connector = await connect(
            key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store
        )

        let done = expectation(description: "answered")
        var received: WireSearchHits?
        connector.requestSearch(query: "hello", limit: 10) { result in
            if case .success(let value) = result { received = value }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(received, WireSearchHits(hits: [], indexing: nil))
    }

    func testADeadSocketFailsAnOutstandingSearchRequest() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startUnansweredServer(key: key)
        let store = InMemoryPairedMacStore()
        let connector = await connect(
            key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store
        )

        let drained = expectation(description: "drained")
        var received: FleetRequestError?
        connector.requestSearch(query: "hello", limit: 10) { result in
            if case .failure(let error) = result { received = error }
            drained.fulfill()
        }
        connector.stop()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(received, .disconnected)
    }

    // MARK: requestOpenConversation

    func testAnOpenConversationReplyLandsOnItsCid() async throws {
        let key = FleetDeviceKey.mint()
        let opened = UUID()
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            guard case .openConversation = request else {
                return reply(.err(cid: cid, code: "unhandled"))
            }
            reply(.session(cid: cid, opened))
        }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        let connector = await connect(
            key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store
        )

        let done = expectation(description: "answered")
        var received: UUID?
        connector.requestOpenConversation(
            conversationID: UUID().uuidString, projectPath: "/w/fd"
        ) { result in
            if case .success(let value) = result { received = value }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(received, opened)
    }

    func testADeadSocketFailsAnOutstandingOpenConversationRequest() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startUnansweredServer(key: key)
        let store = InMemoryPairedMacStore()
        let connector = await connect(
            key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store
        )

        let drained = expectation(description: "drained")
        var received: FleetRequestError?
        connector.requestOpenConversation(
            conversationID: UUID().uuidString, projectPath: "/w/fd"
        ) { result in
            if case .failure(let error) = result { received = error }
            drained.fulfill()
        }
        connector.stop()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(received, .disconnected)
    }
}
