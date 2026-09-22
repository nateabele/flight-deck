import FleetKit
import XCTest

final class TranscriptHitWireTests: XCTestCase {
    /// The phone must decode the same legacy payload as the desk, and it cannot see `AgentID`
    /// at all — this pins the raw-string default independently of the desk-side test.
    func testPhoneDecodesPayloadMissingTheNewKeys() throws {
        let legacy = """
            {"rowID":7,"conversationID":"abc","projectPath":"/w/fd","conversationName":"n",
             "snippet":"s","timestamp":0,"offset":12}
            """
        let hit = try JSONDecoder().decode(TranscriptHit.self, from: Data(legacy.utf8))
        XCTAssertEqual(hit.agent, "claude")
        XCTAssertNil(hit.provenance)
        XCTAssertEqual(hit.workingDirectory, "")
        XCTAssertEqual(hit.transcriptPath, "")
    }
}
