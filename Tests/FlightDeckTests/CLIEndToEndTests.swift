import FleetKit
import XCTest

/// `CLIRunner` over the real `LocalFleetTransport` and a real `FleetSocketServer.startLocal`.
///
/// Every other runner test drives `FakeTransport`, which cannot notice `LocalFleetTransport`
/// failing to forward `onReady`/`onFrame`/`onDisconnect` to its `FleetClient`: a dropped
/// forward there is a CLI that connects, is answered, and hangs forever on a frame it never
/// sees. This is the one test that crosses that seam.
@MainActor
final class CLIEndToEndTests: XCTestCase {
    func testSendSelfOverTheRealLocalSocketIsAckedAndExitsZero() async throws {
        let server = FleetSocketServer()
        let path = "/tmp/fdcli-\(UUID().uuidString.prefix(8)).sock"
        let session = UUID()
        let fleet = FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "a", path: "/w/a",
                        sessions: [WireSession(id: session, title: "alpha", agent: "claude")]),
        ])
        var received: FleetCommand?
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onCommand = { _, cid, command, reply in
            received = command
            reply(.ack(cid: cid))
        }
        try await server.startLocal(path: path)
        defer {
            server.stop()
            unlink(path)
        }

        let transport = LocalFleetTransport(path: path, caller: nil)
        let finished = expectation(description: "runner finished")
        var code: Int32?
        var errors: [String] = []
        let runner = CLIRunner(
            invocation: try CLIArguments.parse(["send", "self", "hi"]),
            transport: transport,
            context: CLIContext(selfID: session, cwd: "/w/a", json: true, isTTY: false),
            out: { _ in }, err: { errors.append($0) },
            finish: { code = $0; finished.fulfill() },
            schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) })
        runner.run()
        await fulfillment(of: [finished], timeout: 5)
        transport.disconnect()

        XCTAssertEqual(code, 0, "\(errors)")
        guard case .prompt(session, _, "hi") = received else {
            return XCTFail("the Mac never saw the prompt: \(String(describing: received))")
        }
    }
}
