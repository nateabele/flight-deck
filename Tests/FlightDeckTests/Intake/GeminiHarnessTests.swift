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

private func geminiRequest(resume: String? = nil, access: HeadlessAccess = .readOnly, cwd: String = "/proj",
                           effort: String = "high") -> HeadlessRequest {
    HeadlessRequest(agent: .gemini, model: "gemini-3.8-flash-low", effort: effort, cwd: URL(fileURLWithPath: cwd),
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
        let cmd = try HeadlessCommand.build(geminiRequest(), home: noHome)
        XCTAssertEqual(cmd.executable, "agy")
        XCTAssertEqual(cmd.arguments, ["-p", "P" + HeadlessCommand.geminiReadOnlyNote, "--output-format", "stream-json",
                                       "--json-schema", "{}", "--model", "gemini-3.8-flash-low", "--disable-slash-commands",
                                       "--project", "flight-deck-planning", "--add-dir", "/intake", "--add-dir", "/shadow"])
        XCTAssertEqual(cmd.unsetEnvironment, [])
    }

    /// Reads come from the FD-owned agy project; the integrator (accept-edits in its work dir)
    /// reads nothing but its own directory and must not carry the read grants.
    func testOnlyReadOnlySeatsRunUnderThePlanningProject() throws {
        XCTAssertEqual(geminiFlag("--project", in: try HeadlessCommand.build(geminiRequest(), home: noHome).arguments),
                       GeminiPlanningProject.id)
        let work = URL(fileURLWithPath: "/intake/work")
        let integrator = try HeadlessCommand.build(geminiRequest(access: .writeInWork(work), cwd: "/intake/work"), home: noHome)
        XCTAssertFalse(integrator.arguments.contains("--project"))
    }

    /// Building a read-only seat's command puts the project in place (a fresh machine, or one
    /// where it was deleted); a write-mode build does not touch the operator's agy config.
    func testBuildInstallsTheProjectForReadOnlySeatsOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fd-gemini-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = GeminiPlanningProject.fileURL(home: home)
        let work = URL(fileURLWithPath: "/intake/work")
        _ = try HeadlessCommand.build(geminiRequest(access: .writeInWork(work), cwd: "/intake/work"), home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try HeadlessCommand.build(geminiRequest(), home: home)
        XCTAssertEqual(try Data(contentsOf: file), GeminiPlanningProject.fileContents())
    }

    /// The model id carries the effort; a separate `--effort` could only contradict it.
    func testNeverPassesEffort() throws {
        XCTAssertFalse(try HeadlessCommand.build(geminiRequest(effort: "high"), home: noHome).arguments.contains("--effort"))
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
        let args = try HeadlessCommand.build(geminiRequest(resume: "conv-7"), home: noHome).arguments
        XCTAssertEqual(geminiFlag("--conversation", in: args), "conv-7")
        XCTAssertEqual(args.suffix(2), ["--conversation", "conv-7"])
    }

    /// `--continue`/`-c` resumes the MOST RECENT conversation — with parallel seats, another
    /// seat's. It must never appear, fresh or resumed.
    func testNeverResumesTheMostRecentConversation() throws {
        for resume in [nil, "conv-7"] {
            let args = try HeadlessCommand.build(geminiRequest(resume: resume), home: noHome).arguments
            XCTAssertFalse(args.contains("--continue"))
            XCTAssertFalse(args.contains("-c"))
        }
    }

    /// Read-only rests on agy's permission system: no mode that approves edits, never the
    /// skip flag (probed: with it, plan mode wrote files). No `--sandbox` either: on agy 1.3.6 it
    /// hides every directory outside the project from the seat's shell and is no write boundary
    /// (`sed -i` ran under it); the planning project's rules are.
    func testReadOnlyNeverGrantsEditsOrSkipsPermissions() throws {
        for resume in [nil, "conv-7"] {
            let args = try HeadlessCommand.build(geminiRequest(resume: resume), home: noHome).arguments
            XCTAssertNil(geminiFlag("--mode", in: args))
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
            XCTAssertFalse(args.contains("--sandbox"))
            XCTAssertEqual(geminiFlag("--project", in: args), GeminiPlanningProject.id)
        }
    }

    func testWriteModeAcceptsEditsInTheWorkDirOnly() throws {
        let work = URL(fileURLWithPath: "/intake/work")
        let cmd = try HeadlessCommand.build(geminiRequest(access: .writeInWork(work), cwd: "/intake/work"), home: noHome)
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
        XCTAssertEqual(HeadlessCommand.validate(geminiRequest(resume: "conv-7", access: .writeInWork(work), cwd: "/intake/work")),
                       .resumeNotSupportedForWrite)
    }

    /// agy serves Claude and GPT-OSS models too; a gemini seat on one would be miscounted as
    /// the Gemini family, so build refuses it.
    func testANonGeminiModelIsRefused() {
        for model in ["claude-opus-5-5-high", "gpt-oss-120b-medium", "opus"] {
            var r = geminiRequest()
            r.model = model
            XCTAssertThrowsError(try HeadlessCommand.build(r, home: noHome)) {
                XCTAssertEqual($0 as? HeadlessCommand.HeadlessCommandError, .modelOutsideFamily(agent: .gemini, model: model))
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
        let out = try HeadlessOutput.parse(.gemini, stdout: try fixture("gemini-p-json", "json", Self.self))
        XCTAssertEqual(out.sessionID, "ff16f91d-63eb-4721-a707-784844faf067")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["plan": "417"])
    }

    func testParsesTheStreamsFinalResult() throws {
        let out = try HeadlessOutput.parse(.gemini, stdout: try fixture("gemini-stream-schema", "jsonl", Self.self))
        XCTAssertEqual(out.sessionID, "f3a73f46-c54b-44b9-a89d-5eeaeba5dda8")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String],
                       ["plan": "All actions executed, verified, and documented in plan and walkthrough artifacts."])
    }

    /// A real read-only turn that tried to write: SUCCESS, no answer, `denied_actions`. That is
    /// the answerless failure `SchemaRepair` resumes — and its conversation is still reported.
    func testATurnEndedByADeniedToolIsAnswerless() throws {
        let stdout = try fixture("gemini-denied-stream", "jsonl", Self.self)
        XCTAssertThrowsError(try HeadlessOutput.parse(.gemini, stdout: stdout)) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .isError(GeminiProfile.answerlessTurnMarker + " (denied: write_file)"))
        }
        XCTAssertEqual(HeadlessOutput.reportedSession(.gemini, stdout: stdout), "ff16f91d-63eb-4721-a707-784844faf067")
        XCTAssertNil(HeadlessOutput.reportedSession(.claude, stdout: stdout))
    }

    /// A signed-out run reports an ERROR result with an EMPTY conversation id: the error must
    /// win over "no session", or the diagnosis would never see the auth text.
    func testAnErrorResultIsAnErrorNotAnAnswer() throws {
        XCTAssertThrowsError(try HeadlessOutput.parse(.gemini, stdout: try fixture("gemini-auth-stdout", "jsonl", Self.self))) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .isError("authentication failed or timed out"))
        }
    }

    func testAStreamThatNeverFinishedHasNoResult() {
        let stdout = Data(#"{"event":"init","conversation_id":"c1","init":{}}"#.utf8 + [0x0A])
        XCTAssertThrowsError(try HeadlessOutput.parse(.gemini, stdout: stdout)) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .noResult)
        }
        XCTAssertThrowsError(try HeadlessOutput.parse(.gemini, stdout: Data())) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .noSession)
        }
    }

    /// The response text is never taken as the answer, even when it is JSON.
    func testNeverTakesTheResponseTextAsTheAnswer() {
        let json = Data(#"{"conversation_id":"c1","status":"SUCCESS","response":"{\"a\":1}"}"#.utf8)
        XCTAssertThrowsError(try HeadlessOutput.parse(.gemini, stdout: json)) {
            XCTAssertEqual($0 as? HeadlessOutput.ParseError, .isError(GeminiProfile.answerlessTurnMarker))
        }
    }
}

// MARK: - Planning project

/// The permission rules a read-only Gemini seat runs under. The live behaviour (reads allowed,
/// writes refused) was probed on agy 1.3.6 on 2026-10-15; these pin what Flight Deck writes.
final class GeminiPlanningProjectTests: XCTestCase {
    private func grants() throws -> (allow: [String], deny: [String], root: [String: Any]) {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: GeminiPlanningProject.fileContents()) as? [String: Any])
        let outer = try XCTUnwrap(root["permissionGrants"] as? [String: Any])
        let inner = try XCTUnwrap(outer["permissionGrants"] as? [String: Any])
        XCTAssertEqual(outer["v2Migrated"] as? Bool, true)
        return (try XCTUnwrap(inner["allow"] as? [String]), try XCTUnwrap(inner["deny"] as? [String]), root)
    }

    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fd-gemini-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testTheFileIsAnAgyProject() throws {
        let root = try grants().root
        XCTAssertEqual(root["id"] as? String, "flight-deck-planning")
        XCTAssertEqual(root["name"] as? String, GeminiPlanningProject.displayName)
        XCTAssertNotNil(root["projectResources"] as? [String: Any])
        XCTAssertEqual(GeminiPlanningProject.fileURL(home: URL(fileURLWithPath: "/h")).path,
                       "/h/.gemini/config/projects/flight-deck-planning.json")
    }

    /// What a planning seat reads: any file (the plan files, the task-graph snapshot, AGENTS.md,
    /// README, source, a sibling repository) and the listing and search commands.
    func testAllowsReadsAnywhereAndTheReadingCommands() throws {
        let allow = try grants().allow
        XCTAssertTrue(allow.contains("read_file(/)"))
        for command in ["ls", "cat", "head", "tail", "wc", "rg", "grep", "cd", "git log", "git diff", "git status", "br list", "br show"] {
            XCTAssertTrue(allow.contains("command(\(command))"), command)
        }
    }

    /// Writes stay refused: every writer is denied by name (a deny is an error the seat reads;
    /// an unlisted command ends its turn), and nothing that can write is allowed.
    func testDeniesEveryWriterAndAllowsNone() throws {
        let (allow, deny, _) = try grants()
        XCTAssertTrue(deny.contains("write_file(/)"))
        for command in ["rm", "mv", "cp", "touch", "mkdir", "tee", "sed", "awk", "find", "xargs", "sh", "bash",
                        "git add", "git commit", "git push", "git checkout", "git reset", "br create", "br close", "br update"] {
            XCTAssertTrue(deny.contains("command(\(command))"), command)
        }
        XCTAssertTrue(Set(allow).isDisjoint(with: deny), "an allow that a deny shadows is a rule nobody can read")
        XCTAssertFalse(allow.contains { $0.hasPrefix("write_file") })
        for writer in ["sed", "awk", "find", "tee", "sh", "bash", "xargs", "git commit", "git add"] {
            XCTAssertFalse(allow.contains("command(\(writer))"), writer)
        }
    }

    /// A command the rules don't name is auto-denied and ENDS the seat's turn (a Polish round
    /// was lost to `grep … | sort | uniq -c`), while a denied one is an error the seat reads. So
    /// the usual pipeline filters are each either allowed or denied, never left out.
    func testEveryCommonPipelineFilterIsNamed() throws {
        let (allow, deny, _) = try grants()
        for command in ["sort", "uniq", "cut", "tr", "nl", "comm", "diff", "jq", "basename", "dirname", "realpath",
                        "printf", "date", "which", "column", "python3", "perl", "node", "ruby"] {
            XCTAssertTrue(allow.contains("command(\(command))") || deny.contains("command(\(command))"), command)
        }
        // These two write a file when given one (`sort -o`, `uniq in out`), so they are denied.
        XCTAssertTrue(deny.contains("command(sort)"))
        XCTAssertTrue(deny.contains("command(uniq)"))
    }

    func testBytesAreStable() {
        XCTAssertEqual(GeminiPlanningProject.fileContents(), GeminiPlanningProject.fileContents())
    }

    func testInstallWritesTheFileOnceAndRepairsAnEdit() throws {
        let home = try tempHome()
        let file = GeminiPlanningProject.fileURL(home: home)
        XCTAssertTrue(GeminiPlanningProject.install(home: home))
        XCTAssertEqual(try Data(contentsOf: file), GeminiPlanningProject.fileContents())
        // An unchanged file is not rewritten.
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertTrue(GeminiPlanningProject.install(home: home))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
        // A hand edit (or an agy rewrite that dropped the rules) is put back.
        try Data("{}".utf8).write(to: file)
        XCTAssertTrue(GeminiPlanningProject.install(home: home))
        XCTAssertEqual(try Data(contentsOf: file), GeminiPlanningProject.fileContents())
    }

    /// No `~/.gemini` means agy has never run: nothing to write for, and no stray directories.
    func testInstallSkipsAHomeWithoutAgy() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fd-no-agy-\(UUID().uuidString)")
        XCTAssertFalse(GeminiPlanningProject.install(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    /// The operator's own agy config is never opened for writing.
    func testInstallOnlyCreatesTheProjectFile() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"trustedWorkspaces":[]}"#.utf8).write(to: settings)
        XCTAssertTrue(GeminiPlanningProject.install(home: home))
        XCTAssertEqual(try Data(contentsOf: settings), Data(#"{"trustedWorkspaces":[]}"#.utf8))
    }
}

// MARK: - Diagnosis

final class GeminiFailureDiagnosisTests: XCTestCase {
    private func classify(_ stdoutName: String, stderrName: String? = nil) throws -> Diagnosis {
        let stdout = try fixture(stdoutName, "jsonl", Self.self)
        let stderr = try stderrName.map { String(decoding: try fixture($0, "txt", Self.self), as: UTF8.self) } ?? ""
        var parseError: Error?
        do { _ = try HeadlessOutput.parse(.gemini, stdout: stdout) } catch { parseError = error }
        return FailureDiagnosis.classify(exitCode: 0, stdout: stdout, stderr: stderr, parseError: parseError, agent: .gemini)
    }

    /// A real planning drafter (agy 1.3.6): it read the task graph, README and AGENTS.md, then
    /// ran `ls` on a sibling repository and agy auto-denied the shell command. It must read as
    /// a refused tool with the reason, not as a model that broke its schema — and still carry
    /// the marker `SchemaRepair` resumes on.
    func testADeniedShellCommandNamesTheCommandNotTheSchema() throws {
        let d = try classify("gemini-denied-command-stream", stderrName: "gemini-denied-command-stderr")
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertTrue(d.detail.contains(GeminiProfile.answerlessTurnMarker), d.detail)
        XCTAssertTrue(d.detail.contains("(denied: command)"), d.detail)
        XCTAssertTrue(d.detail.contains("a shell command"), d.detail)
        XCTAssertFalse(d.detail.contains("schema"), d.detail)
        XCTAssertTrue(d.action.contains("flight-deck-planning"), d.action)
        // A command the read-only list leaves out is denied however well the file was written
        // (`grep … | sort | uniq -c`, 2026-10-16), so the advice can't blame the file alone.
        XCTAssertTrue(d.action.contains("another agent"), d.action)
        XCTAssertNotNil(SchemaRepair.retry(profile: GeminiProfile(), failure: d, sessionID: "C1", access: .readOnly, isRepair: false),
                        "the one resume still fires on the reworded detail")
    }

    /// A `view_file` outside the workspace (agy 1.3.6, probed): `read_file` denied.
    func testADeniedFileReadNamesTheRead() throws {
        let d = try classify("gemini-denied-read-stream")
        XCTAssertEqual(d.category, .invalidOutput)
        XCTAssertTrue(d.detail.contains("(denied: read_file)"), d.detail)
        XCTAssertTrue(d.detail.contains("a file read"), d.detail)
        XCTAssertTrue(d.action.contains("Retry the round"), d.action)
    }

    /// A refused write is the read-only boundary working: the advice is about the model, not
    /// about the permissions.
    func testADeniedWriteIsNotAdvisedAsAPermissionFix() throws {
        let d = try classify("gemini-denied-stream")
        XCTAssertTrue(d.detail.contains("(denied: write_file)"), d.detail)
        XCTAssertFalse(d.action.contains("flight-deck-planning"), d.action)
    }

    func testOtherFailuresKeepTheGenericWording() {
        let d = FailureDiagnosis.classify(exitCode: 0, stdout: Data(), stderr: "", parseError: HeadlessOutput.ParseError.noResult, agent: .gemini)
        XCTAssertEqual(d.detail, "noResult")
        XCTAssertNil(GeminiProfile.deniedToolDiagnosis(HeadlessOutput.ParseError.isError("authentication failed")))
    }

    func testSignedOutRunIsAuthExpiredWithTheAgyFix() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("gemini-auth-stdout", "jsonl", Self.self),
                                          stderr: String(decoding: try fixture("gemini-auth-stderr", "txt", Self.self), as: UTF8.self),
                                          parseError: nil, agent: .gemini)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `agy` in a terminal to sign in")
    }

    func testAuthErrorReportedOnlyInTheStreamStillReadsAsAuth() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("gemini-auth-stdout", "jsonl", Self.self),
                                          stderr: "", parseError: nil, agent: .gemini)
        XCTAssertEqual(d.category, .authExpired)
    }

    func testBadModelIsAHarnessError() throws {
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: try fixture("gemini-bad-model-stdout", "jsonl", Self.self),
                                          stderr: String(decoding: try fixture("gemini-bad-model-stderr", "txt", Self.self), as: UTF8.self),
                                          parseError: nil, agent: .gemini)
        XCTAssertEqual(d.category, .harnessError)
    }

    /// A schema Gemini's API refuses (probed with the un-rewritten triage schema) is the
    /// harness's fault, not the account's.
    func testRejectedSchemaIsAHarnessError() throws {
        let d = FailureDiagnosis.classify(exitCode: 3, stdout: try fixture("gemini-schema-rejected", "jsonl", Self.self),
                                          stderr: "", parseError: nil, agent: .gemini)
        XCTAssertEqual(d.category, .harnessError)
        XCTAssertTrue(d.detail.contains("INVALID_ARGUMENT"), d.detail)
    }

    func testUnverifiedAccountIsAuth() {
        let stdout = Data(#"{"conversation_id":"","status":"ERROR","response":"","error":"Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue."}"#.utf8)
        let d = FailureDiagnosis.classify(exitCode: 1, stdout: stdout, stderr: "", parseError: nil, agent: .gemini)
        XCTAssertEqual(d.category, .authExpired)
        XCTAssertEqual(d.action, "Run `agy` in a terminal and verify your Google account")
    }

    /// UNVERIFIED spelling: no real agy rate limit has been captured. Google's API reports
    /// quota exhaustion as RESOURCE_EXHAUSTED; this pins that it would classify.
    func testResourceExhaustedIsRateLimited() {
        let stdout = Data(#"{"event":"result","result":{"conversation_id":"c","status":"ERROR","error":"RESOURCE_EXHAUSTED: quota"}}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: stdout, stderr: "", parseError: nil, agent: .gemini).category,
                       .rateLimited)
    }

    /// The model's own response is never read for error words.
    func testASuccessfulResultsResponseIsNeverMatched() {
        let stdout = Data(#"{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"401 authentication rate limit"}}"#.utf8)
        XCTAssertEqual(FailureDiagnosis.classify(exitCode: 1, stdout: stdout, stderr: "boom", parseError: nil, agent: .gemini).category,
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
        var parser = ActivityParser(agent: .gemini, project: URL(fileURLWithPath: "/proj"), now: { tick })
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
        var parser = ActivityParser(agent: .gemini, project: URL(fileURLWithPath: "/proj"), now: { Date() })
        parser.feed(try fixture("gemini-stream-schema", "jsonl", Self.self))
        XCTAssertTrue(parser.activity.finished)
        XCTAssertNil(parser.activity.error)
        XCTAssertEqual(parser.activity.footprint["."], 2, "README.md and NOTES.md")
    }

    func testAnErrorResultIsTheSeatsError() throws {
        var parser = ActivityParser(agent: .gemini, project: URL(fileURLWithPath: "/proj"), now: { Date() })
        parser.feed(try fixture("gemini-auth-stdout", "jsonl", Self.self))
        XCTAssertEqual(parser.activity.error, "authentication failed or timed out")
    }

    /// The structured answer streamed as text is not a headline.
    func testJSONResponseTextIsNotAHeadline() {
        var parser = ActivityParser(agent: .gemini, project: URL(fileURLWithPath: "/proj"), now: { Date() })
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
        var id: AgentID { .gemini }
        var family: AgentID { .gemini }
        var binaryName: String { "x" }
        var signInCheck: SignInCheck { SignInCheck(arguments: [], signedOutHint: "", isSignedIn: { _ in false }) }
        var modelCatalog: ProfileModelCatalog { .empty }
        func parseModelList(_ stdout: String) -> [String] { [] }
        var hasNativeSchema: Bool { false }
        func classify(error: AgentErrorSignal) -> AgentFailureKind? { nil }
        func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] { base }
    }
    private let invalid = Diagnosis(category: .invalidOutput, detail: "missing field plan\nsecond error", action: "")

    func testOneRetryResumingTheSameSession() throws {
        let retry = SchemaRepair.retry(profile: SchemaLess(), failure: invalid, sessionID: "S1", access: .readOnly, isRepair: false)
        XCTAssertEqual(retry, SchemaRepair.Retry(resumeSessionID: "S1",
            prompt: SchemaRepair.prompt(firstError: "missing field plan")))
        XCTAssertTrue(try XCTUnwrap(retry).prompt.hasPrefix(
            "Your reply did not validate: missing field plan. Reply again with only the corrected JSON."))
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
        for agent in AgentID.planningOrder where AgentProfiles.profile(for: agent).hasNativeSchema {
            XCTAssertNil(SchemaRepair.retry(profile: AgentProfiles.profile(for: agent), failure: invalid, sessionID: "S1",
                                            access: .readOnly, isRepair: false), "\(agent)")
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
        // The planning default leads, since detection seeds seats with `first`; agy's own order
        // follows it. (This capture still lists 3.1 Pro, which 3.8 Flash has since superseded.)
        XCTAssertEqual(listed.first, GeminiProfile.defaultPlanningModel)
        XCTAssertEqual(listed.dropFirst().first, "gemini-3.8-flash-medium")
        XCTAssertTrue(listed.contains(GeminiProfile.defaultPlanningModel))
        XCTAssertTrue(listed.allSatisfy { $0.hasPrefix("gemini-") && !$0.contains("\t") })
        XCTAssertEqual(listed.count, 11)
    }

    func testSignedInOffersGeminiWithItsListedModels() throws {
        try install(["claude", "agy"])
        let listed = String(decoding: try fixture("gemini-models", "txt", Self.self), as: UTF8.self)
        let calls = CallLog()
        let available = TriageSettings.available(path: bin.path, probe: probe(listed, exit: 0, calls: calls))
        XCTAssertEqual(available.agents, [.claude, .gemini])
        XCTAssertEqual(available.models[.gemini], GeminiProfile().parseModelList(listed))
        XCTAssertEqual(available.choice(for: .gemini)?.model, "gemini-3.8-flash-high")
        XCTAssertNil(available.unavailable[.gemini])
        // The ONLY agy command detection may run: `agy models`, which never starts a sign-in.
        XCTAssertEqual(calls.calls.map(\.0), ["agy"])
        XCTAssertEqual(calls.calls.map(\.1), [["models"]])
        XCTAssertEqual(RoundConfigEditor.agents(in: available), [.claude, .gemini])
    }

    func testSignedOutIsUnavailableWithTheSignInHint() throws {
        try install(["claude", "agy"])
        let text = String(decoding: try fixture("gemini-models-signed-out", "txt", Self.self), as: UTF8.self)
        let available = TriageSettings.available(path: bin.path, probe: probe(text, exit: 1))
        XCTAssertEqual(available.agents, [.claude])
        XCTAssertEqual(available.unavailable[.gemini], "Gemini: run `agy` in a terminal to sign in")
        XCTAssertEqual(RoundConfigEditor.unavailableNotes(available), ["Gemini: run `agy` in a terminal to sign in"])
    }

    func testNotInstalledNeverRunsTheProbe() throws {
        try install(["claude", "codex", "gemini"])   // the old gemini CLI is not what this agent drives
        let calls = CallLog()
        let available = TriageSettings.available(path: bin.path, probe: probe("x", exit: 0, calls: calls))
        XCTAssertEqual(available.agents, [.codex, .claude])
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
        var available = AvailableModels(choices: [.claude: ModelChoice(agent: .claude, model: "opus", effort: "high"),
                                                  .gemini: ModelChoice(agent: .gemini, model: "g1", effort: "high")])
        available.models[.gemini] = ["g1", "g2"]
        // The model menu offers what `agy models` listed at detection.
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .gemini, detected: available.models[.gemini] ?? []), ["g1", "g2"])
        XCTAssertEqual(RoundConfigEditor.modelSuggestions(for: .gemini), [GeminiProfile.defaultPlanningModel])
        // Cross-family: a gemini seat's fallback is another family; claude's stays as it was.
        let gemini = ModelChoice(agent: .gemini, model: "g1", effort: "high")
        XCTAssertEqual(RoundConfigEditor.otherModel(for: gemini, available: available)?.agent, .claude)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: available.claude!, available: available)?.agent, .gemini)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: available.claude!, available: .defaults)?.agent, .codex)
        XCTAssertEqual(RoundConfigEditor.otherModel(for: AvailableModels.defaults.codex!, available: .defaults)?.agent, .claude)
    }
}

// MARK: - Seats

final class GeminiSeatTests: XCTestCase {
    private let gemini = ModelChoice(agent: .gemini, model: "gemini-3.8-pro", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "B", effort: "medium")
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
            XCTAssertEqual(geminiFlag("--project", in: seat.arguments), GeminiPlanningProject.id)
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
