import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// Fixture helpers shared by the grok test classes. Every file is synthetic, in the shapes the
/// live probe of grok 1.0.30 recorded.
enum GrokFixture {
    static func url(_ name: String) throws -> URL {
        let dot = name.lastIndex(of: ".")!
        return try XCTUnwrap(Bundle(for: GrokScreenTests.self).url(
            forResource: String(name[..<dot]), withExtension: String(name[name.index(after: dot)...]),
            subdirectory: "Fixtures/Grok"), "missing fixture \(name)")
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func lines(_ name: String) throws -> [String] {
        String(decoding: try data(name), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// `GrokTimelineMapper` and `GrokOpenPromptReader`.
final class GrokTimelineMapperTests: XCTestCase {
    func testTheConversationAndItsToolCallMapToRows() throws {
        let items = try GrokFixture.lines("updates.synthetic.jsonl").enumerated()
            .flatMap { GrokTimelineMapper.items(inLine: $0.element, at: $0.offset * 100) }
        XCTAssertEqual(items.map(\.kind), [.userTurn, .thinking, .toolCall, .toolResult, .assistantText],
                       "hook bookkeeping, the status-less update and turn_completed map to nothing")
        XCTAssertEqual(items[0].body.text, "Write hello to a.txt")
        XCTAssertEqual(items[2].body.tool, "write")
        XCTAssertEqual(items[2].body.callID, "call-1")
        XCTAssertEqual(items[3].body.callID, "call-1")
        XCTAssertEqual(items[3].body.text, "Wrote 5 bytes")
        XCTAssertFalse(items[3].body.isError)
        XCTAssertEqual(items[4].body.text, "Done. I wrote the file.")
        XCTAssertNotNil(items[0].at)
    }

    func testAQuestionIsAPromptWhoseBodyParsesAsQuestions() throws {
        let items = try GrokFixture.lines("updates-open-question.synthetic.jsonl")
            .flatMap { GrokTimelineMapper.items(inLine: $0, at: 0) }
        let prompt = try XCTUnwrap(items.last)
        XCTAssertEqual(prompt.kind, .prompt)
        XCTAssertEqual(PromptQuestion.all(toolInput: prompt.body.text).first?.options.map(\.label), ["Red", "Blue"])
    }

    func testAFailedResultIsAnError() {
        let line = #"{"timestamp":1,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"failed","content":[{"type":"content","content":{"type":"text","text":"User rejected the execution for tool `write`"}}]}}}"#
        let item = GrokTimelineMapper.items(inLine: line, at: 0).first
        XCTAssertEqual(item?.kind, .toolResult)
        XCTAssertEqual(item?.body.isError, true)
    }

    private func source(_ name: String) throws -> [SourceLine] {
        try GrokFixture.lines(name).enumerated().map { SourceLine(offset: $0.offset * 100, text: $0.element) }
    }

    func testAnUnansweredCallWhileWaitingIsTheOpenPermission() throws {
        let open = GrokOpenPromptReader().openPrompt(
            inTranscriptTail: try source("updates-open-permission.synthetic.jsonl"), activity: .waiting)
        XCTAssertEqual(open, .permission(callID: "call-9", tool: "write", summary: "/tmp/proj/a.txt"))
    }

    func testAnOpenQuestionIsTheOpenPrompt() throws {
        let open = GrokOpenPromptReader().openPrompt(
            inTranscriptTail: try source("updates-open-question.synthetic.jsonl"), activity: .waiting)
        guard case .question(let id, let questions)? = open else { return XCTFail("\(String(describing: open))") }
        XCTAssertEqual(id, "call-q")
        XCTAssertEqual(questions.first?.question, "Red or blue?")
    }

    func testNothingIsOpenWhenAnsweredOrNotWaiting() throws {
        let reader = GrokOpenPromptReader()
        XCTAssertNil(reader.openPrompt(inTranscriptTail: try source("updates.synthetic.jsonl"), activity: .waiting))
        XCTAssertNil(reader.openPrompt(inTranscriptTail: try source("updates-open-permission.synthetic.jsonl"), activity: .busy))
    }
}

/// `GrokStatusFold` and `GrokRuntime`: status from `events.jsonl`, questions from `updates.jsonl`.
@MainActor
final class GrokStatusTests: XCTestCase {
    private func fold(_ names: [String]) throws -> (GrokStatusFold, [AgentEvent]) {
        var fold = GrokStatusFold()
        var events: [AgentEvent] = []
        for name in names {
            for line in try GrokFixture.lines(name) {
                let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                if name.hasPrefix("events") { events += fold.apply(eventRecord: record) }
                else { fold.apply(updateRecord: record) }
            }
        }
        return (fold, events)
    }

    /// An auto-allowed request resolves in the same millisecond; the write's request does not,
    /// and that unmatched one is the card.
    func testAnUnmatchedPermissionRequestIsWaiting() throws {
        XCTAssertEqual(try fold(["events-permission-open.synthetic.jsonl"]).0.activity, .waiting)
    }

    func testTheTurnEndingSettlesIdleAndSaysSo() throws {
        let (state, events) = try fold(["events-permission-open.synthetic.jsonl", "events-turn-ended.synthetic.jsonl"])
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(events, [.turnEnded])
    }

    func testACancelledTurnIsAnAbort() throws {
        let (state, events) = try fold(["events-permission-open.synthetic.jsonl", "events-cancelled.synthetic.jsonl"])
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(events, [.turnEnded, .turnAborted])
    }

    /// `ask_user_question` is auto-allowed and then runs until answered: only the transcript
    /// shows the card.
    func testAnOpenQuestionIsWaitingAndItsResultClosesIt() throws {
        var (state, _) = try fold(["updates-open-question.synthetic.jsonl"])
        XCTAssertEqual(state.activity, .waiting)
        state.apply(.closed("call-q"))
        XCTAssertEqual(state.activity, .idle)
    }

    func testMidTurnWorkIsBusyEvenWithoutTheTurnStart() {
        var state = GrokStatusFold()
        _ = state.apply(eventType: "mcp_server_connected", outcome: nil)
        XCTAssertEqual(state.activity, .idle, "launch bookkeeping is not a turn")
        _ = state.apply(eventType: "phase_changed", outcome: nil)
        XCTAssertEqual(state.activity, .busy)
    }

    // MARK: Runtime

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheRuntimeReportsLiveThenTheFoldedActivityAndAManualTitle() throws {
        let id = UUID()
        let directory = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/\(id.uuidString.lowercased())")
        let transcript = directory.appendingPathComponent("updates.jsonl")
        let runtime = GrokRuntime()
        var events: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: transcript), for: UUID()) { events.append($0) }
        runtime.drainForTesting()
        XCTAssertEqual(events, [], "nothing on disk yet: no status at all")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GrokFixture.data("events-permission-open.synthetic.jsonl").write(to: directory.appendingPathComponent("events.jsonl"))
        try GrokFixture.data("summary-manual.synthetic.json").write(to: directory.appendingPathComponent("summary.json"))
        runtime.drainForTesting()
        XCTAssertEqual(events, [.lifecycle(.live), .activity(.idle), .activity(.busy), .activity(.waiting),
                                .activity(.busy), .activity(.waiting), .title("my renamed session")])
    }

    /// A fresh `grok -s` writes no events line until its first prompt (verified live), so the
    /// process registry is what makes it a live, idle tab — and its removal what ends that.
    func testTheProcessRegistryMakesAQuietSessionLiveAndItsExitAbsent() throws {
        let id = UUID()
        let directory = root.appendingPathComponent("sessions/%2Ftmp%2Fproj/\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("active_sessions.json")
        let runtime = GrokRuntime()
        var events: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: directory.appendingPathComponent("updates.jsonl")),
                           for: UUID()) { events.append($0) }
        let entry = #"[{"session_id":"\#(id.uuidString.lowercased())","pid":1,"cwd":"/tmp/proj","opened_at":"x"}]"#
        try Data(entry.utf8).write(to: registry)
        runtime.drainForTesting()
        XCTAssertEqual(events, [.lifecycle(.live), .activity(.idle)])
        try Data("[]".utf8).write(to: registry)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: registry.path)
        runtime.drainForTesting()
        XCTAssertEqual(events.last, .lifecycle(.absent))
    }

    /// `grok -r` reopens a session in the cwd it was born in, so the directory the binding
    /// guessed may not be the one grok writes.
    func testTheRuntimeFollowsASessionFoundUnderAnotherCwd() throws {
        let id = UUID()
        let guessed = root.appendingPathComponent("sessions/%2Fhere/\(id.uuidString.lowercased())/updates.jsonl")
        let real = root.appendingPathComponent("sessions/%2Fthere/\(id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let runtime = GrokRuntime()
        var events: [AgentEvent] = []
        _ = runtime.attach(AgentBinding(conversationID: id, transcriptURL: guessed), for: UUID()) { events.append($0) }
        runtime.drainForTesting()
        try GrokFixture.data("events-turn-ended.synthetic.jsonl").write(to: real.appendingPathComponent("events.jsonl"))
        runtime.drainForTesting()
        XCTAssertEqual(events.first, .lifecycle(.live))
        XCTAssertTrue(events.contains(.turnEnded))
    }
}

/// `GrokAdapter`'s commands, environment, identity and files.
@MainActor
final class GrokAdapterTests: XCTestCase {
    private let id = UUID(uuidString: "0199C6A0-1111-7AAA-8BBB-000000000001")!
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func session() -> Session {
        var session = Session(title: "g", workingDirectory: "/tmp/proj", agent: .grok)
        session.pinnedConversationID = id
        return session
    }

    func testLaunchMintsTheSessionIdAndResumeCarriesItsOwnFallback() {
        let adapter = GrokAdapter(home: { self.home })
        let s = session()
        let binding = adapter.binding(for: s)
        XCTAssertEqual(adapter.launchCommand(binding, s, .grok(GrokOptions())),
                       "grok -s 0199c6a0-1111-7aaa-8bbb-000000000001\n")
        XCTAssertEqual(adapter.resumeCommand(binding, s, .grok(GrokOptions(model: "grok-4.7-build-fast", effort: "low"))),
                       "grok -r 0199c6a0-1111-7aaa-8bbb-000000000001 -m 'grok-4.7-build-fast' --effort 'low'"
                       + " || grok -s 0199c6a0-1111-7aaa-8bbb-000000000001 -m 'grok-4.7-build-fast' --effort 'low'\n")
    }

    func testTheTranscriptIsUpdatesJsonlUnderThePercentEncodedCwd() {
        let adapter = GrokAdapter(home: { self.home })
        XCTAssertEqual(adapter.binding(for: session()).transcriptURL?.path,
                       home.path + "/sessions/%2Ftmp%2Fproj/0199c6a0-1111-7aaa-8bbb-000000000001/updates.jsonl")
    }

    func testAnExistingSessionDirectoryWinsOverTheComputedOne() throws {
        let existing = home.appendingPathComponent("sessions/%2Felsewhere/0199c6a0-1111-7aaa-8bbb-000000000001")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertEqual(GrokAdapter(home: { self.home }).binding(for: session()).transcriptURL?.deletingLastPathComponent().path,
                       existing.path)
    }

    /// The tab's SHELL gets the compat switches and never `HOME`; the account binding gets both
    /// homes, as `GrokProfile` binds them for planning.
    func testEnvironmentIsolatesTheTabAndBindsTheAccountsHomes() {
        let adapter = GrokAdapter()
        XCTAssertEqual(adapter.launchEnvironment["GROK_CLAUDE_HOOKS_ENABLED"], "0")
        XCTAssertEqual(adapter.launchEnvironment["GROK_CODEX_MCPS_ENABLED"], "0")
        XCTAssertNil(adapter.launchEnvironment["HOME"])
        XCTAssertNil(adapter.launchEnvironment["GROK_MEMORY"], "a person's grok keeps its memory")
        let account = AgentAccount(agent: .grok, displayName: "K", home: URL(fileURLWithPath: "/tmp/grok-k"))
        let env = adapter.environment(for: account)
        XCTAssertEqual(env["GROK_HOME"], "/tmp/grok-k")
        XCTAssertEqual(env["HOME"], "/tmp/grok-k")
        XCTAssertEqual(env["GROK_CLAUDE_SKILLS_ENABLED"], "0")
    }

    func testIdentityIsTheSingleEmailInAuthJson() throws {
        XCTAssertEqual(GrokAdapter.identity(fromHomeData: try GrokFixture.data("auth.synthetic.json"))?.email,
                       "pilot@example.com")
        let two = #"{"a::1":{"email":"x@example.com"},"a::2":{"email":"y@example.com"}}"#
        XCTAssertNil(GrokAdapter.identity(fromHomeData: Data(two.utf8)), "two logins: no answer, not a wrong one")
        XCTAssertNil(GrokAdapter.identity(fromHomeData: Data("{}".utf8)))
    }

    func testTheTitleIsReadFromSummaryJsonBesideTheTranscript() throws {
        let directory = home.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GrokFixture.data("summary.synthetic.json").write(to: directory.appendingPathComponent("summary.json"))
        XCTAssertEqual(GrokAdapter.title(fromTranscriptAt: directory.appendingPathComponent("updates.jsonl")),
                       "Write Hello To A File")
    }

    func testCapabilitiesAreStated() {
        XCTAssertNotNil(AgentID.grok.textChannel)
        XCTAssertNotNil(AgentID.grok.dialogDriver)
        XCTAssertNotNil(AgentID.grok.openPromptReader)
        XCTAssertNotNil(AgentID.grok.searchCorpus)
        XCTAssertNil(AgentID.grok.renameTyping, "one-shot /rename through the text channel")
        XCTAssertNil(AgentID.grok.turnRecovery)
        XCTAssertFalse(AgentID.grok.negotiatesIdentity)
        XCTAssertEqual(AgentID.grok.exitCommand, "/quit")
        XCTAssertEqual(AgentID.grok.interruptKey, .controlC)
        XCTAssertEqual(AgentID.claude.interruptKey, .escape)
        XCTAssertEqual(GrokAdapter().loginInvocation(for: AgentAccount(agent: .grok, displayName: "K", home: home)),
                       LoginInvocation(command: "grok login", inject: nil))
    }
}

/// `GrokSearchCorpus`, `GrokBillingSource` and `GrokRoutingCapabilities`.
@MainActor
final class GrokCorpusAndUsageTests: XCTestCase {
    private var home: URL!
    private var project: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("grok-corpus-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        project = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func testTheCorpusFindsAProjectsSessionsAndIndexesTheConversation() throws {
        let id = "0199c6a0-1111-7aaa-8bbb-000000000001"
        let cwd = project.resolvingSymlinksInPath().path
        let directory = home.appendingPathComponent("sessions")
            .appendingPathComponent(GrokSessionFiles.encodedDirectoryName(forWorkingDirectory: cwd))
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var summary = try XCTUnwrap(JSONSerialization.jsonObject(with: GrokFixture.data("summary.synthetic.json")) as? [String: Any])
        summary["info"] = ["id": id, "cwd": cwd]
        try JSONSerialization.data(withJSONObject: summary).write(to: directory.appendingPathComponent("summary.json"))
        try GrokFixture.data("updates.synthetic.jsonl").write(to: directory.appendingPathComponent("updates.jsonl"))

        let account = AgentAccount(agent: .grok, displayName: "K", home: home)
        let refs = GrokSearchCorpus().transcripts(forProjects: [project.path], accounts: [account])
        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(ref.conversationID, id)
        XCTAssertEqual(ref.agent, .grok)
        XCTAssertNil(ref.provenance)
        XCTAssertEqual(GrokSearchCorpus().conversationName(inLines: [], for: ref), .authoritative("Write Hello To A File"))

        let messages = try GrokFixture.lines("updates.synthetic.jsonl").flatMap {
            GrokSearchCorpus().indexedMessages(inLine: $0, conversationID: id, at: 0)
        }
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Write hello to a.txt", "Done. I wrote the file."])
        XCTAssertNotNil(messages[0].timestamp)
    }

    func testAHeadlessSessionIsRankedAutomated() throws {
        let data = Data(#"{"info":{"id":"x","cwd":"/p"},"session_kind":"headless","generated_title":"T"}"#.utf8)
        XCTAssertEqual(GrokSearchCorpus.meta(fromSummary: data), .init(cwd: "/p", title: "T", headless: true))
    }

    func testTheNewestBillingLineIsTheWeeklyWindow() throws {
        let text = String(decoding: try GrokFixture.data("unified-billing.synthetic.jsonl"), as: UTF8.self)
        let found = try XCTUnwrap(GrokBillingSource.windows(inLogTail: text))
        XCTAssertEqual(found.windows.count, 1)
        XCTAssertEqual(found.windows[0].name, "weekly")
        XCTAssertEqual(found.windows[0].utilization, 0.375, accuracy: 0.0001)
        XCTAssertEqual(found.windows[0].resetsAt, GrokBillingSource.date(from: "2026-10-14T20:15:34.608Z"))
        XCTAssertNotNil(found.windows[0].resetsAt, "microsecond +00:00 stamps parse")
        XCTAssertNotNil(found.readAt)
        XCTAssertNil(GrokBillingSource.windows(inLogTail: "{\"msg\":\"other\"}\n"))
    }

    func testRoutingOffersTheProfilesModelsAndMapsOverridesToGrokOptions() async {
        let caps = GrokRoutingCapabilities()
        let models = await caps.modelCatalog().value
        XCTAssertEqual(models?.map(\.id), GrokProfile().modelCatalog.aliases)
        XCTAssertEqual(caps.knobSchema["effort"], GrokProfile().modelCatalog.effortValues)
        guard case .supported(let options) = caps.applying(LaunchOverrides(model: "grok-4.6", knobs: ["effort": "low"]),
                                                           to: .grok(GrokOptions())) else { return XCTFail() }
        XCTAssertEqual(options, .grok(GrokOptions(model: "grok-4.6", effort: "low")))
        guard case .unsupported = caps.applying(LaunchOverrides(model: nil, knobs: ["speed": "x"]), to: .grok(GrokOptions()))
        else { return XCTFail("an unknown knob is refused") }
        guard case .unsupported? = try? await caps.resetContext(Session(title: "g", workingDirectory: "/tmp", agent: .grok))
        else { return XCTFail("reset is refused until a grok tab can follow /new") }
    }
}
