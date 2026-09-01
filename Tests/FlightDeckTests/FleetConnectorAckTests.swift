import Network
import XCTest
@testable import FleetKit

/// The connector's command half, against a real listener.
///
/// Until this existed a `cmd` from the phone was fire-and-forget: `send(_:)` returned `Void`
/// and `apply`'s `.ack` arm said so outright — *"an `ack` for a command matches nothing here
/// and is a no-op."* That is tolerable for `markRead`, whose effect arrives as a northbound
/// event or does not matter, and is not tolerable for a prompt, where being told nothing
/// leaves a person believing they told an agent something.
///
/// `browse: false` throughout, as every other connector test does: Bonjour on the build
/// machine finds whatever else is running and makes the race nondeterministic.
@MainActor
final class FleetConnectorAckTests: XCTestCase {
    private var server: FleetSocketServer!
    private var connector: FleetConnector!
    private let key = FleetDeviceKey.mint()
    private let session = UUID()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        connector?.stop()
        connector = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func prompt(_ text: String) -> FleetCommand {
        .prompt(id: session, token: UUID(), text: text)
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

    func testACommandWithACompletionIsAnsweredByItsAck() async throws {
        server.onCommand = { _, cid, _, reply in reply(.ack(cid: cid)) }
        let connector = try await startConnector()

        let answered = expectation(description: "acked")
        var result: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success = try XCTUnwrap(result) else {
            return XCTFail("an ack must resolve the command that earned it")
        }
    }

    /// The crossing test. A command's `err` and a request's `err` both arrive as the same
    /// frame shape, and the two tables share one `cid` space — so an implementation that
    /// tried them in the wrong table, or in only one, would deliver the refusal to the wrong
    /// caller. The request is deliberately left OUTSTANDING and asserted so, because "the
    /// command completion fired" alone passes just as happily when the fetch was stolen.
    func testACommandsErrReachesItsOwnCompletionAndLeavesAFetchAlone() async throws {
        server.onCommand = { _, cid, _, reply in reply(.err(cid: cid, code: "unsupported_agent")) }
        // Deliberately never answered, so the test can assert it is still waiting.
        server.onRequest = { _, _, _, _ in }
        let connector = try await startConnector()

        var pageResult: Result<TimelinePage, FleetRequestError>?
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) {
            pageResult = $0
        }

        let refused = expectation(description: "err reached the command")
        var commandResult: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { commandResult = $0; refused.fulfill() }
        await fulfillment(of: [refused], timeout: 10)

        guard case .failure(.server(let code)) = try XCTUnwrap(commandResult) else {
            return XCTFail("a command's err must reach the command's own completion")
        }
        XCTAssertEqual(code, "unsupported_agent")
        XCTAssertNil(pageResult, "the fetch was never answered and must still be waiting")
    }

    /// The rule that was already here and must survive: an `ack` correlated to a REQUEST is a
    /// server answering the wrong verb, and the caller is freed with a server error rather
    /// than left waiting.
    ///
    /// With a command deliberately left outstanding, because the survival half alone cannot
    /// be shown to fail for its own reason —
    /// `FleetConnectorRequestTests.testAnAckOnAPendingRequestReleasesItRatherThanStrandingIt`
    /// already asserts it, through `broadcast` rather than a reply, and no mutation of the
    /// connector can redden one without the other. What only this test holds is the crossing
    /// in the `ack` direction (the `err` direction is the test above): a `pendingAcks` that
    /// matched on anything but the `cid` would answer the WRONG caller here — resolving the
    /// command with a spurious `.success` while stranding the fetch — and would still pass
    /// every other test in both files, each of which has only one thing outstanding at a time.
    func testAnAckForARequestIsStillAnUnexpectedAckFailureAndLeavesACommandAlone() async throws {
        server.onRequest = { _, cid, _, reply in reply(.ack(cid: cid)) }
        // Swallowed, so the command stays outstanding and the test can assert it was not
        // answered by an `ack` that was never its own.
        server.onCommand = { _, _, _, reply in reply(.ack(cid: 0)) }
        let connector = try await startConnector()

        // Sent first, so it holds the LOWER cid: a table that ignores the number and takes
        // whatever it has filed reaches this one when the request's ack arrives.
        var commandResult: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { commandResult = $0 }

        let answered = expectation(description: "request answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) {
            result = $0
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.server(let code)) = try XCTUnwrap(result) else {
            return XCTFail("an ack is no answer to a question whose point is the data back")
        }
        XCTAssertEqual(code, "unexpected_ack")
        XCTAssertNil(commandResult, "the command earned no ack of its own and must still wait")
    }

    /// A socket that dies with a command outstanding must answer it. Without the drain the
    /// completion is never called at all — and a phone whose Mac went away mid-send is
    /// exactly the case this feature cannot get wrong.
    func testASocketThatDiesMidCommandAnswersDisconnected() async throws {
        // Swallowed: the command is received and never answered, so only the teardown can
        // resolve it.
        server.onCommand = { _, _, _, reply in reply(.ack(cid: 0)) }
        let connector = try await startConnector()

        let answered = expectation(description: "drained")
        var result: Result<Void, FleetRequestError>?
        connector.send(prompt("ship it")) { result = $0; answered.fulfill() }
        connector.stop()
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.disconnected) = try XCTUnwrap(result) else {
            return XCTFail("a command outstanding when the socket goes must be answered")
        }
    }

    /// The same asymmetry `request(_:then:)` documents, and for the same reason: a caller that
    /// arms a deadline before sending must be able to rely on the completion possibly having
    /// already run by the time `send` returns.
    func testSendingWithNoConnectionAnswersSynchronously() async throws {
        let connector = try await startConnector()
        connector.stop()

        var answeredBeforeReturning = false
        var returned = false
        connector.send(prompt("ship it")) { _ in answeredBeforeReturning = !returned }
        returned = true

        XCTAssertTrue(answeredBeforeReturning,
                      "with no socket the answer must come back inside the call, not later")
    }
}
