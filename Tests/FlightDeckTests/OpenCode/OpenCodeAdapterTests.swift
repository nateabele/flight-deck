import IntakeKit
import FleetKit
import XCTest
@testable import FlightDeck

@MainActor
final class OpenCodeClientTests: XCTestCase {
    func testCreatingASessionSendsTitleModelAndAgentToItsDirectory() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("POST", "/session", json: ["id": "ses_new", "title": "session 4", "directory": "/w"])
        let info = try await OpenCodeClient(http: http).createSession(
            directory: "/w", title: "session 4",
            options: OpenCodeOptions(model: "ollama/qwen3-coder:32k", agent: "plan")
        )
        XCTAssertEqual(info.id, "ses_new")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.query, ["directory": "/w"])
        let body = try XCTUnwrap(http.body(of: request))
        XCTAssertEqual(body["title"] as? String, "session 4")
        XCTAssertEqual(body["agent"] as? String, "plan")
        XCTAssertEqual(body["model"] as? [String: String], ["providerID": "ollama", "id": "qwen3-coder:32k"])
    }

    func testAMissingSessionIsNilNotAnError() async throws {
        let http = ScriptedOpenCodeHTTP()
        let found = try await OpenCodeClient(http: http).session("ses_gone", directory: "/w")
        XCTAssertNil(found)
    }

    func testOtherFailuresCarryOpenCodesOwnMessage() async {
        let http = ScriptedOpenCodeHTTP()
        http.on("POST", "/session/ses_a/prompt_async", status: 400,
                json: ["name": "BadRequest", "data": ["message": "agent not found"]])
        do {
            try await OpenCodeClient(http: http).prompt("ses_a", text: "hi", directory: "/w")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OpenCodeError, .http(status: 400, message: "agent not found"))
        }
    }

    func testPendingRequestsIncludeSubagentsButNotStrangers() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("GET", "/permission", json: [
            ["id": "per_root", "sessionID": "ses_root"],
            ["id": "per_child", "sessionID": "ses_child"],
            ["id": "per_other", "sessionID": "ses_other"],
        ])
        http.on("GET", "/question", json: [["id": "que_grand", "sessionID": "ses_grand"]])
        http.on("GET", "/session/ses_child", json: ["id": "ses_child", "parentID": "ses_root"])
        http.on("GET", "/session/ses_grand", json: ["id": "ses_grand", "parentID": "ses_child"])
        http.on("GET", "/session/ses_other", json: ["id": "ses_other"])
        let pending = try await OpenCodeClient(http: http).pendingRequests(inTreeOf: "ses_root", directory: "/w")
        XCTAssertEqual(pending.permissions, ["per_root", "per_child"])
        XCTAssertEqual(pending.questions, ["que_grand"])
    }

    func testBasicAuthUsesOpenCodesDefaultUser() {
        XCTAssertEqual(URLSessionOpenCodeHTTP.authorization(password: "pw"),
                       "Basic " + Data("opencode:pw".utf8).base64EncodedString())
        XCTAssertNil(URLSessionOpenCodeHTTP.authorization(password: nil))
    }
}

@MainActor
final class OpenCodeAdapterTests: XCTestCase {
    private func adapter(_ http: ScriptedOpenCodeHTTP, server: FakeOpenCodeServer) -> OpenCodeAdapter {
        var adapter = OpenCodeAdapter(server: server)
        adapter.mirrorRoot = OpenCodeFixtures.temporaryDirectory()
        adapter.transport = { _ in http }
        return adapter
    }

    private func session(transcriptPath: String? = nil, pinned: UUID = UUID()) -> Session {
        Session(title: "session 3", workingDirectory: "/Users/dev/My Project",
                pinnedConversationID: pinned, agent: .opencode, transcriptPath: transcriptPath)
    }

    /// Every capability is answered, and the one `nil` is a stated design answer (rename goes
    /// over the wire; there is no modal to type into), not a gap.
    func testEveryCapabilityIsImplemented() {
        let agent = AgentID.opencode
        XCTAssertNotNil(agent.textChannel)
        XCTAssertNotNil(agent.dialogDriver)
        XCTAssertNotNil(agent.turnRecovery)
        XCTAssertNotNil(agent.openPromptReader)
        XCTAssertNotNil(agent.searchCorpus)
        XCTAssertNotNil(agent.promptResponder)
        XCTAssertNil(agent.renameTyping)
        XCTAssertTrue(agent.negotiatesIdentity)
        XCTAssertTrue(agent.needsRuntimeStart)
        XCTAssertFalse(agent.hasStatusRegistry)
        XCTAssertEqual(agent.displayName, "OpenCode")
        XCTAssertEqual(agent.homeEnvironmentKey, "XDG_DATA_HOME")
        XCTAssertEqual(agent.builtInHome.path, NSHomeDirectory() + "/.local/share")
    }

    func testPrepareBindsTheDerivedIDAndTheMirror() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("POST", "/session", json: ["id": "ses_abc123", "title": "session 3", "directory": "/w"])
        let server = FakeOpenCodeServer(databaseURL: URL(fileURLWithPath: "/tmp/x/opencode/opencode.db"))
        let binding = try await adapter(http, server: server).prepare(for: session(), options: .opencode(OpenCodeOptions()))
        XCTAssertEqual(binding.conversationID, OpenCodeIdentity.conversationID(forSession: "ses_abc123"))
        XCTAssertEqual(OpenCodeIdentity.sessionID(fromTranscript: binding.transcriptURL), "ses_abc123")
        XCTAssertEqual(http.requests.first?.query["directory"], "/Users/dev/My Project")
    }

    func testTheLaunchAttachesToTheAccountsServerWithoutThePassword() {
        let server = FakeOpenCodeServer()
        let adapter = adapter(ScriptedOpenCodeHTTP(), server: server)
        let binding = AgentBinding(conversationID: UUID(), transcriptURL: URL(fileURLWithPath: "/m/ses_abc123.jsonl"))
        let command = adapter.launchCommand(binding, session(), .opencode(OpenCodeOptions()))
        XCTAssertEqual(command, "opencode attach http://127.0.0.1:45555 --dir '/Users/dev/My Project' -s ses_abc123\n")
        XCTAssertFalse(command.contains(server.password))
        XCTAssertEqual(adapter.launchEnvironment["OPENCODE_SERVER_PASSWORD"], server.password)
        XCTAssertEqual(adapter.resumeCommand(binding, session(), .opencode(OpenCodeOptions())), command)
    }

    func testWithNoServerTheTabStillOpensItsSession() {
        let adapter = adapter(ScriptedOpenCodeHTTP(), server: FakeOpenCodeServer(running: false))
        let binding = AgentBinding(conversationID: UUID(), transcriptURL: URL(fileURLWithPath: "/m/ses_abc123.jsonl"))
        XCTAssertEqual(adapter.launchCommand(binding, session(), .opencode(OpenCodeOptions())),
                       "opencode '/Users/dev/My Project' -s ses_abc123\n")
    }

    func testRebindKeepsAPinThatStillExists() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("GET", "/session/ses_keep", json: ["id": "ses_keep", "title": "x"])
        let pinned = OpenCodeIdentity.conversationID(forSession: "ses_keep")
        let restored = session(transcriptPath: "/m/ses_keep.jsonl", pinned: pinned)
        let binding = try await adapter(http, server: FakeOpenCodeServer()).rebind(for: restored, options: .opencode(OpenCodeOptions()))
        XCTAssertEqual(binding.conversationID, pinned)
        XCTAssertFalse(http.requests.contains { $0.method == "POST" })
    }

    func testRebindReplacesADeletedSession() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("POST", "/session", json: ["id": "ses_fresh", "title": "session 3"])
        let restored = session(transcriptPath: "/m/ses_gone.jsonl",
                               pinned: OpenCodeIdentity.conversationID(forSession: "ses_gone"))
        let server = FakeOpenCodeServer(databaseURL: URL(fileURLWithPath: "/tmp/x/opencode/opencode.db"))
        let binding = try await adapter(http, server: server).rebind(for: restored, options: .opencode(OpenCodeOptions()))
        XCTAssertEqual(binding.conversationID, OpenCodeIdentity.conversationID(forSession: "ses_fresh"))
    }

    func testRenameIsAPatchRoutedToTheSessionsDirectory() async throws {
        let db = try SyntheticOpenCodeDatabase()
        try db.session("ses_r", directory: "/Users/dev/proj", title: "old")
        let http = ScriptedOpenCodeHTTP()
        http.on("PATCH", "/session/ses_r", json: ["id": "ses_r", "title": "new"])
        let adapter = adapter(http, server: FakeOpenCodeServer(databaseURL: db.url))
        try await adapter.rename(
            AgentBinding(conversationID: UUID(), transcriptURL: URL(fileURLWithPath: "/m/ses_r.jsonl")), to: "new"
        )
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.query["directory"], "/Users/dev/proj")
        XCTAssertEqual(http.body(of: request)?["title"] as? String, "new")
    }

    // MARK: - Text channel delivery

    private func target(_ adapter: OpenCodeAdapter, session sessionID: String = "ses_t") -> AgentTarget {
        AgentTarget(adapter: adapter, location: AgentLocation(
            workingDirectory: "/w",
            binding: AgentBinding(conversationID: UUID(), transcriptURL: URL(fileURLWithPath: "/m/\(sessionID).jsonl"))
        ))
    }

    func testSubmitSendsPromptAsyncAndTypesNothing() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("POST", "/session/ses_t/prompt_async", status: 204)
        let spy = SpyInjector()
        let injector = TargetedInjector(base: spy, target: target(adapter(http, server: FakeOpenCodeServer())))
        let finished = expectation(description: "finished")
        var sent: Bool?
        let started = OpenCodeTextChannel().submit(
            "continue", into: injector, settle: { $0() }, stillWanted: { true },
            onFinished: { sent = $0; finished.fulfill() }
        )
        XCTAssertTrue(started)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(sent, true)
        XCTAssertEqual(spy.events, [], "a draft in the composer is never touched")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.query["directory"], "/w")
        let parts = http.body(of: request)?["parts"] as? [[String: String]]
        XCTAssertEqual(parts?.first?["text"], "continue")
    }

    func testSubmitRefusesAnUnaddressedTerminal() {
        XCTAssertFalse(OpenCodeTextChannel().submit(
            "hi", into: SpyInjector(), settle: { $0() }, stillWanted: { true }, onFinished: { _ in }
        ))
    }

    func testASupersededSubmitSendsNothingButStillFinishes() async {
        let http = ScriptedOpenCodeHTTP()
        let injector = TargetedInjector(base: SpyInjector(), target: target(adapter(http, server: FakeOpenCodeServer())))
        var sent: Bool?
        _ = OpenCodeTextChannel().submit(
            "hi", into: injector, settle: { $0() }, stillWanted: { false }, onFinished: { sent = $0 }
        )
        XCTAssertEqual(sent, false)
        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: - Prompt responder

    private let question = PromptQuestion(question: "Proceed?", options: [.init(label: "Yes"), .init(label: "No")])

    private func settle(_ http: ScriptedOpenCodeHTTP, count: Int) async {
        for _ in 0..<100 where http.requests.count < count { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testAllowIsOnceNeverAlways() async throws {
        let http = ScriptedOpenCodeHTTP()
        http.on("POST", "/permission/per_1/reply", json: true)
        let responder = OpenCodePromptResponder()
        XCTAssertTrue(responder.answer(.permission(callID: "per_1", tool: "bash", summary: "ls"),
                                       with: .allow, for: target(adapter(http, server: FakeOpenCodeServer()))))
        await settle(http, count: 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.body(of: request)?["reply"] as? String, "once")
        XCTAssertEqual(request.query["directory"], "/w")
    }

    func testDenyRejects() async throws {
        let http = ScriptedOpenCodeHTTP()
        let responder = OpenCodePromptResponder()
        XCTAssertTrue(responder.answer(.permission(callID: "per_1", tool: nil, summary: nil),
                                       with: .deny, for: target(adapter(http, server: FakeOpenCodeServer()))))
        await settle(http, count: 1)
        XCTAssertEqual(http.body(of: try XCTUnwrap(http.requests.first))?["reply"] as? String, "reject")
    }

    func testAnOptionIsAnsweredWithTheMacsOwnLabel() async throws {
        let http = ScriptedOpenCodeHTTP()
        let responder = OpenCodePromptResponder()
        XCTAssertTrue(responder.answer(.question(callID: "que_1", [question]),
                                       with: .option(index: 1, label: "No"),
                                       for: target(adapter(http, server: FakeOpenCodeServer()))))
        await settle(http, count: 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.path, "/question/que_1/reply")
        XCTAssertEqual(http.body(of: request)?["answers"] as? [[String]], [["No"]])
    }

    func testAMismatchedLabelSendsNothing() {
        let http = ScriptedOpenCodeHTTP()
        let responder = OpenCodePromptResponder()
        XCTAssertFalse(responder.answer(.question(callID: "que_1", [question]),
                                        with: .option(index: 1, label: "Yes"),
                                        for: target(adapter(http, server: FakeOpenCodeServer()))))
        XCTAssertFalse(responder.answer(.permission(callID: "per_1", tool: nil, summary: nil),
                                        with: .option(index: 0, label: "Yes"),
                                        for: target(adapter(http, server: FakeOpenCodeServer()))))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAWholeSetMapsEachQuestionsLabels() {
        let multi = PromptQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")], multiSelect: true)
        XCTAssertEqual(OpenCodePromptResponder.labels(
            for: .answers([[.init(index: 0, label: "Yes")], [.init(index: 0, label: "A"), .init(index: 1, label: "B")]]),
            questions: [question, multi]
        ), [["Yes"], ["A", "B"]])
        XCTAssertNil(OpenCodePromptResponder.labels(
            for: .answers([[.init(index: 0, label: "Yes"), .init(index: 1, label: "No")]]), questions: [question]
        ), "two picks on a single-select question")
        XCTAssertNil(OpenCodePromptResponder.labels(for: .answers([]), questions: [question]))
    }

    func testAbortRejectsEverythingPendingInTheTree() async {
        let http = ScriptedOpenCodeHTTP()
        http.on("GET", "/permission", json: [["id": "per_c", "sessionID": "ses_c"]])
        http.on("GET", "/question", json: [["id": "que_t", "sessionID": "ses_t"]])
        http.on("GET", "/session/ses_c", json: ["id": "ses_c", "parentID": "ses_t"])
        OpenCodePromptResponder().abort(for: target(adapter(http, server: FakeOpenCodeServer())))
        await settle(http, count: 5)
        let posts = http.requests.filter { $0.method == "POST" }.map(\.path)
        XCTAssertEqual(Set(posts), ["/permission/per_c/reply", "/question/que_t/reject"])
    }
}
