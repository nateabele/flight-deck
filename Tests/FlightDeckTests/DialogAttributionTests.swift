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
        XCTAssertEqual(a.apply(line("PermissionRequest")),
                       .raised(sid, PendingDialog(agentID: "a28ad87b", callID: "toolu_X")))
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

    /// Review Focus 4: a new user turn means the old dialog is gone.
    func testUserPromptSubmitClearsThePendingDialog() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X"))
        guard case .promptSubmitted(let id, _)? = a.apply(line("UserPromptSubmit")) else {
            return XCTFail("expected promptSubmitted")
        }
        XCTAssertEqual(id, sid)
    }

    func testPostToolUseForTheAttributedCallClearsIt() {
        var a = DialogAttribution()
        _ = a.apply(line("PermissionRequest", agent: "a28ad87b", toolUseID: "toolu_X"))
        XCTAssertEqual(a.apply(line("PostToolUse", agent: "a28ad87b", toolUseID: "toolu_X")), .cleared(sid))
    }
}
