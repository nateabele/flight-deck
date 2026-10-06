import FleetKit
import XCTest

/// `flightdeck new` prints the id the Mac names, not the first tab that happens to appear in the
/// project — which, with a swarm spawning in the same project, is often somebody else's.
@MainActor
final class CLINewSessionIDTests: XCTestCase {
    func testNewPrintsTheIDTheMacReturns() async throws {
        let server = FleetSocketServer()
        let path = "/tmp/fdnew-\(UUID().uuidString.prefix(8)).sock"
        let project = UUID(), created = UUID(), decoy = UUID()
        let fleet = FleetSnapshot(projects: [WireProject(id: project, name: "a", path: "/w/a", sessions: [])])
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onCommand = { _, cid, _, reply in
            // A swarm's tab lands in the same project first; the CLI must not print it.
            server.broadcast(.event(seq: 2, .sessionAdded(WireSession(id: decoy, title: "swarm", agent: "claude"), project: project, at: 0)))
            reply(.session(cid: cid, created))
        }
        try await server.startLocal(path: path)
        defer { server.stop(); unlink(path) }

        let transport = LocalFleetTransport(path: path, caller: nil)
        let finished = expectation(description: "runner finished")
        var printed: [String] = []
        var code: Int32?
        let runner = CLIRunner(
            invocation: try CLIArguments.parse(["new", "a"]),
            transport: transport,
            // A terminal, so `new` prints the bare id (a pipe would get JSON).
            context: CLIContext(selfID: nil, cwd: "/w/a", json: false, isTTY: true),
            out: { printed.append($0) }, err: { _ in },
            finish: { code = $0; finished.fulfill() },
            schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) })
        runner.run()
        await fulfillment(of: [finished], timeout: 5)
        transport.disconnect()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(printed, [created.uuidString])
    }
}
