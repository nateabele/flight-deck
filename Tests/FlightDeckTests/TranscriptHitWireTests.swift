import FleetKit
import XCTest
import IntakeKit

@testable import FlightDeck

final class TranscriptHitWireTests: XCTestCase {
    /// A newer phone against an older Mac must degrade to today's behaviour rather than
    /// failing the whole frame. The old payload has none of the four new keys.
    func testDecodesPayloadMissingTheNewKeys() throws {
        let legacy = """
            {"rowID":7,"conversationID":"abc","projectPath":"/w/fd","conversationName":"n",
             "snippet":"s","timestamp":0,"offset":12}
            """
        let hit = try JSONDecoder().decode(TranscriptHit.self, from: Data(legacy.utf8))
        XCTAssertEqual(hit.agent, "claude")
        XCTAssertNil(hit.provenance)
        XCTAssertEqual(hit.workingDirectory, "")
        XCTAssertEqual(hit.transcriptPath, "")
        XCTAssertEqual(hit.rowID, 7)
    }

    /// The agent is carried as a raw string because FleetKit compiles for iOS and cannot see
    /// `AgentID`. This pins the two ends agreeing on the spelling.
    func testAgentStringRoundTripsThroughAgentID() throws {
        let hit = TranscriptHit(
            rowID: 1, conversationID: "c", projectPath: "/w/fd", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 0), offset: 0,
            agent: AgentID.codex.rawValue, provenance: "exec", workingDirectory: "/w/fd",
            transcriptPath: "/w/fd/.codex/rollout.jsonl"
        )
        let round = try JSONDecoder().decode(
            TranscriptHit.self, from: JSONEncoder().encode(hit)
        )
        XCTAssertEqual(AgentID(rawValue: round.agent), .codex)
        XCTAssertEqual(round.provenance, "exec")
        XCTAssertEqual(round.transcriptPath, "/w/fd/.codex/rollout.jsonl")
    }
}
