import FleetKit
import XCTest
@testable import FlightDeck

/// Spec §5: `session.new` used to ack before creating and never named the tab. It now answers
/// after creation with the tab's id, which is what lets the CLI and the phone address what they
/// started. Driven over the real local socket.
@MainActor
final class SessionNewReplyTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient?
    private var path = ""

    override func setUp() async throws {
        harness = FleetTestHarness()
        path = "/tmp/fdsn-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
    }
    override func tearDown() async throws {
        client?.disconnect(); harness.service.stop(); harness = nil
    }

    private func send(_ command: FleetCommand) async -> ServerFrame? {
        let client = FleetClient(localCaller: nil); self.client = client
        let ready = expectation(description: "snapshot")
        let replied = expectation(description: "reply")
        var cid = 0
        var reply: ServerFrame?
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            if frame.correlationID == cid, cid != 0 { reply = frame; replied.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ready], timeout: 5)
        cid = client.send(command)
        await fulfillment(of: [replied], timeout: 5)
        return reply
    }

    func testSessionNewAnswersWithTheNewTabsID() async throws {
        let existing = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha", isDirectory: true))
        let project = try XCTUnwrap(harness.store.repos.first { $0.sessions.contains { $0.id == existing.id } }?.id)
        guard case .session(_, let id)? = await send(.newSession(project: project)) else {
            return XCTFail("expected a .session reply")
        }
        XCTAssertNotEqual(id, existing.id)
        XCTAssertTrue(harness.store.sessionExists(id))
    }

    func testAnUnknownProjectIsStillRefused() async {
        guard case .err(_, "unknown_project")? = await send(.newSession(project: UUID())) else {
            return XCTFail("expected unknown_project")
        }
    }
}
