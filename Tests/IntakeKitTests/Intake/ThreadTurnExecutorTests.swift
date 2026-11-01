import XCTest
import IntakeKit

/// `ThreadTurnExecutor`: one thread turn through the agent's own CLI, with no real CLI spawned —
/// a scripted `CommandRunner` hands back a recorded-shape stream.
final class ThreadTurnExecutorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-thread-exec-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func request(resume: String? = nil) -> ThreadTurnRequest {
        ThreadTurnRequest(thread: ThreadID(), agent: .claude, model: "m", effort: "high",
                          project: URL(fileURLWithPath: "/repo"), readable: [dir.appendingPathComponent("workspace")],
                          prompt: "P", resumeSessionID: resume, runDirectory: dir.appendingPathComponent("runs/1-0"),
                          activityURL: dir.appendingPathComponent("activity.json"))
    }

    private static func stream(_ structured: String) -> Data {
        Data("""
        {"type":"system","subtype":"init","session_id":"S1"}
        {"type":"result","subtype":"success","is_error":false,"session_id":"S1","structured_output":\(structured)}

        """.utf8)
    }

    func testARunGetsThreadReadAccessInTheRepoAndDecodesTheAnswer() async throws {
        let answer = #"{"reply":"Because [cite:cp1.d0].","decision":null,"actions":null}"#
        let runner = Spy(CommandResult(stdout: Self.stream(answer), stderr: "", exitCode: 0))
        let outcome = try await ThreadTurnExecutor(runner: runner, environment: ["PATH": "/usr/bin"],
                                                   userHome: URL(fileURLWithPath: "/nonexistent-fd-home"))
            .run(request(resume: "S0"))

        XCTAssertEqual(outcome, .answered(ThreadAnswer(reply: "Because [cite:cp1.d0]."), sessionID: "S1"))
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, "claude")
        XCTAssertEqual(call.cwd.path, "/repo")
        XCTAssertTrue(call.processGroup)
        XCTAssertTrue(call.arguments.contains(HeadlessCommand.claudeThreadReadTools), "threadRead access")
        XCTAssertEqual(call.arguments.last.map { _ in call.arguments.firstIndex(of: "--resume").map { call.arguments[$0 + 1] } },
                       "S0")
        let schema = try String(contentsOf: dir.appendingPathComponent("runs/1-0/schema.json"), encoding: .utf8)
        XCTAssertEqual(schema, ThreadActions.schemaJSON)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("runs/1-0/stdout")), Self.stream(answer),
                       "the stream is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("activity.json").path))
    }

    /// I4: the agent's CLI never acts as anyone on the control socket. With no token a caller
    /// is the unscoped human, so the agent gets a value the socket refuses as invalid, and never
    /// the runner's own token, which the runner keeps for itself.
    func testTheAgentCarriesAnInvalidCallerNeverTheRunnerToken() async throws {
        let runnerToken = "intake-runner:\(UUID().uuidString).abc123"
        let runner = Spy(CommandResult(stdout: Self.stream(#"{"reply":"x","decision":null,"actions":null}"#), stderr: "", exitCode: 0))
        _ = try await ThreadTurnExecutor(runner: runner, environment: ["PATH": "/usr/bin", "FLIGHT_DECK_CALLER": runnerToken],
                                         userHome: URL(fileURLWithPath: "/nonexistent-fd-home")).run(request())
        let env = try XCTUnwrap(runner.calls.first?.environment)
        XCTAssertEqual(env["FLIGHT_DECK_CALLER"], ThreadTurnExecutor.agentCaller)
        XCTAssertEqual(ThreadTurnExecutor.agentCaller, "thread-agent:none")
        XCTAssertFalse(env.values.contains(runnerToken), "the runner token reaches no agent")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    /// I3, end to end: an OpenCode turn's config scopes reads outside the repo to its workspace.
    func testAnOpenCodeTurnReadsOutsideTheRepoOnlyInItsWorkspace() async throws {
        let runner = Spy(CommandResult(stdout: Data(), stderr: "", exitCode: 1))
        var r = request()
        r.agent = .opencode
        _ = try await ThreadTurnExecutor(runner: runner, environment: [:], userHome: URL(fileURLWithPath: "/nonexistent-fd-home"))
            .run(r)
        let config = try XCTUnwrap(runner.calls.first?.environment["OPENCODE_CONFIG_CONTENT"])
        let escaped = r.readable[0].path.replacingOccurrences(of: "/", with: "\\/")
        XCTAssertTrue(config.contains(#""external_directory":{"*":"deny",""# + escaped + #"\/*":"allow"}"#), config)
    }

    /// An answer that isn't a thread answer is the agent's to fix: malformed, with the reason
    /// and the session to resume.
    func testAnAnswerThatDoesNotDecodeIsMalformed() {
        let outcome = ThreadTurnExecutor.outcome(agent: .claude, result: CommandResult(
            stdout: Self.stream(#"{"reply":"x","decision":"","actions":[{"op":"makeVisual"}]}"#), stderr: "", exitCode: 0))
        guard case .malformed(let why, let session) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.hasPrefix("not a thread answer"), why)
        XCTAssertEqual(session, "S1")
    }

    /// A harness failure is not retried: there is no answer to fix.
    func testANonZeroExitFails() {
        let outcome = ThreadTurnExecutor.outcome(agent: .claude, result: CommandResult(stdout: Data(), stderr: "boom", exitCode: 1))
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
    }

    /// A thread prompt carries the vocabulary rule every agent prompt carries, and never the
    /// old word for a task.
    func testThreadPromptsCarryTheVocabularyRule() throws {
        let root = dir.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = TapeStore(intakeDirectory: root)
        var tape = Tape()
        try store.writeCheckpoint(Checkpoint(id: 1, stage: .refine, round: 1, major: false, createdAt: Date()),
                                  files: ["plan.md": Data("# Plan\n\n## A\nOne.\n".utf8)], into: &tape)
        let workspace = try ThreadWorkspace.build(in: dir.appendingPathComponent("workspace"), anchor: .wholePlan,
                                                  checkpoint: 1, plan: "# Plan\n\n## A\nOne.\n", tape: tape, store: store,
                                                  intake: nil)
        let record = ThreadRecord(id: ThreadID(), title: "t", anchor: .wholePlan, agent: .grok, model: "m", effort: "",
                                  followsCheckpoint: 1, createdAt: Date())
        let prompt = ThreadPrompts.turn(record: record, turn: ThreadTurn(seq: 1, messageID: "m", you: "Hi", checkpoint: 1,
                                                                        startedAt: Date()),
                                        earlier: [], workspace: workspace, moved: false, diffs: [])
        XCTAssertTrue(prompt.contains(AgentVocabulary.rule))
        XCTAssertFalse(prompt.lowercased().contains("bead"))
        XCTAssertTrue(prompt.contains("you have no shell in this thread"), "grok reads files only")
        XCTAssertFalse(ThreadPrompts.retry(["x"]).lowercased().contains("bead"))
    }
}

private final class Spy: CommandRunner, @unchecked Sendable {
    struct Call { var executable: String; var arguments: [String]; var cwd: URL; var processGroup: Bool
        var environment: [String: String] = [:] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    let result: CommandResult
    init(_ result: CommandResult) { self.result = result }
    var calls: [Call] { lock.withLock { _calls } }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        lock.withLock { _calls.append(Call(executable: executable, arguments: arguments, cwd: cwd, processGroup: processGroup,
                                           environment: environment)) }
        return result
    }
}
