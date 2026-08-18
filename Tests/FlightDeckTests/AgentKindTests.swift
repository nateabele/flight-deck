import XCTest
@testable import FlightDeck

final class AgentKindTests: XCTestCase {
    func testAgentIDRoundTripsThroughItsRawValue() {
        // Persisted in sessions.json, so the raw values are a storage format, not a label.
        XCTAssertEqual(AgentID(rawValue: "claude"), .claude)
        XCTAssertEqual(AgentID(rawValue: "codex"), .codex)
        XCTAssertEqual(AgentID.claude.rawValue, "claude")
        XCTAssertNil(AgentID(rawValue: "cursor"), "unknown agents must not silently decode")
    }

    func testDisplayNamesAreUserFacing() {
        XCTAssertEqual(AgentID.claude.displayName, "Claude")
        XCTAssertEqual(AgentID.codex.displayName, "Codex")
    }

    func testBindingCarriesIdentityAndOptionalTranscript() {
        let id = UUID()
        let bare = AgentBinding(conversationID: id, transcriptURL: nil)
        XCTAssertEqual(bare.conversationID, id)
        XCTAssertNil(bare.transcriptURL, "an agent that reports no path is legal")
    }
}
