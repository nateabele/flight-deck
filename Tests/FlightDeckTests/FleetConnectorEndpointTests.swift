import Network
import XCTest
import FleetKit

/// The refresh as the client sees it. Harness shape copied from `FleetConnectorTests`.
@MainActor
final class FleetConnectorEndpointTests: XCTestCase {
    private var servers: [FleetSocketServer] = []
    private var connector: FleetConnector?

    override func tearDown() {
        connector?.stop()
        servers.forEach { $0.stop() }
        servers = []
        connector = nil
        super.tearDown()
    }

    /// The answer is set AFTER `start()` returns, because a realistic answer has to name the
    /// port the server just bound.
    private final class Answer: @unchecked Sendable {
        var endpoints: [String] = []
        var code: String?
    }

    private func snapshot() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [])
        ])
    }

    private func startServer(key: FleetDeviceKey, answer: Answer) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            guard case .macEndpoints = request else {
                return reply(.err(cid: cid, code: "unhandled"))
            }
            if let code = answer.code { reply(.err(cid: cid, code: code)) }
            else { reply(.macEndpoints(cid: cid, answer.endpoints)) }
        }
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

    /// Every snapshot is every connect, and it is the only hook the refresh has — addresses
    /// have no push path.
    func testTheConnectorAsksForEndpointsOnSnapshotArrival() async throws {
        let key = FleetDeviceKey.mint()
        let asked = expectation(description: "asked")
        asked.assertForOverFulfill = false
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            if case .macEndpoints = request { asked.fulfill() }
            reply(.macEndpoints(cid: cid, ["100.64.0.1:9"]))
        }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)
        _ = await connect(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: InMemoryPairedMacStore())
        await fulfillment(of: [asked], timeout: 5)
    }

    /// The Mac enumerated its own interfaces, so its answer is authoritative for membership:
    /// an address it no longer claims is exactly the stale candidate this request removes.
    func testAReplyReplacesTheStoredEndpoints() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"
        answer.endpoints = ["100.64.0.1:9", live]

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live, "192.0.2.1:9"], store: store)

        let done = expectation(description: "refreshed")
        connector.requestMacEndpoints { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        // "192.0.2.1:9" is gone — the Mac never claimed it.
        XCTAssertEqual(Set(store.load()?.endpoints ?? []), Set(["100.64.0.1:9", live]))
    }

    /// `promote()` keeps whichever address last won a race at the front. A refresh must not
    /// throw that away when the Mac still claims the address.
    func testTheLastSuccessfulEndpointStaysAtTheFrontWhenTheMacStillClaimsIt() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"
        // The Mac ranks the tunnel first; the client has just proved `live` works.
        answer.endpoints = ["100.64.0.1:9", live]

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live], store: store)

        let done = expectation(description: "refreshed")
        connector.requestMacEndpoints { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(store.load()?.endpoints.first, live,
                       "promotion must survive a refresh that still contains the address")
    }

    /// "Absent" and "empty" mean opposite things. We are reading this frame over one of the
    /// Mac's addresses, so a reply saying it has none must not erase the one that is working.
    func testAnEmptyReplyIsIgnored() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"
        answer.endpoints = []

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live], store: store)

        let done = expectation(description: "answered")
        connector.requestMacEndpoints { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(store.load()?.endpoints, [live])
    }

    /// An older Mac answers `unsupported`/`unhandled`. That must be a soft failure that
    /// leaves the phone exactly as it was — the compatibility rule the whole wire obeys.
    func testAnErrReplyLeavesTheStoredListIntact() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        answer.code = "unsupported"
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live], store: store)

        let failed = expectation(description: "failed")
        var received: FleetRequestError?
        connector.requestMacEndpoints { result in
            if case .failure(let error) = result { received = error }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(received, .server(code: "unsupported"))
        XCTAssertEqual(store.load()?.endpoints, [live])
    }

    /// The fourth pending table has to drain with the other three, or a client whose socket
    /// dies with a refresh outstanding waits forever.
    func testADeadSocketFailsAnOutstandingEndpointRequest() async throws {
        let key = FleetDeviceKey.mint()
        // Never answered: the server holds the request while the client tears down.
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, _, _, _ in }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store)

        let drained = expectation(description: "drained")
        var received: FleetRequestError?
        connector.requestMacEndpoints { result in
            if case .failure(let error) = result { received = error }
            drained.fulfill()
        }
        connector.stop()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(received, .disconnected)
    }
}
