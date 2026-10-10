import XCTest
import IntakeKit
@testable import FlightDeck

/// The OpenCode `AgentProfile`: `opencode run` as a headless planning harness. Every stdout
/// below is the SHAPE `opencode run --format json` printed on opencode 1.18.34 (2026-10-09)
/// against the scripted fake model, with ids and paths replaced by synthetic ones.
final class OpenCodeProfileTests: XCTestCase {
    static let models = """
        opencode/big-pickle
        ollama/qwen3-coder:30b
        lmstudio/hf.co/org/model:q4
        """

    static func run(_ text: String, session: String = "ses_test1", message: String = "msg_2") -> Data {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("""
            {"type":"step_start","timestamp":1,"sessionID":"\(session)","part":{"id":"prt_1","messageID":"msg_1","sessionID":"\(session)","type":"step-start"}}
            {"type":"text","timestamp":2,"sessionID":"\(session)","part":{"id":"prt_2","messageID":"msg_1","sessionID":"\(session)","type":"text","text":"Let me look."}}
            {"type":"tool_use","timestamp":3,"sessionID":"\(session)","part":{"type":"tool","tool":"read","callID":"call_1","state":{"status":"completed","input":{"filePath":"/p/README.md"},"output":"a"}}}
            {"type":"step_finish","timestamp":4,"sessionID":"\(session)","part":{"reason":"tool-calls","messageID":"msg_1","type":"step-finish","tokens":{"input":10,"output":2,"reasoning":1,"cache":{"write":0,"read":5}},"cost":0.5}}
            {"type":"step_start","timestamp":5,"sessionID":"\(session)","part":{"messageID":"\(message)","type":"step-start"}}
            {"type":"text","timestamp":6,"sessionID":"\(session)","part":{"id":"prt_3","messageID":"\(message)","sessionID":"\(session)","type":"text","text":"\(escaped)"}}
            {"type":"step_finish","timestamp":7,"sessionID":"\(session)","part":{"reason":"stop","messageID":"\(message)","type":"step-finish","tokens":{"input":3,"output":4,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0.25}}

            """.utf8)
    }

    /// `run` exits 0 on a failed turn; this event is the only failure signal (probed with the
    /// fake model answering HTTP 400).
    static func failed(status: Int, message: String) -> Data {
        Data("""
            {"type":"error","timestamp":1,"sessionID":"ses_fail","error":{"name":"APIError","data":{"message":"\(message)","statusCode":\(status),"isRetryable":false}}}

            """.utf8)
    }

    private func request(access: HeadlessAccess = .readOnly, model: String = "ollama/qwen3-coder:30b",
                         effort: String = "", resume: String? = nil, cwd: String = "/p") -> HeadlessRequest {
        HeadlessRequest(agent: .opencode, model: model, effort: effort, cwd: URL(fileURLWithPath: cwd, isDirectory: true),
                        readableDirs: [URL(fileURLWithPath: "/intake")], prompt: "Review the plan.",
                        schemaFile: URL(fileURLWithPath: "/s.json"), schemaJSON: #"{"type":"object"}"#,
                        resumeSessionID: resume, access: access)
    }

    // MARK: Profile

    func testOpenCodeIsAHeadlessHarness() {
        let profile = OpenCodeProfile()
        XCTAssertNil(profile.unimplemented)
        XCTAssertEqual(profile.binaryName, "opencode")
        XCTAssertFalse(profile.hasNativeSchema, "run has no schema flag: the schema rides in the prompt")
        XCTAssertEqual(profile.modelCatalog.listArguments, ["models"])
        XCTAssertEqual(profile.modelCatalog.defaultPlanningModel, "", "empty = OpenCode's configured default")
        XCTAssertEqual(profile.modelCatalog.effortValues, [], "--variant is provider-specific")
        XCTAssertFalse(profile.modelCatalog.isEmpty)
        XCTAssertTrue(AgentProfiles.headlessReady.contains(.opencode))
        XCTAssertEqual(AgentProfiles.profile(for: .opencode).id, .opencode)
        XCTAssertEqual(AgentID.opencode.profile.id, .opencode, "the adapter's facet is the registry's profile")
        XCTAssertEqual(AgentID.planningOrder.last, .opencode)
    }

    func testParsesTheModelList() {
        XCTAssertEqual(OpenCodeProfile().parseModelList(Self.models),
                       ["opencode/big-pickle", "ollama/qwen3-coder:30b", "lmstudio/hf.co/org/model:q4"])
        XCTAssertEqual(OpenCodeProfile().parseModelList("Warning: something odd\nno-slash\n/leading\ntrailing/\n"), [])
    }

    /// `opencode models` exits 0 whether or not any provider is set up; a listed model is the
    /// evidence a run can use one.
    func testSignInCheck() {
        let check = OpenCodeProfile().signInCheck
        XCTAssertEqual(check.arguments, ["models"])
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: Self.models, stderr: "", exitCode: 0)), .ready)
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: "", stderr: "", exitCode: 0)),
                       .signedOut(hint: OpenCodeProfile.signInHint))
        XCTAssertEqual(check.readiness(SignInCheckOutput(stdout: Self.models, stderr: "", exitCode: 1)),
                       .signedOut(hint: OpenCodeProfile.signInHint))
    }

    // MARK: Command

    func testReadOnlyArgv() throws {
        let command = try HeadlessCommand.build(request())
        XCTAssertEqual(command.executable, "opencode")
        XCTAssertEqual(Array(command.arguments.prefix(9)),
                       ["run", "--format", "json", "--agent", OpenCodeProfile.readOnlyAgent, "--dir", "/p",
                        "-m", "ollama/qwen3-coder:30b"])
        XCTAssertEqual(command.arguments[command.arguments.count - 2], "--", "a prompt starting with - stays a message")
        let message = try XCTUnwrap(command.arguments.last)
        XCTAssertTrue(message.hasPrefix("Review the plan."))
        XCTAssertTrue(message.hasSuffix(#"{"type":"object"}"#), "the schema is in the prompt")
        XCTAssertFalse(command.arguments.contains("--auto"), "--auto approves everything not denied")
        XCTAssertFalse(command.arguments.contains("--variant"))
    }

    func testEmptyModelLeavesOpenCodesDefaultAndEffortIsAVariant() throws {
        let command = try HeadlessCommand.build(request(model: "", effort: "high", resume: "ses_prev"))
        XCTAssertFalse(command.arguments.contains("-m"))
        let variant = try XCTUnwrap(command.arguments.firstIndex(of: "--variant"))
        XCTAssertEqual(command.arguments[variant + 1], "high")
        let session = try XCTUnwrap(command.arguments.firstIndex(of: "-s"))
        XCTAssertEqual(command.arguments[session + 1], "ses_prev", "resume by the id the run reported, never --continue")
        XCTAssertFalse(command.arguments.contains("--continue"))
    }

    func testIntegratorArgv() throws {
        let work = "/intakes/i1/work"
        let command = try HeadlessCommand.build(request(access: .writeInWork(URL(fileURLWithPath: work, isDirectory: true)), cwd: work))
        let agent = try XCTUnwrap(command.arguments.firstIndex(of: "--agent"))
        XCTAssertEqual(command.arguments[agent + 1], OpenCodeProfile.integratorAgent)
        let dir = try XCTUnwrap(command.arguments.firstIndex(of: "--dir"))
        XCTAssertEqual(command.arguments[dir + 1], work)
    }

    // MARK: Environment

    private func config(_ env: [String: String]) throws -> [String: Any] {
        let text = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func permission(_ config: [String: Any], _ agent: String) -> [String: Any]? {
        ((config["agent"] as? [String: Any])?[agent] as? [String: Any])?["permission"] as? [String: Any]
    }

    func testReadOnlyEnvironment() throws {
        let command = try HeadlessCommand.build(request())
        let base = ["PATH": "/bin", "CLAUDE_CODE_CHILD_SESSION": "1", "HOME": "/Users/x"]
        let env = HeadlessCommand.environment(for: command, base: base, home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(env["OPENCODE_DISABLE_PROJECT_CONFIG"], "1", "a project opencode.json beat OPENCODE_PERMISSION when probed")
        XCTAssertEqual(env["OPENCODE_DISABLE_CLAUDE_CODE"], "1")
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(env["XDG_DATA_HOME"], "the built-in account is the base environment as is")
        let config = try config(env)
        let readOnly = try XCTUnwrap(permission(config, OpenCodeProfile.readOnlyAgent))
        XCTAssertEqual(readOnly["*"] as? String, "deny", "deny, not ask: an ask under run ends the turn")
        XCTAssertEqual(Set(readOnly.filter { $0.value as? String == "allow" }.keys), ["read", "grep", "glob", "list"])
        XCTAssertNil(permission(config, OpenCodeProfile.integratorAgent), "no edit grant exists in a read-only run")
    }

    func testAnAccountIsAnXDGDataRoot() throws {
        let command = try HeadlessCommand.build(request())
        let env = HeadlessCommand.environment(for: command, base: ["PATH": "/bin"],
                                              account: AgentAccountRef(id: "a", home: URL(fileURLWithPath: "/Users/x/.local/share-work")))
        XCTAssertEqual(env["XDG_DATA_HOME"], "/Users/x/.local/share-work")
        XCTAssertEqual(AgentID.opencode.homeEnvironmentKey, "XDG_DATA_HOME")
    }

    /// The integrator may edit only under its work dir, by a pattern relative to the git
    /// worktree holding it — the form OpenCode matches (probed).
    func testIntegratorEditRuleIsRelativeToTheWorktree() throws {
        let work = "/Users/x/Library/fd/intakes/i1/work"
        let command = try HeadlessCommand.build(request(access: .writeInWork(URL(fileURLWithPath: work, isDirectory: true)), cwd: work))
        let env = OpenCodeProfile().environment(base: [:], account: nil, arguments: command.arguments,
                                                fileExists: { $0 == "/Users/x/.git" })
        let edit = try XCTUnwrap(permission(try config(env), OpenCodeProfile.integratorAgent)?["edit"] as? [String: String])
        XCTAssertEqual(edit, ["*": "deny", "Library/fd/intakes/i1/work/*": "allow"])
    }

    func testWorktreePatternOutsideAnyRepositoryIsRootRelative() {
        XCTAssertEqual(OpenCodeProfile.worktreeRelativePattern(for: URL(fileURLWithPath: "/srv/w"), fileExists: { _ in false }),
                       "srv/w/*")
        XCTAssertEqual(OpenCodeProfile.worktreeRelativePattern(for: URL(fileURLWithPath: "/r/w"), fileExists: { $0 == "/r/w/.git" }),
                       "*", "the work dir IS the worktree")
    }

    /// OpenCode names a `/var/folders` (or `/tmp`) path by its REAL path, `private/var/…`.
    /// Foundation's `resolvingSymlinksInPath` strips `/private`, which made the rule match
    /// nothing — caught by `OpenCodeLiveTests`.
    func testWorktreePatternUsesTheRealPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oc-pattern-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pattern = OpenCodeProfile.worktreeRelativePattern(for: dir, fileExists: { _ in false })
        XCTAssertTrue(pattern.hasPrefix("private/"), pattern)
        XCTAssertTrue(pattern.hasSuffix("/\(dir.lastPathComponent)/*"), pattern)
    }

    // MARK: Output

    func testParsesTheLastMessagesJSON() throws {
        let parsed = try HeadlessOutput.parse(.opencode, stdout: Self.run(#"{"ok": true}"#))
        XCTAssertEqual(parsed.sessionID, "ses_test1")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: parsed.structured) as? [String: Bool], ["ok": true])
    }

    func testAFencedAnswerIsUnwrapped() throws {
        let parsed = try HeadlessOutput.parse(.opencode, stdout: Self.run("```json\n{\"ok\": 1}\n```"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: parsed.structured) as? [String: Int], ["ok": 1])
    }

    /// Prose is the normal failure of a schema-less harness — repairable, so its session must
    /// be reported even though the parse failed.
    func testProseIsNotJSONButKeepsItsSession() {
        let stdout = Self.run("Here is my review.")
        XCTAssertThrowsError(try HeadlessOutput.parse(.opencode, stdout: stdout)) { error in
            guard case HeadlessOutput.ParseError.notJSON = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(HeadlessOutput.reportedSession(.opencode, stdout: stdout), "ses_test1")
        let retry = SchemaRepair.retry(profile: OpenCodeProfile(),
                                       failure: Diagnosis(category: .invalidOutput, detail: "not JSON", action: ""),
                                       sessionID: "ses_test1", access: .readOnly, isRepair: false)
        XCTAssertEqual(retry?.resumeSessionID, "ses_test1")
    }

    func testAnErrorEventIsTheFailureAndIsClassified() throws {
        XCTAssertThrowsError(try HeadlessOutput.parse(.opencode, stdout: Self.failed(status: 400, message: "fake model refuses"))) { error in
            XCTAssertEqual(error as? HeadlessOutput.ParseError, .isError("400 fake model refuses"))
        }
        let limited = String(decoding: Self.failed(status: 429, message: "slow down"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(OpenCodeProfile().classify(error: .streamErrorEvent(json: limited)), .rateLimited)
        let auth = String(decoding: Self.failed(status: 401, message: "bad key"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(OpenCodeProfile().classify(error: .streamErrorEvent(json: auth)), .authExpired)
    }

    // MARK: Activity

    func testTheSeatRowFollowsTheStream() {
        var parser = ActivityParser(agent: .opencode, project: URL(fileURLWithPath: "/p"), now: { Date(timeIntervalSince1970: 0) })
        let lines = String(decoding: Self.run(#"{"ok": true}"#), as: UTF8.self).split(separator: "\n")
        for line in lines.prefix(3) { parser.feed(Data((line + "\n").utf8)) }
        XCTAssertEqual(parser.activity.action?.verb, "Reading")
        XCTAssertEqual(parser.activity.headline, "Let me look.")
        for line in lines.dropFirst(3) { parser.feed(Data((line + "\n").utf8)) }
        XCTAssertEqual(parser.activity.inputTokens, 18)
        XCTAssertEqual(parser.activity.outputTokens, 7)
        XCTAssertEqual(parser.activity.costUSD, 0.75)
        XCTAssertTrue(parser.activity.finished)
        XCTAssertEqual(parser.activity.headline, "Let me look.", "the JSON answer is never a headline")
    }
}
