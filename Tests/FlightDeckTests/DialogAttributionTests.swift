import XCTest
@testable import FlightDeck

final class DialogAttributionTests: XCTestCase {
    private let sid = UUID()
    private func line(_ event: String, agent: String? = nil, tool: String = "Bash",
                      input: String = #"{"command":"rm -rf x"}"#, toolUseID: String? = nil) -> HookEventRecord {
        var obj = #"{"session_id":"\#(sid.uuidString.lowercased())","hook_event_name":"\#(event)","tool_name":"\#(tool)","tool_input":\#(input)"#
        if let agent { obj += #","agent_id":"\#(agent)","agent_type":"implementer""# }
        if let toolUseID { obj += #","tool_use_id":"\#(toolUseID)""# }
        return HookEventRecord.decode(obj + "}")!
    }

    func testAPermissionRequestCarryingItsIDsIsAttributedDirectly() {
        var a = DialogAttribution()
        XCTAssertEqual(a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X")),
                       .raised(sid, PendingDialog(agentID: "a28ad87b", callID: "toolu_X")))
    }

    func testWithoutIDsItMatchesThePrecedingPreToolUse() {
        var a = DialogAttribution()
        _ = a.apply(line("PreToolUse", agent: "a1111111", input: #"{"command":"ls"}"#, toolUseID: "toolu_OTHER"))
        _ = a.apply(line("PreToolUse", agent: "a28ad87b", toolUseID: "toolu_X"))
        // A real subagent PermissionRequest carries agent_id but no tool_use_id.
        XCTAssertEqual(a.apply(line("PermissionRequest", agent: "a28ad87b")),
                       .raised(sid, PendingDialog(agentID: "a28ad87b", callID: "toolu_X")))
    }

    /// An id-less, agent-less request is the main agent's: a subagent's identical recent call
    /// must not steal it.
    func testAMainAgentRequestNeverMatchesASubagentsIdenticalCall() {
        var a = DialogAttribution()
        _ = a.apply(line("PreToolUse", toolUseID: "toolu_MAIN"))
        _ = a.apply(line("PreToolUse", agent: "a28ad87b", toolUseID: "toolu_SUB"))
        XCTAssertEqual(a.apply(line("PermissionRequest")),
                       .raised(sid, PendingDialog(agentID: nil, callID: "toolu_MAIN")))
    }

    func testTheMainAgentsDialogHasNoAgentID() {
        var a = DialogAttribution()
        _ = a.apply(line("PreToolUse", toolUseID: "toolu_MAIN"))
        XCTAssertEqual(a.apply(line("PermissionRequest")),
                       .raised(sid, PendingDialog(agentID: nil, callID: "toolu_MAIN")))
    }

    /// Review Focus 3: never guess.
    func testNoPermissionRequestMeansNoPendingDialog() {
        var a = DialogAttribution()
        XCTAssertNil(a.apply(line("PreToolUse", agent: "a28ad87b", toolUseID: "toolu_X")))
        XCTAssertNil(a.apply(line("PermissionRequest", agent: "a28ad87b",
                                  input: #"{"command":"never seen"}"#)),
                     "no matching PreToolUse and no tool_use_id: nothing is attributed")
    }

    /// Review Focus 4: a new user turn means the main agent's old dialog is gone — the only
    /// way to submit one past it is Esc, which fires no hook.
    func testUserPromptSubmitClearsTheMainAgentsPendingDialog() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", toolUseID: "toolu_X"))
        guard case .promptSubmitted(let id, _)? = a.apply(line("UserPromptSubmit")) else {
            return XCTFail("expected promptSubmitted")
        }
        XCTAssertEqual(id, sid)
        XCTAssertNil(a.apply(line("PostToolUse", toolUseID: "toolu_X")), "already cleared")
    }

    /// "The Plan" (2026-10-09): a background task finishing is delivered to the parent as a
    /// new user turn, with a subagent's dialog still on screen. That turn says nothing about
    /// the subagent's dialog, which stays attributed until its own PostToolUse.
    func testASubagentsDialogOutlivesTheParentsNextTurn() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X"))
        guard case .promptSubmitted? = a.apply(line("UserPromptSubmit")) else {
            return XCTFail("expected promptSubmitted")
        }
        XCTAssertEqual(a.apply(line("PostToolUse", agent: "a28ad87b", toolUseID: "toolu_X")), .cleared(sid))
    }

    func testPostToolUseForTheAttributedCallClearsIt() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X"))
        XCTAssertEqual(a.apply(line("PostToolUse", agent: "a28ad87b", toolUseID: "toolu_X")), .cleared(sid))
    }
}
