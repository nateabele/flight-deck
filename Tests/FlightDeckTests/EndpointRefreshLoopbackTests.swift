import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The refresh channel over a real TLS-PSK socket on loopback: a connected client asks the
/// Mac where it can be reached and gets an answer it could actually dial.
///
/// `FleetTestHarness` and this setup/teardown shape are copied from `AnswerLoopbackTests`.
@MainActor
final class EndpointRefreshLoopbackTests: XCTestCase {
    private var harness: FleetTestHarness?
    private var client: FleetClient?

    override func tearDown() async throws {
        client?.disconnect()
        harness?.service.stop()
        client = nil
        harness = nil
    }

    func testAConnectedClientCanAskTheMacForItsAddresses() async throws {
        let harness = FleetTestHarness()
        self.harness = harness
        _ = try await harness.start()

        let client = FleetClient(key: harness.key)
        self.client = client

        let answered = expectation(description: "endpoints")
        // `nonisolated(unsafe)` is not needed: the box is only read after `fulfillment`.
        let received = FrameBox()
        client.onFrame = { frame in
            if case .macEndpoints(_, let list) = frame {
                received.endpoints = list
                answered.fulfill()
            }
        }
        // Sent from `onReady`, exactly as `TimelineLoopbackTests` sends its own request: the
        // socket's very first frame must be `hello`, and `FleetSocketServer` cancels a `req`
        // that arrives on an unattached connection (§4). `onReady` fires after `hello` is on
        // the wire, so this cannot race ahead of it.
        client.onReady = { [weak client] in client?.send(FleetRequest.macEndpoints) }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)

        await fulfillment(of: [answered], timeout: 5)
        let endpoints = received.endpoints
        XCTAssertFalse(endpoints.isEmpty, "a listening Mac always has at least one address")
        XCTAssertTrue(endpoints.allSatisfy { $0.contains(":") })
        XCTAssertFalse(
            endpoints.contains { $0.hasPrefix("127.") },
            "loopback is dropped — a phone dialling it spends a race slot on itself"
        )
        XCTAssertLessThanOrEqual(endpoints.count, 4)
    }

    /// The rule the whole reply-frame family obeys. A `seq` here would let a client that
    /// refreshed its endpoints move the resume point it hands back on its next `hello`.
    func testTheReplyCarriesNoSeqAndItsTagIsUndotted() throws {
        let encoded = try JSONEncoder().encode(ServerFrame.macEndpoints(cid: 7, ["100.64.0.1:1234"]))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(json["seq"])
        let tag = try XCTUnwrap(json["t"] as? String)
        XCTAssertEqual(tag, "endpoints")
        // Undotted, so it cannot collide with the dotted `FleetEventTag` namespace that
        // `ServerFrame`'s decoder falls through to when no frame tag matches.
        XCTAssertFalse(tag.contains("."))
    }

    /// Round-trips, so a client and a Mac built from these sources agree on the shape.
    func testTheReplyRoundTrips() throws {
        let frame = ServerFrame.macEndpoints(cid: 3, ["100.64.0.1:1", "192.168.1.5:1"])
        let decoded = try JSONDecoder().decode(
            ServerFrame.self, from: try JSONEncoder().encode(frame)
        )
        XCTAssertEqual(decoded, frame)
    }

    /// Mutable state shared with a socket-queue callback, read only after `fulfillment`.
    private final class FrameBox: @unchecked Sendable {
        var endpoints: [String] = []
    }
}
