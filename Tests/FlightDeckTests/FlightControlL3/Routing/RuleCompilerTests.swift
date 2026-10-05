import XCTest
import IntakeKit

private final class CannedRunner: CommandRunner, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let cwd: URL; let environment: [String: String] }
    var result: Result<CommandResult, Error>
    private(set) var calls: [Call] = []
    init(_ result: Result<CommandResult, Error>) { self.result = result }
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, cwd: cwd, environment: environment))
        return try result.get()
    }
}

/// One cheap headless call per sentence, constrained by a schema, then validated (spec L3-R §3).
/// The model output is a fixture; each validation failure is that fixture with one field swapped.
final class RuleCompilerTests: XCTestCase {
    private typealias D = RoutingTestData
    private var work: URL!

    override func setUp() {
        super.setUp()
        work = FileManager.default.temporaryDirectory.appendingPathComponent("RuleCompilerTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: work); super.tearDown() }

    private func compiler(_ runner: CannedRunner, settings: RuleCompilerSettings = .default) -> RuleCompiler {
        // `home: work` so `HarnessCommand` never reads the operator's own codex/claude settings.
        RuleCompiler(runner: runner, settings: settings, workDirectory: work, home: work,
                     baseEnvironment: { ["PATH": "/usr/bin", "CLAUDECODE": "1"] })
    }

    private func ok(_ stdout: Data) -> CannedRunner { CannedRunner(.success(CommandResult(stdout: stdout, stderr: "", exitCode: 0))) }

    private func stream(_ wire: RuleCompilerWire) throws -> Data {
        let structured = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire))
        let result: [String: Any] = ["type": "result", "subtype": "success", "is_error": false,
                                     "session_id": "rc-fixture-1", "result": "", "structured_output": structured]
        let initLine = #"{"type":"system","subtype":"init","session_id":"rc-fixture-1"}"#
        let resultLine = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        return Data((initLine + "\n" + resultLine + "\n").utf8)
    }

    private func recordedWire() throws -> RuleCompilerWire {
        let parsed = try HarnessOutput.parse(.claude, stdout: RoutingFixtures.data("compiler-valid.claude.jsonl"))
        return try JSONDecoder().decode(RuleCompilerWire.self, from: parsed.structured)
    }

    private func outcome(_ runner: CannedRunner, settings: RuleCompilerSettings = .default) async -> RuleCompileOutcome {
        let input = D.input()
        let proposal = await compiler(runner, settings: settings).propose(input)
        return RuleCompilation.finish(proposal, input: input)
    }

    func testTheRecordedOutputCompilesToTheSpecRule() async throws {
        let result = await outcome(ok(try RoutingFixtures.data("compiler-valid.claude.jsonl")))
        XCTAssertEqual(result, .compiled(D.r3().compiled!))
    }

    func testItRunsHeadlessClaudeHaikuWithTheStrictSchema() async throws {
        let runner = ok(try RoutingFixtures.data("compiler-valid.claude.jsonl"))
        _ = await compiler(runner).propose(D.input())
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, "claude")
        XCTAssertEqual(call.arguments.first, "-p")
        XCTAssertEqual(call.arguments[try XCTUnwrap(call.arguments.firstIndex(of: "--model")) + 1], "haiku")
        XCTAssertEqual(call.arguments[try XCTUnwrap(call.arguments.firstIndex(of: "--json-schema")) + 1], RuleCompilerPrompt.schemaJSON)
        XCTAssertEqual(call.cwd, work)
        XCTAssertNil(call.environment["CLAUDECODE"], "a claude spawned from inside Claude Code must not inherit the child marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("rule-schema.json").path))
    }

    func testCodexCanBeTheCompiler() async throws {
        let text = String(decoding: try JSONEncoder().encode(D.specWire), as: UTF8.self)
        let msg = try JSONSerialization.data(withJSONObject: ["type": "item.completed", "item": ["type": "agent_message", "text": text]])
        let stdout = Data((#"{"type":"thread.started","thread_id":"T1"}"# + "\n" + String(decoding: msg, as: UTF8.self) + "\n").utf8)
        let runner = ok(stdout)
        let result = await outcome(runner, settings: RuleCompilerSettings(harness: .codex, model: "gpt-6-luna", effort: "low"))
        XCTAssertEqual(result, .compiled(D.r3().compiled!))
        XCTAssertEqual(runner.calls.first?.executable, "codex")
        XCTAssertTrue(runner.calls.first?.arguments.contains("--output-schema") == true)
    }

    func testEveryValidationFailureFailsWithItsMessage() async throws {
        let base = try recordedWire()
        let cases: [(String, (inout RuleCompilerWire) -> Void, RuleValidationError)] = [
            ("dimension", { $0.terms[0].dimension = "teleportation" }, .unknownDimension("teleportation")),
            ("kind", { $0.terms[2].kind = "astrology" }, .unknownKind("astrology")),
            ("agent", { $0.harness = "gemini" }, .unknownHarness("gemini")),
            ("model", { $0.model = "gpt-9" }, .unknownModel("codex", "gpt-9")),
            ("knob", { $0.knobs = [.init(name: "effort", value: "max")] }, .knobRejected("codex", "gpt-6-sol", "effort", "max")),
            ("pool", { $0.pool = "nowhere" }, .unknownPool("nowhere")),
            ("pool owner", { $0.pool = "claude-subs" }, .poolBelongsElsewhere("claude-subs", owner: "claude", harness: "codex")),
            ("declined", { $0.ok = false; $0.reason = "that is not a routing rule" }, .declined("that is not a routing rule")),
        ]
        for (name, change, expected) in cases {
            var w = base
            change(&w)
            let result = await outcome(ok(try stream(w)))
            XCTAssertEqual(result, .failed(expected.message), name)
        }
    }

    func testANonZeroExitIsUnavailable() async {
        let runner = CannedRunner(.success(CommandResult(stdout: Data(), stderr: "Not logged in\nmore", exitCode: 1)))
        let result = await outcome(runner)
        XCTAssertEqual(result, .unavailable("claude exited 1: Not logged in"))
    }

    func testAProcessThatCannotStartIsUnavailable() async {
        struct NoSpawn: Error {}
        let result = await outcome(CannedRunner(.failure(NoSpawn())))
        guard case .unavailable(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.hasPrefix("could not start claude"), why)
    }

    func testProseInsteadOfJSONFails() async {
        let prose = Data((#"{"type":"system","subtype":"init","session_id":"s"}"# + "\n"
            + #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"Sure! Here is your rule."}"# + "\n").utf8)
        let result = await outcome(ok(prose))
        guard case .failed(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.hasPrefix("the compiler gave no usable answer"), why)
    }

    func testRecordingMovesTheRuleThroughItsStates() {
        let ref = CompilerRef(harness: "claude", model: "haiku")
        var rule = RoutingRule(id: "r1", sentence: D.specSentence)
        rule.record(.unavailable("offline"), by: ref, at: D.at)
        XCTAssertEqual(rule.state, .draft); XCTAssertNil(rule.compiledAt)
        rule.record(.failed("unknown dimension teleportation"), by: ref, at: D.at)
        XCTAssertEqual(rule.state, .failed); XCTAssertEqual(rule.failure, "unknown dimension teleportation"); XCTAssertNil(rule.compiled)
        rule.record(.compiled(D.r3().compiled!), by: ref, at: D.at)
        XCTAssertEqual(rule.state, .compiled); XCTAssertNil(rule.failure)
        XCTAssertEqual(rule.compiler, ref); XCTAssertEqual(rule.compiledAt, D.at)
    }

    func testThePromptCarriesEveryInput() {
        let p = RuleCompilerPrompt.text(D.input())
        XCTAssertTrue(p.contains(D.specSentence))
        for d in Dimensions.all { XCTAssertTrue(p.contains(d.id), d.id) }
        XCTAssertTrue(p.contains("snapshot-tests"))
        XCTAssertFalse(p.contains("golden-tests"), "merged kinds are not offered for new conditions")
        XCTAssertTrue(p.contains("gpt-6-luna"))
        XCTAssertTrue(p.contains("effort = low | medium | high"))
        XCTAssertTrue(p.contains("- codex-subs (codex)"))
        XCTAssertTrue(p.contains("Default model: opus"))
    }

    func testTheSchemaIsStrict() throws {
        func strict(_ node: Any) {
            guard let obj = node as? [String: Any] else { return }
            if let props = obj["properties"] as? [String: Any] {
                XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
                XCTAssertEqual(Set(obj["required"] as? [String] ?? []), Set(props.keys))
                props.values.forEach(strict)
            }
            if let items = obj["items"] { strict(items) }
        }
        strict(try JSONSerialization.jsonObject(with: Data(RuleCompilerPrompt.schemaJSON.utf8)))
    }
}

/// R9: the "not merged" filter and the weights string are shared by the compiler prompt and
/// later tasks, so their exact semantics and format are pinned here.
final class TaskKindRoutingTests: XCTestCase {
    private typealias D = RoutingTestData

    func testIsLiveExcludesOnlyMergedKinds() {
        XCTAssertTrue(D.tests.isLive)
        XCTAssertTrue(D.kind("p", [:], status: .proposed).isLive)
        XCTAssertFalse(D.golden.isLive)
    }

    func testWeightsTextIsSortedByIdWithPlainNumbers() {
        XCTAssertEqual(D.tests.weightsText, "agentic-coding 0.4, test-authoring 0.9")
        XCTAssertEqual(D.kind("none", [:]).weightsText, "none")
    }
}
