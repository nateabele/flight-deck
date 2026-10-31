import XCTest
@testable import FleetKit

@MainActor
final class FleetLocalClientTests: XCTestCase {
    func testALocalClientAttachesWithItsCallerAndGetsAnswers() async throws {
        let path = "/tmp/fdlc-\(UUID().uuidString.prefix(8)).sock"
        let server = FleetSocketServer()
        defer { server.stop() }
        var caller: String?
        server.onHello = { attachment, _ in
            caller = attachment.caller
            return [.snapshot(seq: 1, fleet: FleetSnapshot(), reason: .initial)]
        }
        server.onRequest = { _, cid, _, reply in reply(.recentlyClosed(cid: cid, [])) }
        try await server.startLocal(path: path)

        let client = FleetClient(localCaller: "tok")
        defer { client.disconnect() }
        let answered = expectation(description: "reply")
        var cid = 0
        client.onFrame = { frame in
            if case .snapshot = frame { cid = client.send(FleetRequest.recentlyClosed) }
            if case .recentlyClosed(let got, _) = frame, got == cid { answered.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertEqual(caller, "tok")
    }

    func testConnectingToNothingDisconnectsRatherThanHanging() async {
        // What `flightdeck` turns into exit 69: the app is not running.
        let client = FleetClient(localCaller: nil)
        let ended = expectation(description: "disconnect")
        client.onDisconnect = { _ in ended.fulfill() }
        client.connect(toLocal: "/tmp/fd-nothing-\(UUID().uuidString.prefix(8)).sock", lastSeq: 0)
        await fulfillment(of: [ended], timeout: 5)
    }
}
