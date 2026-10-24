import FleetKit
import XCTest
@testable import FlightDeck

@MainActor
final class CodexNativeDialogsTests: XCTestCase {
    private final class Transport: CodexTransport {
        var onLine: ((String) -> Void)?
        var sent: [String] = []
        func send(_ line: String) { sent.append(line) }
    }

    private func make() -> (CodexNativeDialogs, Transport) {
        let transport = Transport()
        return (CodexNativeDialogs(rpc: CodexRPC(transport: transport)), transport)
    }

    private func choose(_ open: OpenPrompt, _ index: Int) -> PromptAnswer {
        guard case .question(_, let questions) = open else { return .deny }
        return .option(index: index, label: questions[0].options[index].label)
    }

    func testEveryOfferedApprovalDecisionTravelsUnchangedAndOnlyOnce() throws {
        let decisions: [Any] = ["accept", "acceptForSession", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", "status"]]], "decline", "cancel"]
        for index in decisions.indices {
            let (dialogs, transport) = make()
            let thread = UUID()
            dialogs.receive(id: "approval", method: "item/commandExecution/requestApproval",
                params: ["threadId": thread.uuidString, "command": "git status", "availableDecisions": decisions])
            let open = try XCTUnwrap(dialogs.openPrompt(for: thread))
            XCTAssertTrue(dialogs.answer(open, with: choose(open, index), thread: thread))
            XCTAssertFalse(dialogs.answer(open, with: choose(open, index), thread: thread))
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(transport.sent[0].utf8)) as? [String: Any])
            let actual = try XCTUnwrap((response["result"] as? [String: Any])?["decision"])
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: actual, options: [.fragmentsAllowed, .sortedKeys]),
                           try JSONSerialization.data(withJSONObject: decisions[index], options: [.fragmentsAllowed, .sortedKeys]))
            XCTAssertNotNil(dialogs.openPrompt(for: thread), "wait for the server's resolution")
            dialogs.notify("serverRequest/resolved", params: ["threadId": thread.uuidString, "requestId": "approval"])
            XCTAssertNil(dialogs.openPrompt(for: thread))
        }
    }

    func testStaleGenerationWrongThreadAndChangedLabelsCannotAnswer() throws {
        let (dialogs, transport) = make()
        let (replacement, _) = make()
        let thread = UUID()
        let params: [String: Any] = ["threadId": thread.uuidString, "availableDecisions": ["accept", "cancel"]]
        dialogs.receive(id: 0, method: "item/fileChange/requestApproval", params: params)
        replacement.receive(id: 0, method: "item/fileChange/requestApproval", params: params)
        let open = try XCTUnwrap(dialogs.openPrompt(for: thread))
        XCTAssertFalse(replacement.answer(open, with: choose(open, 0), thread: thread))
        XCTAssertFalse(dialogs.answer(open, with: choose(open, 0), thread: UUID()))
        XCTAssertFalse(dialogs.answer(open, with: .option(index: 0, label: "Forged"), thread: thread))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testQuestionIDsAndSecretFreeTextSurvivePhoneWire() throws {
        let (dialogs, transport) = make()
        let thread = UUID()
        dialogs.receive(id: 1, method: "item/tool/requestUserInput", params: ["threadId": thread.uuidString,
            "questions": [["id": "secret", "question": "Enter the token", "header": "Token", "isSecret": true]]])
        let open = try XCTUnwrap(dialogs.openPrompt(for: thread))
        let wire = try JSONDecoder().decode(WireOpenPrompt.self, from: JSONEncoder().encode(WireOpenPrompt(open)))
        guard case .question(_, let questions) = try XCTUnwrap(wire.prompt) else { return XCTFail("question missing") }
        XCTAssertTrue(questions[0].isSecret)
        XCTAssertTrue(questions[0].freeTextOnly)
        XCTAssertTrue(questions[0].isAnswerable)
        XCTAssertTrue(dialogs.answer(open, with: .answers([[.typed("test-token", optionCount: 0)]]), thread: thread))
        let data = try XCTUnwrap(transport.sent.first).data(using: .utf8)!
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let answers = (result["result"] as? [String: Any])?["answers"] as? [String: [String: [String]]]
        XCTAssertEqual(answers?["secret"]?["answers"], ["test-token"])
    }

    func testExplicitPermissionsPreserveRequestedSubsetAndChosenScope() throws {
        let (dialogs, transport) = make()
        let thread = UUID()
        dialogs.receive(id: 2, method: "item/permissions/requestApproval", params: ["threadId": thread.uuidString,
            "permissions": ["network": ["enabled": true]]])
        let open = try XCTUnwrap(dialogs.openPrompt(for: thread))
        XCTAssertTrue(dialogs.answer(open, with: choose(open, 0), thread: thread))
        let response = try JSONSerialization.jsonObject(with: Data(transport.sent[0].utf8)) as! [String: Any]
        let result = response["result"] as! [String: Any]
        XCTAssertEqual(result["scope"] as? String, "turn")
        XCTAssertEqual(((result["permissions"] as? [String: Any])?["network"] as? [String: Bool])?["enabled"], true)
    }

    func testMcpFormAnswersPreserveTypesAndValidateBounds() throws {
        let (dialogs, transport) = make()
        let thread = UUID()
        dialogs.receive(id: 3, method: "mcpServer/elicitation/request", params: ["threadId": thread.uuidString,
            "mode": "form", "message": "Configure", "requestedSchema": ["type": "object",
            "properties": ["count": ["type": "integer", "minimum": 1, "maximum": 3]], "required": ["count"]]])
        let open = try XCTUnwrap(dialogs.openPrompt(for: thread))
        XCTAssertFalse(dialogs.answer(open, with: .answers([[.typed("10", optionCount: 0)]]), thread: thread))
        XCTAssertTrue(dialogs.answer(open, with: .answers([[.typed("2", optionCount: 0)]]), thread: thread))
        let response = try JSONSerialization.jsonObject(with: Data(transport.sent[0].utf8)) as! [String: Any]
        XCTAssertEqual(((response["result"] as? [String: Any])?["content"] as? [String: Int])?["count"], 2)
    }

    func testMcpURLIsAnExplicitLinkAndDoesNotOpenOrAnswerItself() throws {
        let (dialogs, transport) = make()
        let thread = UUID()
        dialogs.receive(id: 4, method: "mcpServer/elicitation/request", params: ["threadId": thread.uuidString,
            "mode": "url", "message": "Sign in", "url": "https://example.com/authorize"])
        guard case .question(_, let questions)? = dialogs.openPrompt(for: thread) else { return XCTFail("missing URL offer") }
        XCTAssertEqual(questions[0].url, "https://example.com/authorize")
        XCTAssertFalse(questions[0].allowsOther)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testSubagentApprovalIsAttributedToItsRootAndAnsweredByItsNativeID() throws {
        let (dialogs, transport) = make()
        let root = UUID(), child = UUID()
        dialogs.notify("thread/started", params: ["thread": ["id": child.uuidString, "parentThreadId": root.uuidString]])
        var reported: UUID?
        dialogs.onChange = { id, _ in reported = id }
        dialogs.receive(id: "child-approval", method: "item/fileChange/requestApproval", params: ["threadId": child.uuidString])
        let open = try XCTUnwrap(dialogs.openPrompt(for: root))
        XCTAssertEqual(reported, root)
        XCTAssertTrue(dialogs.answer(open, with: .deny, thread: root))
        XCTAssertTrue(transport.sent[0].contains("child-approval"))
    }

    func testReplayedSubagentRequestRecoversAncestryBeforeMetadataEventsArrive() async throws {
        let (dialogs, _) = make()
        let root = UUID(), child = UUID()
        dialogs.observe(root)
        dialogs.parentLookup = { id in id == child ? root : nil }
        let restored = expectation(description: "pending child prompt reached the root")
        dialogs.onChange = { id, state in if id == root, state == .waiting { restored.fulfill() } }
        dialogs.receive(id: 6, method: "item/fileChange/requestApproval", params: ["threadId": child.uuidString])
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertNotNil(dialogs.openPrompt(for: root))
    }

    func testReplayedFileApprovalLoadsItsPreviewBeforeOfferingApproval() async throws {
        let (dialogs, _) = make()
        let thread = UUID()
        let loaded = expectation(description: "change preview recovered")
        dialogs.fileChangeLookup = { _, _ in [["path": "/tmp/test.txt", "diff": "+hello"]] }
        dialogs.onChange = { _, _ in
            if case .question(_, let questions)? = dialogs.openPrompt(for: thread), questions[0].isAnswerable { loaded.fulfill() }
        }
        dialogs.receive(id: 7, method: "item/fileChange/requestApproval", params: ["threadId": thread.uuidString, "itemId": "patch"])
        let initial = try XCTUnwrap(dialogs.openPrompt(for: thread))
        XCTAssertFalse(dialogs.answer(initial, with: choose(initial, 0), thread: thread))
        await fulfillment(of: [loaded], timeout: 1)
        guard case .question(_, let questions)? = dialogs.openPrompt(for: thread) else { return XCTFail("missing approval") }
        XCTAssertTrue(questions[0].question.contains("+hello"))
    }

    func testTitledMultiSelectFormUsesNativeValuesRatherThanDisplayLabels() throws {
        let (dialogs, transport) = make()
        let thread = UUID()
        dialogs.receive(id: 5, method: "mcpServer/elicitation/request", params: ["threadId": thread.uuidString,
            "mode": "form", "requestedSchema": ["type": "object", "required": ["colors"], "properties": ["colors": [
                "type": "array", "minItems": 1, "maxItems": 2,
                "items": ["anyOf": [["const": "r", "title": "Red"], ["const": "b", "title": "Blue"]]]]]]])
        let open = try XCTUnwrap(dialogs.openPrompt(for: thread))
        XCTAssertTrue(dialogs.answer(open, with: .answers([[.init(index: 0, label: "Red"), .init(index: 1, label: "Blue")]]), thread: thread))
        let response = try JSONSerialization.jsonObject(with: Data(transport.sent[0].utf8)) as! [String: Any]
        XCTAssertEqual(((response["result"] as? [String: Any])?["content"] as? [String: [String]])?["colors"], ["r", "b"])
    }

    func testStatusAndConsecutiveRequestsRemainWaitingUntilAllResolve() {
        let (dialogs, _) = make()
        let thread = UUID()
        var states: [SessionActivity] = []
        dialogs.onChange = { _, state in states.append(state) }
        for id in [1, 2] {
            dialogs.receive(id: id, method: "item/fileChange/requestApproval", params: ["threadId": thread.uuidString])
        }
        dialogs.notify("thread/status/changed", params: ["threadId": thread.uuidString, "status": ["type": "active", "activeFlags": []]])
        dialogs.notify("serverRequest/resolved", params: ["threadId": thread.uuidString, "requestId": 1])
        XCTAssertEqual(states.last, .waiting)
        dialogs.notify("serverRequest/resolved", params: ["threadId": thread.uuidString, "requestId": 2])
        XCTAssertEqual(states.last, .busy)
    }
}
