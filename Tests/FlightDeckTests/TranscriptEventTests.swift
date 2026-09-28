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

    /// claude 2.1.276+ launches every `Agent` in the background: its tool_result lands ~40ms
    /// after the tool_use and says only "launched". Reading that as the agent finishing is what
    /// zeroed the sidebar count inside a single poll.
    func testAsyncLaunchResultIsNotAgentFinished() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a8cc"}}
        """#
        XCTAssertEqual(events(line), [.agentLaunched(toolUseID: "toolu_1", agentID: "a8cc"), .progressed])
    }

    /// The real completion of a background agent: a user record whose content is the
    /// notification, naming the launching tool_use.
    func testTaskNotificationFinishesTheAgentItNames() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>a8cc</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>completed</status>\n<summary>Agent \"x\" finished</summary>\n</task-notification>"}}
        """#
        XCTAssertEqual(events(line), [.taskNotified(toolUseID: "toolu_1", taskID: "a8cc"), .progressed])
    }

    /// The same notification is enqueued the moment the agent stops, which can be long before
    /// a busy parent delivers it as a user record.
    func testQueuedTaskNotificationFinishesTheAgentItNames() {
        let line = #"""
        {"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>a8cc</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>completed</status>\n</task-notification>"}
        """#
        XCTAssertEqual(events(line), [.taskNotified(toolUseID: "toolu_1", taskID: "a8cc")])
    }

    /// A notification that arrived while the parent was mid-response is delivered as a queued
    /// command attachment — and its enqueue record can be written to the file *before* the
    /// launch it closes, so this later copy is the one that actually closes it.
    func testQueuedCommandAttachmentFinishesTheAgentItNames() {
        let line = #"""
        {"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>a8cc</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>completed</status>\n</task-notification>"}}
        """#
        XCTAssertEqual(events(line), [.taskNotified(toolUseID: "toolu_1", taskID: "a8cc")])
    }

    /// `SendMessage` to a stopped background agent wakes it; its result names the agent, and
    /// the agent's next notification reports under this call's tool-use id.
    func testSendMessageResumeIsAgentResumed() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sm","content":[{"type":"text","text":"ok"}]}]},"toolUseResult":{"success":true,"message":"Resuming agent a8cc","resumedAgentId":"a8cc"}}
        """#
        XCTAssertEqual(events(line), [.agentResumed(toolUseID: "toolu_sm", agentID: "a8cc"), .progressed])
    }

    /// Only a record that IS a notification counts — a person pasting one mid-message is prose.
    func testTaskNotificationQuotedInProseIsIgnored() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":"look at this: <task-notification><tool-use-id>toolu_1</tool-use-id></task-notification>"}}
        """#
        XCTAssertEqual(events(line), [.progressed])
    }

    func testIgnoresSystemRecords() {
        XCTAssertEqual(events(#"{"type":"system","subtype":"turn_duration","durationMs":1178896}"#), [])
        XCTAssertEqual(events(#"{"type":"system","subtype":"stop_hook_summary"}"#), [])
    }

    func testMalformedLineYieldsNothing() {
        XCTAssertEqual(events("not json"), [])
        XCTAssertEqual(events(""), [])
    }
}
