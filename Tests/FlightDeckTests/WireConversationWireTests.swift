import FleetKit
import XCTest

final class WireConversationWireTests: XCTestCase {
    /// A newer phone against an older Mac must degrade to today's behaviour rather than
    /// failing the whole catalogue — `WireConversationCatalogue` decodes its `conversations`
    /// array in one shot, so one old-shaped element would otherwise lose every conversation
    /// in the reply.
    func testDecodesPayloadMissingTheAgentKey() throws {
        let legacy = """
            {"id":"abc","name":"old chat","projectPath":"/w/fd"}
            """
        let conversation = try JSONDecoder().decode(
            WireConversation.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(conversation.agent, "claude")
        XCTAssertEqual(conversation.id, "abc")
    }

    /// A codex conversation must round-trip as codex, not silently degrade to the "claude"
    /// default — that default exists for version skew, not to overwrite a value that was
    /// actually sent.
    func testCodexAgentRoundTrips() throws {
        let conversation = WireConversation(
            id: "abc", name: "old chat", projectPath: "/w/fd", agent: "codex"
        )
        let round = try JSONDecoder().decode(
            WireConversation.self, from: JSONEncoder().encode(conversation)
        )
        XCTAssertEqual(round.agent, "codex")
    }
}
