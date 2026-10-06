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

    /// `ls` over the real socket with a snapshot several times one 8 KiB socket read. The
    /// live fleet's snapshot is ~23 KB; the line framer once delivered nothing longer than a
    /// single read, so this hung while the one-session fleet above passed.
    func testLsWithASnapshotLargerThanOneReadSucceeds() async throws {
        let server = FleetSocketServer()
        let path = "/tmp/fdcli-\(UUID().uuidString.prefix(8)).sock"
        let fleet = FleetSnapshot(projects: (0..<40).map { p in
            WireProject(id: UUID(), name: "project-\(p)", path: "/w/project-\(p)",
                        sessions: (0..<6).map { s in
                            WireSession(id: UUID(), title: "session \(p)-\(s) with a longish title",
                                        agent: "claude")
                        })
        })
        XCTAssertGreaterThan(try JSONEncoder().encode(fleet).count, 32 * 1024)
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        try await server.startLocal(path: path)
        defer {
            server.stop()
            unlink(path)
        }

        let transport = LocalFleetTransport(path: path, caller: nil)
        let finished = expectation(description: "runner finished")
        var code: Int32?
        var output = ""
        var errors: [String] = []
        let runner = CLIRunner(
            invocation: try CLIArguments.parse(["ls"]),
            transport: transport,
            context: CLIContext(selfID: nil, cwd: "/w", json: true, isTTY: false),
            out: { output += $0 }, err: { errors.append($0) },
            finish: { code = $0; finished.fulfill() },
            schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) })
        runner.run()
        await fulfillment(of: [finished], timeout: 3)
        transport.disconnect()

        XCTAssertEqual(code, 0, "\(errors)")
        XCTAssertTrue(output.contains("project-39"), "ls never printed the whole fleet")
    }
}
