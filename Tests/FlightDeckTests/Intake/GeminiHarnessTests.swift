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
    HarnessRequest(harness: .gemini, model: "gemini-3.8-flash-low", effort: effort, cwd: URL(fileURLWithPath: cwd),
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
        XCTAssertEqual(cmd.arguments, ["-p", "P" + HarnessCommand.geminiReadOnlyNote, "--output-format", "stream-json",
                                       "--json-schema", "{}", "--model", "gemini-3.8-flash-low", "--disable-slash-commands",
                                       "--sandbox", "--add-dir", "/intake", "--add-dir", "/shadow"])
        XCTAssertEqual(cmd.unsetEnvironment, [])
    }

    /// The model id carries the effort; a separate `--effort` could only contradict it.
    func testNeverPassesEffort() throws {
        XCTAssertFalse(try HarnessCommand.build(geminiRequest(effort: "high"), home: noHome).arguments.contains("--effort"))
        XCTAssertEqual(GeminiProfile().modelCatalog.effortValues, [])
        XCTAssertEqual(RoundConfigEditor.effortChoices(for: .gemini), [], "the editor hides the knob")
    }

    /// Gemini refuses `null` inside `enum` (probed: 400 on the triage schema). The rewrite to
    /// `anyOf` must accept exactly the same values.
    func testSchemaIsRewrittenWithoutNullEnums() throws {
        let schema = #"{"type":"object","properties":{"preset":{"type":["string","null"],"enum":["a","b",null]},"n":{"type":["string","null"]}}}"#
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(GeminiSchema.compatible(schema).utf8)) as? [String: Any])
        let preset = try XCTUnwrap((rewritten["properties"] as? [String: Any])?["preset"] as? [String: Any])
        let anyOf = try XCTUnwrap(preset["anyOf"] as? [[String: Any]])
        XCTAssertEqual(anyOf[0]["type"] as? String, "string")
        XCTAssertEqual(anyOf[0]["enum"] as? [String], ["a", "b"])
        XCTAssertEqual(anyOf[1] as? [String: String], ["type": "null"])
        XCTAssertEqual((rewritten["properties"] as? [String: Any])?["n"] as? [String: [String]], ["type": ["string", "null"]],
                       "a nullable without an enum is left alone")
        // The real triage schema: no null survives in any enum.
        let triage = try String(decoding: fixture("triage-schema", "json", Self.self), as: UTF8.self)
        XCTAssertFalse(GeminiSchema.compatible(triage).contains(",null]"))
        XCTAssertTrue(triage.contains(",null]"))
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

    /// Read-only rests on agy's permission system: no mode that approves edits, never the
    /// skip flag (probed: with it, plan mode wrote files), and the sandbox for commands.
    func testReadOnlyNeverGrantsEditsOrSkipsPermissions() throws {
        for resume in [nil, "conv-7"] {
            let args = try HarnessCommand.build(geminiRequest(resume: resume), home: noHome).arguments
            XCTAssertNil(geminiFlag("--mode", in: args))
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
            XCTAssertTrue(args.contains("--sandbox"))
        }
    }

    func testWriteModeAcceptsEditsInTheWorkDirOnly() throws {
        let work = URL(fileURLWithPath: "/intake/work")
        let cmd = try HarnessCommand.build(geminiRequest(access: .writeInWork(work), cwd: "/intake/work"), home: noHome)
        XCTAssertEqual(geminiFlag("--mode", in: cmd.arguments), "accept-edits")
        XCTAssertTrue(cmd.arguments.contains("--sandbox"))
        XCTAssertEqual(geminiFlag("-p", in: cmd.arguments), "P", "the read-only note is not the integrator's")
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

    /// agy serves Claude and GPT-OSS models too; a gemini seat on one would be miscounted as
    /// the Gemini family, so build refuses it.
    func testANonGeminiModelIsRefused() {
        for model in ["claude-opus-5-5-high", "gpt-oss-120b-medium", "opus"] {
            var r = geminiRequest()
            r.model = model
            XCTAssertThrowsError(try HarnessCommand.build(r, home: noHome)) {
                XCTAssertEqual($0 as? HarnessCommand.HarnessCommandError, .modelOutsideFamily(harness: .gemini, model: model))
            }
        }
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
    /// A real `--output-format json` resume (agy 1.3.1): `structured_output` is the answer,
    /// although `response` carries extra keys the schema forbids.
    func testParsesTheJSONResult() throws {
        let out = try HarnessOutput.parse(.gemini, stdout: try fixture("gemini-p-json", "json", Self.self))
        XCTAssertEqual(out.sessionID, "ff16f91d-63eb-4721-a707-784844faf067")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["plan": "417"])
    }

    func testParsesTheStreamsFinalResult() throws {
        let out = try HarnessOutput.parse(.gemini, stdout: try fixture("gemini-stream-schema", "jsonl", Self.self))
        XCTAssertEqual(out.sessionID, "f3a73f46-c54b-44b9-a89d-5eeaeba5dda8")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String],
                       ["plan": "All actions executed, verified, and documented in plan and walkthrough artifacts."])
    }

    /// A real read-only turn that tried to write: SUCCESS, no answer, `denied_actions`. That is
    /// the answerless failure `SchemaRepair` resumes — and its conversation is still reported.
    func testATurnEndedByADeniedToolIsAnswerless() throws {
        let stdout = try fixture("gemini-denied-stream", "jsonl", Self.self)
        XCTAssertThrowsError(try HarnessOutput.parse(.gemini, stdout: stdout)) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .isError(GeminiProfile.answerlessTurnMarker + " (denied: write_file)"))
        }
        XCTAssertEqual(HarnessOutput.reportedSession(.gemini, stdout: stdout), "ff16f91d-63eb-4721-a707-784844faf067")
        XCTAssertNil(HarnessOutput.reportedSession(.claude, stdout: stdout))
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

    /// The response text is never taken as the answer, even when it is JSON.
    func testNeverTakesTheResponseTextAsTheAnswer() {
        let json = Data(#"{"conversation_id":"c1","status":"SUCCESS","response":"{\"a\":1}"}"#.utf8)
        XCTAssertThrowsError(try HarnessOutput.parse(.gemini, stdout: json)) {
            XCTAssertEqual($0 as? HarnessOutput.ParseError, .isError(GeminiProfile.answerlessTurnMarker))
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
                                          stderr: String(decoding: try fixture("gemini-bad-model-stderr", "txt", Self.self), as: UTF8.self),
                                          parseError: nil, harness: .gemini)
        XCTAssertEqual(d.category, .harnessError)
    }

    /// A schema Gemini's API refuses (probed with the un-rewritten triage schema) is the
    /// harness's fault, not the account's.
    func testRejectedSchemaIsAHarnessError() throws {
        let d = FailureDiagnosis.classify(exitCode: 3, stdout: try fixture("gemini-schema-rejected", "jsonl", Self.self),
                                          stderr: "", parseError: nil, harness: .gemini)
        XCTAssertEqual(d.category, .harnessError)
        XCTAssertTrue(d.detail.contains("INVALID_ARGUMENT"), d.detail)
    }

    func testUnverifiedAccountIsAuth() {
        let stdout = Data(#"{"conversation_id":"","status":"ERROR","response":"","error":"Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue."}"#.utf8)
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: stdout, stderr: "", parseError: nil, harness: .gemini)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `agy` in a terminal and verify your Google account")
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
        XCTAssertEqual(p.classify(error: .streamErrorEvent(json:
            #"{"event":"result","result":{"conversation_id":"","status":"ERROR","error":"RESOURCE_EXHAUSTED"}}"#)), .rateLimited)
        XCTAssertEqual(p.classify(error: .stderr("model is overloaded")), .overloaded)
        XCTAssertNil(p.classify(error: .stderr("invalid model selection: x not recognized")))
    }
}

// MARK: - Activity

final class GeminiActivityParserTests: XCTestCase {
    /// The real read-only triage stream (agy 1.3.1): it read README.md, then tried a shell
    /// command the headless mode denied, which ended the turn without an answer.
    func testFoldsTheStream() throws {
        let tick = Date(timeIntervalSince1970: 9)
        var parser = ActivityParser(harness: .gemini, project: URL(fileURLWithPath: "/proj"), now: { tick })
        parser.feed(try fixture("gemini-stream-activity", "jsonl", Self.self))
        let a = parser.activity
        XCTAssertEqual(a.lastEventAt, tick)
        XCTAssertEqual(a.action, ActivityAction(verb: "Running", object: "git status"))
        XCTAssertEqual(a.footprint, [".": 1])
        XCTAssertEqual(a.inputTokens, 28387)
        XCTAssertEqual(a.outputTokens, 136)
        XCTAssertTrue(a.finished)
        XCTAssertEqual(a.error, "denied: command")
        XCTAssertNil(a.rateLimitWindows)
    }

    func testFoldsASuccessfulStream() throws {
        var parser = ActivityParser(harness: .gemini, project: URL(fileURLWithPath: "/proj"), now: { Date() })
        parser.feed(try fixture("gemini-stream-schema", "jsonl", Self.self))
        XCTAssertTrue(parser.activity.finished)
        XCTAssertNil(parser.activity.error)
        XCTAssertEqual(parser.activity.footprint["."], 2, "README.md and NOTES.md")
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

    /// agy's answerless turn (a denied tool) is resumed once even though agy has a native
    /// schema — and only that failure, only read-only, only once.
    func testAnAnswerlessGeminiTurnIsResumedOnce() {
        let answerless = Diagnosis(category: .invalidOutput,
                                   detail: "isError(\"\(GeminiProfile.answerlessTurnMarker) (denied: write_file)\")", action: "")
        XCTAssertEqual(SchemaRepair.retry(profile: GeminiProfile(), failure: answerless, sessionID: "C1", access: .readOnly, isRepair: false),
                       SchemaRepair.Retry(resumeSessionID: "C1", prompt: SchemaRepair.answerlessPrompt))
        XCTAssertNil(SchemaRepair.retry(profile: GeminiProfile(), failure: answerless, sessionID: "C1", access: .readOnly, isRepair: true))
        XCTAssertNil(SchemaRepair.retry(profile: GeminiProfile(), failure: answerless, sessionID: nil, access: .readOnly, isRepair: false))
        XCTAssertNil(SchemaRepair.retry(profile: GeminiProfile(), failure: answerless, sessionID: "C1",
                                        access: .writeInWork(URL(fileURLWithPath: "/w")), isRepair: false))
        XCTAssertNil(SchemaRepair.retry(profile: ClaudeProfile(), failure: answerless, sessionID: "C1", access: .readOnly, isRepair: false),
                     "claude has no answerless failure")
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

    /// The captured `agy models` (agy 1.3.1): `<id>\t<name>` lines, Gemini and other vendors'
    /// models mixed. Only Gemini ids are this harness's.
    func testModelListKeepsOnlyGeminiIDs() throws {
        let listed = GeminiProfile().parseModelList(String(decoding: try fixture("gemini-models", "txt", Self.self), as: UTF8.self))
        // agy lists Flash first; the planning default leads, since detection seeds seats with `first`.
        XCTAssertEqual(listed.first, GeminiProfile.defaultPlanningModel)
        XCTAssertEqual(listed.dropFirst().first, "gemini-3.8-flash-high")
        XCTAssertTrue(listed.contains(GeminiProfile.defaultPlanningModel))
        XCTAssertTrue(listed.allSatisfy { $0.hasPrefix("gemini-") && !$0.contains("\t") })
        XCTAssertEqual(listed.count, 11)
    }

    func testSignedInOffersGeminiWithItsListedModels() throws {
        try install(["claude", "agy"])
        let listed = String(decoding: try fixture("gemini-models", "txt", Self.self), as: UTF8.self)
        let calls = CallLog()
        let available = TriageSettings.available(path: bin.path, probe: probe(listed, exit: 0, calls: calls))
        XCTAssertEqual(available.harnesses, [.claude, .gemini])
        XCTAssertEqual(available.models[.gemini], GeminiProfile().parseModelList(listed))
        XCTAssertEqual(available.choice(for: .gemini)?.model, "gemini-3.1-pro-high")
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

    func testEditorKnobsForGemini() throws {
        XCTAssertEqual(RoundConfigEditor.effortChoices(for: .gemini), [], "the model id carries the effort")
        var available = AvailableModels(choices: [.claude: ModelChoice(harness: .claude, model: "opus", effort: "high"),
                                                  .gemini: ModelChoice(harness: .gemini, model: "g1", effort: "high")])
        available.models[.gemini] = ["g1", "g2"]
        // The model menu offers what `agy models` listed at detection.
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .gemini, detected: available.models[.gemini] ?? []), ["g1", "g2"])
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .gemini), [GeminiProfile.defaultPlanningModel])
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
            XCTAssertNil(geminiFlag("--mode", in: seat.arguments))
            XCTAssertTrue(seat.arguments.contains("--sandbox"))
        }
    }

    /// A drafter whose turn agy ended on a denied tool is resumed ONCE, on its own conversation,
    /// and the resumed answer stands.
    func testAnAnswerlessDrafterIsResumedOnItsOwnConversation() async throws {
        let denied = try fixture("gemini-denied-stream", "jsonl", Self.self)
        let runner = ScriptedHarnessRunner { call in
            call.isResume ? ok(call, "ff16f91d-63eb-4721-a707-784844faf067", json(DraftOutput(plan: "# recovered")))
                          : CommandResult(stdout: denied, stderr: "", exitCode: 0)
        }
        let result = try await executor(runner).run(PlannedRound(stage: .draft, round: 0, major: true),
                                                    inputs(drafters: [Slot(gemini)]))
        guard case .checkpoint(let cp, let files) = result else { return XCTFail("expected a checkpoint, got \(result)") }
        XCTAssertEqual(cp.record.slots.map(\.status), [.ok])
        XCTAssertEqual(files["drafts/0.md"].map { String(decoding: $0, as: UTF8.self) }, "# recovered")
        let runs = runner.calls.filter { $0.executable == "agy" && $0.arguments != ["models"] }
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(geminiFlag("--conversation", in: runs[1].arguments), "ff16f91d-63eb-4721-a707-784844faf067")
        XCTAssertTrue(runs[1].prompt.hasPrefix(SchemaRepair.answerlessPrompt))
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
