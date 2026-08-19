import XCTest
@testable import FlightDeck

final class AgentPersistenceTests: XCTestCase {
    func testASessionDefaultsToClaude() {
        // Every session that exists today is a claude session; the default is what makes
        // the migration a no-op rather than a data change.
        XCTAssertEqual(Session(title: "t", workingDirectory: "/w").agent, .claude)
    }

    func testAnEntryWithNoAgentFieldDecodesAsClaude() throws {
        // Exactly the shape already on disk in sessions.json — no `agent` key at all.
        let json = """
        {"id":"\(UUID().uuidString)","title":"old","workingDirectory":"/w"}
        """
        let entry = try JSONDecoder().decode(SessionSnapshot.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.agent ?? .claude, .claude, "old snapshots must migrate by omission")
    }

    func testACodexEntryRoundTrips() throws {
        var entry = SessionSnapshot.Entry(id: UUID(), title: "t", workingDirectory: "/w")
        entry.agent = .codex
        entry.transcriptPath = "/Users/x/.codex/sessions/2026/08/18/rollout-abc.jsonl"

        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(SessionSnapshot.Entry.self, from: data)

        XCTAssertEqual(back.agent, .codex)
        XCTAssertEqual(back.transcriptPath, entry.transcriptPath)
    }
}
