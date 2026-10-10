import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

final class OpenCodeTimelineMapperTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String { OpenCodeEventMapper.encode(object) }

    func testAUserTurnShowsWhatTheUserTypedOnly() {
        let items = OpenCodeTimelineMapper.items(inLine: line([
            "type": "message", "id": "msg_1", "role": "user", "time": 1_791_000_000_000,
            "parts": [
                ["type": "text", "text": "fix the parser"],
                ["type": "text", "text": "<file contents>", "synthetic": true],
            ],
        ]), at: 40)
        XCTAssertEqual(items.map(\.kind), [.userTurn])
        XCTAssertEqual(items.first?.body.text, "fix the parser")
        XCTAssertEqual(items.first?.id, "40#0")
        XCTAssertNotNil(items.first?.at)
    }

    func testAnAssistantStepMapsEachPart() {
        let items = OpenCodeTimelineMapper.items(inLine: line([
            "type": "message", "id": "msg_2", "role": "assistant", "parts": [
                ["type": "reasoning", "text": "thinking about it"],
                ["type": "text", "text": "Listing files."],
                ["type": "tool", "tool": "bash", "callID": "call_1",
                 "state": ["status": "completed", "input": ["command": "ls"], "output": "a.py\n", "title": "ls"]],
                ["type": "tool", "tool": "read", "callID": "call_2",
                 "state": ["status": "error", "input": ["filePath": "/x/b.py"], "error": "no such file"]],
                ["type": "patch", "files": ["/x/a.py", "/x/b.py"]],
            ],
        ]), at: 0)
        XCTAssertEqual(items.map(\.kind), [
            .thinking, .assistantText, .toolCall, .toolResult, .toolCall, .toolResult, .systemNotice,
        ])
        XCTAssertEqual(items[2].body.callID, "call_1")
        XCTAssertEqual(items[2].body.summary, "ls")
        XCTAssertEqual(items[3].body.text, "a.py\n")
        XCTAssertEqual(items[4].body.summary, "/x/b.py", "OpenCode's camelCase filePath is previewed")
        XCTAssertTrue(items[5].body.isError)
    }

    /// A tool still marked running inside a SETTLED message was cut off. Left open it would
    /// read as a live permission dialog to `OpenPrompt.find` whenever the tab is waiting.
    func testACutOffToolIsClosed() {
        let items = OpenCodeTimelineMapper.items(inLine: line([
            "type": "message", "id": "msg_3", "role": "assistant",
            "error": ["name": "MessageAbortedError", "data": ["message": "Aborted"]],
            "parts": [["type": "tool", "tool": "bash", "callID": "call_9",
                       "state": ["status": "running", "input": ["command": "sleep 100"]]]],
        ]), at: 0)
        XCTAssertEqual(items.map(\.kind), [.toolCall, .toolResult, .systemNotice])
        XCTAssertEqual(items[1].body.callID, "call_9")
        XCTAssertEqual(items[2].body.text, "Interrupted")
    }

    // MARK: - Prompts, through the phone's own derivation

    private let permissionAsked = #"{"id":"per_1","kind":"permission","metadata":{"command":"ls"},"patterns":["ls"],"permission":"bash","time":1791000000000,"type":"prompt.asked"}"#
    private let permissionResolved = #"{"id":"per_1","outcome":"once","time":1791000001000,"type":"prompt.resolved"}"#
    private let questionAsked = #"{"id":"que_1","kind":"question","questions":[{"header":"Proceed","multiple":false,"options":[{"description":"Continue","label":"Yes"},{"description":"Stop here","label":"No"}],"question":"Proceed with the fake task?"}],"time":1791000000000,"type":"prompt.asked"}"#

    private func sourceLines(_ texts: [String]) -> [SourceLine] {
        texts.enumerated().map { SourceLine(offset: $0.offset * 100, text: $0.element) }
    }

    @MainActor
    func testAnOpenPermissionIsDerivedWithItsRequestIDAsTheCallID() {
        let open = OpenCodeOpenPromptReader().openPrompt(
            inTranscriptTail: sourceLines([permissionAsked]), activity: .waiting
        )
        XCTAssertEqual(open, .permission(callID: "per_1", tool: "bash", summary: "ls"))
    }

    @MainActor
    func testAResolvedPermissionIsNoLongerOpen() {
        XCTAssertNil(OpenCodeOpenPromptReader().openPrompt(
            inTranscriptTail: sourceLines([permissionAsked, permissionResolved]), activity: .waiting
        ))
    }

    @MainActor
    func testNothingIsOpenUnlessTheTabIsWaiting() {
        XCTAssertNil(OpenCodeOpenPromptReader().openPrompt(
            inTranscriptTail: sourceLines([permissionAsked]), activity: .busy
        ))
    }

    @MainActor
    func testAQuestionIsDerivedInTheSharedQuestionShape() throws {
        let open = try XCTUnwrap(OpenCodeOpenPromptReader().openPrompt(
            inTranscriptTail: sourceLines([questionAsked]), activity: .waiting
        ))
        guard case .question(let callID, let questions) = open else { return XCTFail("\(open)") }
        XCTAssertEqual(callID, "que_1")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "Proceed with the fake task?")
        XCTAssertEqual(questions[0].options.map(\.label), ["Yes", "No"])
        XCTAssertEqual(questions[0].options.first?.detail, "Continue")
        XCTAssertFalse(questions[0].multiSelect)
    }

    /// The same derivation the phone runs over its feed, which is why the agent string had to be
    /// admitted in FleetKit too.
    func testThePhonesDerivationAdmitsOpenCode() {
        let items = OpenCodeTimelineMapper.items(inLine: permissionAsked, at: 0)
        XCTAssertNotNil(OpenPrompt.find(in: items, agent: "opencode", activity: "waiting"))
        XCTAssertNil(OpenPrompt.find(in: items, agent: "someagent", activity: "waiting"))
    }
}
