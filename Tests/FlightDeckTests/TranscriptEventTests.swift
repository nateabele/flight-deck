import XCTest
@testable import FlightDeck

final class TranscriptEventTests: XCTestCase {
    private let sid = UUID()

    private func events(_ line: String) -> [ClaudeSession.TranscriptEvent] {
        ClaudeSession.events(inLine: line, sessionID: sid)
    }

    func testParsesCustomTitle() {
        let line = #"{"type":"custom-title","customTitle":"hello","sessionId":"\#(sid.uuidString.lowercased())"}"#
        XCTAssertEqual(events(line), [.title("hello")])
    }

    func testIgnoresCustomTitleForAnotherSession() {
        let line = #"{"type":"custom-title","customTitle":"hello","sessionId":"\#(UUID().uuidString.lowercased())"}"#
        XCTAssertEqual(events(line), [])
    }

    func testParsesAgentToolUse() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{}}]}}
        """#
        XCTAssertEqual(events(line), [.agentStarted("toolu_1"), .progressed])
    }

    func testParsesMultipleAgentToolUsesInOneRecord() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Agent"},{"type":"tool_use","id":"toolu_2","name":"Agent"}]}}
        """#
        XCTAssertEqual(events(line), [.agentStarted("toolu_1"), .agentStarted("toolu_2"), .progressed])
    }

    func testIgnoresNonAgentToolUse() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Bash"}]}}
        """#
        XCTAssertEqual(events(line), [.progressed])
    }

    /// Emitted for every tool_result; the watcher's set makes non-Agent ids a no-op.
    func testParsesToolResultAsAgentFinished() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1"}]}}
        """#
        XCTAssertEqual(events(line), [.agentFinished("toolu_1"), .progressed])
    }

    func testParsesTurnDuration() {
        let line = #"{"type":"system","subtype":"turn_duration","durationMs":1178896}"#
        XCTAssertEqual(events(line), [.turnEnded])
    }

    func testIgnoresOtherSystemSubtypes() {
        let line = #"{"type":"system","subtype":"stop_hook_summary"}"#
        XCTAssertEqual(events(line), [])
    }

    func testMalformedLineYieldsNothing() {
        XCTAssertEqual(events("not json"), [])
        XCTAssertEqual(events(""), [])
    }
}
