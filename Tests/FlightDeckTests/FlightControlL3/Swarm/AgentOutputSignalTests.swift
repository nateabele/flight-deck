import XCTest
import IntakeKit

/// The guard's block message is an exact, capturable string (spike findings), and it reaches FD
/// inside an agent's own records — claude's transcript tool_result, codex's rollout exec output.
/// The scan reads every string leaf of a record, so it does not care which shape carries it; and
/// `BLOCKED:` counts only in text the AGENT wrote, never in the prompt that asked for it.
final class AgentOutputSignalTests: XCTestCase {
    private func capturedMessage() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "guard-block", withExtension: "txt",
                                                           subdirectory: "Fixtures/FlightControlL3/Swarm"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(AgentOutputScan.guardMarker))
        return text
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheCapturedGuardMessageParses() throws {
        let blocks = AgentOutputScan.guardBlocks(in: try capturedMessage())
        XCTAssertEqual(blocks.count, 1)
        XCTAssertFalse(blocks[0].file.isEmpty)
        XCTAssertFalse(blocks[0].pattern.isEmpty)
        XCTAssertEqual(blocks[0].file, "Sources/Foo.swift")
        XCTAssertEqual(blocks[0].pattern, "Sources/*.swift")
        XCTAssertEqual(blocks[0].holder, "GreenFox")
        XCTAssertFalse(blocks[0].message.contains("\n"), "the drawer quotes one line")
    }

    func testTheSpikeMessageParsesExactly() {
        XCTAssertEqual(AgentOutputScan.guardBlocks(in: "Exit code 1\nmcp-agent-mail: file reservation conflict detected! widget.py conflicts with reservation 'widget.py' held by BlueFalcon\n"),
                       [GuardBlock(file: "widget.py", pattern: "widget.py", holder: "BlueFalcon",
                                   message: "mcp-agent-mail: file reservation conflict detected! widget.py conflicts with reservation 'widget.py' held by BlueFalcon")])
    }

    func testAClaudeToolResultCarriesIt() throws {
        let msg = "mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with reservation 'Sources/*.swift' held by GreenFox"
        let record: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "Exit code 1\n" + msg]]]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        XCTAssertEqual(AgentOutputScan.signals(line: line, record: record),
                       [.guardBlock(GuardBlock(file: "Sources/Foo.swift", pattern: "Sources/*.swift", holder: "GreenFox", message: msg))])
    }

    func testACodexExecEndCarriesItOnceEvenInTwoFields() throws {
        let msg = "mcp-agent-mail: file reservation conflict detected! a.swift conflicts with reservation 'a.swift' held by RedStone"
        let record: [String: Any] = ["type": "event_msg", "payload": ["type": "exec_command_end", "stderr": msg, "aggregated_output": msg]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        XCTAssertEqual(AgentOutputScan.signals(line: line, record: record).count, 1)
    }

    func testBlockedCountsOnlyInTheAgentsOwnText() throws {
        let claude = try object(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Working.\nBLOCKED: Sources/Foo.swift is reserved by GreenFox"}]}}"#)
        XCTAssertEqual(AgentOutputScan.signals(line: "BLOCKED:", record: claude), [.blocked("Sources/Foo.swift is reserved by GreenFox")])
        let prompt = try object(#"{"type":"user","message":{"content":"If you are blocked, say so in one line that starts with BLOCKED:, then stop."}}"#)
        XCTAssertEqual(AgentOutputScan.signals(line: "BLOCKED:", record: prompt), [], "the task prompt is not the agent")
        let codex = try object(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"BLOCKED: waiting on a.swift"}]}}"#)
        XCTAssertEqual(AgentOutputScan.signals(line: "BLOCKED:", record: codex), [.blocked("waiting on a.swift")])
    }

    func testALineWithoutAMarkerIsNotParsed() throws {
        XCTAssertEqual(AgentOutputScan.signals(line: #"{"type":"assistant"}"#, record: ["type": "assistant"]), [])
    }
}
