import XCTest
import IntakeKit
@testable import FlightDeck

/// The Gemini planning harness (grok/gemini spec, Track M), driven through Antigravity's `agy`.
/// Fixtures are `Fixtures/Intake/gemini-*`; each is synthetic content in the shape a live `agy`
/// 1.2.3 run produced (see spec §10, Gemini column, for which were probed).
private func fixture(_ name: String, _ ext: String, _ test: AnyClass) throws -> Data {
    try Data(contentsOf: try XCTUnwrap(Bundle(for: test).url(forResource: name, withExtension: ext,
                                                             subdirectory: "Fixtures/Intake")))
}

private func geminiRequest(resume: String? = nil, access: HarnessAccess = .readOnly, cwd: String = "/proj",
                           effort: String = "high") -> HarnessRequest {
    HarnessRequest(harness: .gemini, model: "gemini-m", effort: effort, cwd: URL(fileURLWithPath: cwd),
                   readableDirs: [URL(fileURLWithPath: "/intake"), URL(fileURLWithPath: "/shadow")], prompt: "P",
                   schemaFile: URL(fileURLWithPath: "/intake/runs/x/schema.json"), schemaJSON: "{}",
                   resumeSessionID: resume, access: access)
}

private func geminiFlag(_ flag: String, in args: [String]) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

// MARK: - Commands

final class HarnessCommandGeminiTests: XCTestCase {
    private let noHome = URL(fileURLWithPath: "/nonexistent-fd-home")

    func testFreshReadOnlySeat() throws {
        let cmd = try HarnessCommand.build(geminiRequest(), home: noHome)
        XCTAssertEqual(cmd.executable, "agy")
        XCTAssertEqual(cmd.arguments, ["-p", "P", "--output-format", "stream-json",
                                       "--json-schema", "/intake/runs/x/schema.json", "--model", "gemini-m",
                                       "--effort", "high", "--disable-slash-commands", "--print-timeout", "2h",
                                       "--mode", "plan", "--add-dir", "/intake", "--add-dir", "/shadow"])
        XCTAssertEqual(cmd.unsetEnvironment, [])
    }

    func testResumeUsesTheSeatsOwnConversationID() throws {
        let args = try HarnessCommand.build(geminiRequest(resume: "conv-7"), home: noHome).arguments
        XCTAssertEqual(geminiFlag("--conversation", in: args), "conv-7")
        XCTAssertEqual(args.suffix(2), ["--conversation", "conv-7"])
    }

    /// `--continue`/`-c` resumes the MOST RECENT conversation — with parallel seats, another
    /// seat's. It must never appear, fresh or resumed.
    func testNeverResumesTheMostRecentConversation() throws {
        for resume in [nil, "conv-7"] {
            let args = try HarnessCommand.build(geminiRequest(resume: resume), home: noHome).arguments
            XCTAssertFalse(args.contains("--continue"))
            XCTAssertFalse(args.contains("-c"))
        }
    }

    func testReadOnlyNeverGrantsEditsOrSkipsPermissions() throws {
        for resume in [nil, "conv-7"] {
            let args = try HarnessCommand.build(geminiRequest(resume: resume), home: noHome).arguments
            XCTAssertEqual(geminiFlag("--mode", in: args), "plan")
            XCTAssertFalse(args.contains("accept-edits"))
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        }
    }

    func testWriteModeAcceptsEditsInTheWorkDirOnly() throws {
        let work = URL(fileURLWithPath: "/intake/work")
        let cmd = try HarnessCommand.build(geminiRequest(access: .writeInWork(work), cwd: "/intake/work"), home: noHome)
        XCTAssertEqual(geminiFlag("--mode", in: cmd.arguments), "accept-edits")
        // `--add-dir` widens where edits may land, so write mode adds none.
        XCTAssertFalse(cmd.arguments.contains("--add-dir"))
        XCTAssertFalse(cmd.arguments.contains("--dangerously-skip-permissions"))
        XCTAssertNil(geminiFlag("--conversation", in: cmd.arguments))
    }

    func testWriteModeWithAResumeIsRefused() {
        let work = URL(fileURLWithPath: "/intake/work")
        XCTAssertEqual(HarnessCommand.validate(geminiRequest(resume: "conv-7", access: .writeInWork(work), cwd: "/intake/work")),
                       .resumeNotSupportedForWrite)
    }

    func testEmptyEffortIsOmitted() throws {
        let args = try HarnessCommand.build(geminiRequest(effort: ""), home: noHome).arguments
        XCTAssertFalse(args.contains("--effort"))
    }

    func testEnvironmentScrubsChildSessionAndKeepsTheBuiltInAccount() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1"]
        let account = AgentAccountRef(id: "other", home: URL(fileURLWithPath: "/accounts/other"))
        let env = GeminiProfile().environment(base: base, account: account)
        XCTAssertEqual(env, ["PATH": "/usr/bin", "HOME": "/Users/x"], "agy has no home to bind; HOME is never moved")
    }
}

// MARK: - Output

final class HarnessOutputGeminiTests: XCTestCase {
    func testParsesTheJSONResult() throws {
        let out = try HarnessOutput.parse(.gemini, stdout: try fixture("gemini-p-json", "json", Self.self))
        XCTAssertEqual(out.sessionID, "6c1f4c0e-3a51-4b8e-9d0e-1f2a3b4c5d6e")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String],
                       ["plan": "# Plan\n\n## Scope\nOne\n"])
    }

    func testParsesTheStreamsFinalResult() throws {
        let out = try HarnessOutput.parse(.gemini, stdout: try fixture("gemini-stream-activity", "jsonl", Self.self))
        XCTAssertEqual(out.sessionID, "6c1f4c0e-3a51-4b8e-9d0e-1f2a3b4c5d6e")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["plan": "# Plan"])
    }

    /// A signed-out run reports an ERROR result with an EMPTY conversation id: the error must
    /// win over "no session", or the diagnosis would never see the auth text.
    func testAnErrorResultIsAnErrorNotAnAnswer() throws {
        XCTAssertThrowsError(try HarnessOutput.parse(.gemini, stdout: try fixture("gemini-auth-stdout", "jsonl", Self.self))) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .isError("authentication failed or timed out"))
        }
    }

    func testAStreamThatNeverFinishedHasNoResult() {
        let stdout = Data(#"{"event":"init","conversation_id":"c1","init":{}}"#.utf8 + [0x0A])
        XCTAssertThrowsError(try HarnessOutput.parse(.gemini, stdout: stdout)) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .noResult)
        }
        XCTAssertThrowsError(try HarnessOutput.parse(.gemini, stdout: Data())) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .noSession)
        }
    }

    /// Without `structured_output`, the response text must itself be JSON — prose is rejected.
    func testFallsBackToTheResponseOnlyWhenItIsJSON() throws {
        let ok = Data(#"{"conversation_id":"c1","status":"SUCCESS","response":"{\"a\":1}"}"#.utf8)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try HarnessOutput.parse(.gemini, stdout: ok).structured) as? [String: Int],
                       ["a": 1])
        let prose = Data(#"{"conversation_id":"c1","status":"SUCCESS","response":"Here you go: {\"a\":1}"}"#.utf8)
        XCTAssertThrowsError(try HarnessOutput.parse(.gemini, stdout: prose)) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .notJSON("Here you go: {\"a\":1}"))
        }
    }
}

// MARK: - Diagnosis

final class GeminiFailureDiagnosisTests: XCTestCase {
    func testSignedOutRunIsAuthExpiredWithTheAgyFix() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("gemini-auth-stdout", "jsonl", Self.self),
                                          stderr: String(decoding: try fixture("gemini-auth-stderr", "txt", Self.self), as: UTF8.self),
                                          parseError: nil, harness: .gemini)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `agy` in a terminal to sign in")
    }

    func testAuthErrorReportedOnlyInTheStreamStillReadsAsAuth() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("gemini-auth-stdout", "jsonl", Self.self),
                                          stderr: "", parseError: nil, harness: .gemini)
        XCTAssertEqual(d.category, .authExpired)
    }

    func testBadModelIsAHarnessError() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("gemini-bad-model-stdout", "jsonl", Self.self),
                                          stderr: "", parseError: nil, harness: .gemini)
        XCTAssertEqual(d.category, .harnessError)
        XCTAssertTrue(d.detail.contains("invalid model selection"), d.detail)
    }

    /// UNVERIFIED spelling: no real agy rate limit has been captured. Google's API reports
    /// quota exhaustion as RESOURCE_EXHAUSTED; this pins that it would classify.
    func testResourceExhaustedIsRateLimited() {
        let stdout = Data(#"{"event":"result","result":{"conversation_id":"c","status":"ERROR","error":"RESOURCE_EXHAUSTED: quota"}}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: stdout, stderr: "", parseError: nil, harness: .gemini).category,
                       .rateLimited)
    }

    /// The model's own response is never read for error words.
    func testASuccessfulResultsResponseIsNeverMatched() {
        let stdout = Data(#"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"401 authentication rate limit"}}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: stdout, stderr: "boom", parseError: nil, harness: .gemini).category,
                       .harnessError)
    }

    func testProfileClassifier() {
        let p = GeminiProfile()
        XCTAssertEqual(p.classify(error: .stderr("Authentication required. Please visit the URL")), .authExpired)
        XCTAssertEqual(p.classify(error: .stderr("Error: Please sign in to view available models.")), .authExpired)
        XCTAssertEqual(p.classify(error: .streamErrorEvent(json: #"{"error":"RESOURCE_EXHAUSTED"}"#)), .rateLimited)
        XCTAssertEqual(p.classify(error: .stderr("model is overloaded")), .overloaded)
        XCTAssertNil(p.classify(error: .stderr("invalid model selection: x not recognized")))
    }
}

// MARK: - Activity

final class GeminiActivityParserTests: XCTestCase {
    func testFoldsTheStream() throws {
        let tick = Date(timeIntervalSince1970: 9)
        var parser = ActivityParser(harness: .gemini, project: URL(fileURLWithPath: "/proj"), now: { tick })
        parser.feed(try fixture("gemini-stream-activity", "jsonl", Self.self))
        let a = parser.activity
        XCTAssertEqual(a.lastEventAt, tick)
        XCTAssertEqual(a.headline, "Reading the README first.")
        XCTAssertEqual(a.action, ActivityAction(verb: "Searching", object: "\"func run\""))
        XCTAssertEqual(a.footprint, [".": 1])
        XCTAssertEqual(a.inputTokens, 1500)
        XCTAssertEqual(a.outputTokens, 60)
        XCTAssertTrue(a.finished)
        XCTAssertNil(a.error)
        XCTAssertNil(a.rateLimitWindows)
    }

    func testAnErrorResultIsTheSeatsError() throws {
        var parser = ActivityParser(harness: .gemini, project: URL(fileURLWithPath: "/proj"), now: { Date() })
        parser.feed(try fixture("gemini-auth-stdout", "jsonl", Self.self))
        XCTAssertEqual(parser.activity.error, "authentication failed or timed out")
    }

    /// The structured answer streamed as text is not a headline.
    func testJSONResponseTextIsNotAHeadline() {
        var parser = ActivityParser(harness: .gemini, project: URL(fileURLWithPath: "/proj"), now: { Date() })
        let line = #"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"{\"plan\": \"x\"}"}}"#
        parser.feed(Data(line.utf8 + [0x0A]))
        XCTAssertNil(parser.activity.headline)
    }
}

// MARK: - Schema repair

final class SchemaRepairRetryTests: XCTestCase {
    /// A harness without a schema flag — none ships today (agy has `--json-schema`), so the
    /// seam is exercised through a stand-in.
    private struct SchemaLess: AgentProfile {
        var id: Harness { .gemini }
        var family: ModelFamily { .gemini }
        var binaryName: String { "x" }
        var signInCheck: SignInCheck { SignInCheck(arguments: [], signedOutHint: "", isSignedIn: { _ in false }) }
        var modelCatalog: ProfileModelCatalog { .empty }
        func parseModelList(_ stdout: String) -> [String] { [] }
        var hasNativeSchema: Bool { false }
        func classify(error: AgentErrorSignal) -> AgentFailureKind? { nil }
        func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] { base }
    }
    private let invalid = Diagnosis(category: .invalidOutput, detail: "missing field plan\nsecond error", action: "")

    func testOneRetryResumingTheSameSession() {
        let retry = SchemaRepair.retry(profile: SchemaLess(), failure: invalid, sessionID: "S1", access: .readOnly, isRepair: false)
        XCTAssertEqual(retry, SchemaRepair.Retry(resumeSessionID: "S1",
            prompt: "Your reply did not validate: missing field plan. Reply again with only the corrected JSON."))
    }

    func testNeverMoreThanOne() {
        XCTAssertNil(SchemaRepair.retry(profile: SchemaLess(), failure: invalid, sessionID: "S1", access: .readOnly, isRepair: true))
    }

    func testOnlyInvalidOutputWithASessionInReadOnlyIsRepaired() {
        let limited = Diagnosis(category: .rateLimited, detail: "429", action: "")
        XCTAssertNil(SchemaRepair.retry(profile: SchemaLess(), failure: limited, sessionID: "S1", access: .readOnly, isRepair: false))
        XCTAssertNil(SchemaRepair.retry(profile: SchemaLess(), failure: invalid, sessionID: nil, access: .readOnly, isRepair: false))
        XCTAssertNil(SchemaRepair.retry(profile: SchemaLess(), failure: invalid, sessionID: "S1",
                                        access: .writeInWork(URL(fileURLWithPath: "/w")), isRepair: false))
    }

    func testNativeSchemaHarnessesNeverRetry() {
        for harness in Harness.allCases where AgentProfiles.profile(for: harness).hasNativeSchema {
            XCTAssertNil(SchemaRepair.retry(profile: AgentProfiles.profile(for: harness), failure: invalid, sessionID: "S1",
                                            access: .readOnly, isRepair: false), "\(harness)")
        }
        XCTAssertTrue(GeminiProfile().hasNativeSchema, "agy --json-schema")
    }
}

// MARK: - Availability

final class GeminiAvailabilityTests: XCTestCase {
    private var bin: URL!

    override func setUpWithError() throws {
        bin = FileManager.default.temporaryDirectory.appendingPathComponent("fd-gemini-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: bin) }

    private func install(_ tools: [String]) throws {
        for tool in tools {
            let file = bin.appendingPathComponent(tool)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    private func probe(_ text: String, exit: Int32, calls: CallLog = CallLog()) -> SignInProbe {
        SignInProbe { executable, args, _ in
            calls.append(((executable as NSString).lastPathComponent, args))
            return SignInCheckOutput(stdout: text, stderr: "", exitCode: exit)
        }
    }

    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(String, [String])] = []
        var calls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }
        func append(_ c: (String, [String])) { lock.lock(); _calls.append(c); lock.unlock() }
    }

    func testSignedInOffersGeminiWithItsListedModels() throws {
        try install(["claude", "agy"])
        let listed = String(decoding: try fixture("gemini-models", "txt", Self.self), as: UTF8.self)
        let calls = CallLog()
        let available = TriageSettings.available(path: bin.path, probe: probe(listed, exit: 0, calls: calls))
        XCTAssertEqual(available.harnesses, [.claude, .gemini])
        XCTAssertEqual(available.models[.gemini], GeminiProfile().parseModelList(listed))
        XCTAssertEqual(available.choice(for: .gemini)?.effort, "high")
        XCTAssertNil(available.unavailable[.gemini])
        // The ONLY agy command detection may run: `agy models`, which never starts a sign-in.
        XCTAssertEqual(calls.calls.map(\.0), ["agy"])
        XCTAssertEqual(calls.calls.map(\.1), [["models"]])
        XCTAssertEqual(RoundConfigEditor.harnesses(in: available), [.claude, .gemini])
    }

    func testSignedOutIsUnavailableWithTheSignInHint() throws {
        try install(["claude", "agy"])
        let text = String(decoding: try fixture("gemini-models-signed-out", "txt", Self.self), as: UTF8.self)
        let available = TriageSettings.available(path: bin.path, probe: probe(text, exit: 1))
        XCTAssertEqual(available.harnesses, [.claude])
        XCTAssertEqual(available.unavailable[.gemini], "Gemini: run `agy` in a terminal to sign in")
        XCTAssertEqual(RoundConfigEditor.unavailableNotes(available), ["Gemini: run `agy` in a terminal to sign in"])
    }

    func testNotInstalledNeverRunsTheProbe() throws {
        try install(["claude", "codex", "gemini"])   // the old gemini CLI is not what this harness drives
        let calls = CallLog()
        let available = TriageSettings.available(path: bin.path, probe: probe("x", exit: 0, calls: calls))
        XCTAssertEqual(available.harnesses, [.codex, .claude])
        XCTAssertEqual(available.unavailable[.gemini], "Gemini: not installed")
        XCTAssertTrue(calls.calls.isEmpty)
        XCTAssertEqual(RoundConfigEditor.unavailableNotes(available), [])
    }

    /// An exit-0 check that lists nothing is not proof of a signed-in account.
    func testAnEmptyModelListIsNotSignedIn() throws {
        try install(["agy"])
        let available = TriageSettings.available(path: bin.path, probe: probe("", exit: 0))
        XCTAssertNil(available.choice(for: .gemini))
        XCTAssertNotNil(available.unavailable[.gemini])
    }

    func testEditorKnobsForGemini() {
        XCTAssertEqual(RoundConfigEditor.effortChoices(for: .gemini), ["low", "medium", "high"])
        var available = AvailableModels(choices: [.claude: ModelChoice(harness: .claude, model: "opus", effort: "high"),
                                                  .gemini: ModelChoice(harness: .gemini, model: "g1", effort: "high")])
        available.models[.gemini] = ["g1", "g2"]
        XCTAssertEqual(RoundConfigEditor.modelChoices(for: .gemini, current: "g2", available: available), ["g1", "g2"])
        XCTAssertEqual(RoundConfigEditor.modelChoices(for: .gemini, current: "old", available: available), ["old", "g1", "g2"])
        XCTAssertEqual(RoundConfigEditor.modelChoices(for: .claude, current: "opus", available: available), [])
        // Cross-family: a gemini seat's fallback is another family; claude's stays as it was.
        let gemini = ModelChoice(harness: .gemini, model: "g1", effort: "high")
        XCTAssertEqual(RoundConfigEditor.otherModel(for: gemini, available: available)?.harness, .claude)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: available.claude!, available: available)?.harness, .gemini)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: available.claude!, available: .defaults)?.harness, .codex)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: AvailableModels.defaults.codex!, available: .defaults)?.harness, .claude)
    }
}

// MARK: - Seats

final class GeminiSeatTests: XCTestCase {
    private let gemini = ModelChoice(harness: .gemini, model: "gemini-3.8-pro", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "B", effort: "medium")
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiSeatTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var project: URL { root.appendingPathComponent("project") }
    private var store: TapeStore { TapeStore(intakeDirectory: root.appendingPathComponent("intake")) }

    private func inputs(drafters: [Slot]) -> RoundInputs {
        let config = RoundConfig(drafters: drafters, synthesizer: Slot(claude, persona: .arbiter), reviewer: Slot(claude),
                                 integrator: claude, encoder: claude, polisher: claude, refinementCap: 2, polishCap: 1,
                                 freshEyesAndDedup: false, defaultPlay: .step, customized: false)
        return RoundInputs(intake: Intake(projectPath: project.path, intent: "Add dark mode"), config: config, tape: Tape(),
                           store: store, project: project, environment: ["PATH": "/usr/bin:/bin"],
                           now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    private func executor(_ runner: CommandRunner) -> RoundExecutor {
        RoundExecutor(runner: runner, graphReader: GraphReader(runner: runner, environment: [:]),
                      userHome: root.appendingPathComponent("home"))
    }

    /// Two parallel gemini drafters: each seat records ITS OWN conversation id from its own
    /// run — the id agy reported, never a shared or most-recent one.
    func testParallelGeminiDraftersEachKeepTheirOwnConversation() async throws {
        let runner = ScriptedHarnessRunner { call in
            let persona = call.prompt.contains("arbiter") ? "a" : "r"
            return ok(call, "conv-\(persona)-\(UUID().uuidString.prefix(4))", json(DraftOutput(plan: "# \(persona)")))
        }
        let result = try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true),
                                                    inputs(drafters: [Slot(gemini, persona: .arbiter), Slot(gemini, persona: .realist)]))
        guard case .checkpoint(let cp, _) = result else { return XCTFail("expected a checkpoint, got \(result)") }
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok, .ok])
        let sessions = cp.record.slots.compactMap(\.sessionID)
        XCTAssertEqual(Set(sessions).count, 2, "each seat its own conversation")
        let seats = runner.calls("drafter").filter { $0.executable == "agy" }
        XCTAssertEqual(seats.count, 2)
        for seat in seats {
            XCTAssertFalse(seat.isResume)
            XCTAssertFalse(seat.arguments.contains("--continue"))
            XCTAssertEqual(geminiFlag("--mode", in: seat.arguments), "plan")
        }
    }

    /// The preflight: a signed-out agy pauses the seat as `authExpired` and the real run is
    /// NEVER spawned — `agy -p` signed out opens a Google sign-in in the human's browser.
    func testSignedOutAgyPausesWithoutSpawningTheRun() async throws {
        let runner = ScriptedHarnessRunner { call in ok(call, "s", json(DraftOutput(plan: "# x"))) }
        runner.agyModels = CommandResult(stdout: Data("Fetching available models...\n".utf8),
                                         stderr: "Error: Please sign in to view available models. Launch the CLI without arguments to sign in.\n",
                                         exitCode: 1)
        let result = try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true),
                                                    inputs(drafters: [Slot(gemini)]))
        guard case .paused(let diagnosis, _) = result else { return XCTFail("expected a pause, got \(result)") }
        XCTAssertEqual(diagnosis.category, .authExpired)
        XCTAssertEqual(diagnosis.action, GeminiProfile.signInHint)
        let agyCalls = runner.calls.filter { $0.executable == "agy" }
        XCTAssertEqual(agyCalls.map(\.arguments), [["models"]], "only the sign-in check ran")
    }
}
