import XCTest
import IntakeKit

// Shared by RoundExecutorTests (IntakeKitTests) and the app-hosted Gemini/round-edit tests; this
// file compiles into both bundles (see project.yml).

/// A `CommandRunner` that answers `br` with a canned graph and every harness child with
/// whatever `script` returns for it — the role is read off the prompt, since that is the one
/// thing every seat's argv carries in both harness shapes.
final class ScriptedHarnessRunner: CommandRunner, @unchecked Sendable {
    struct Call {
        var executable: String, arguments: [String], cwd: URL, environment: [String: String], processGroup: Bool
        var prompt: String {
            if executable == "claude" || executable == "agy", let i = arguments.firstIndex(of: "-p") { return arguments[i + 1] }
            return arguments.last ?? ""
        }
        var model: String? {
            guard let i = arguments.firstIndex(where: { $0 == "-m" || $0 == "--model" }) else { return nil }
            return arguments[i + 1]
        }
        var role: String {
            let p = prompt
            if p.contains("failed validation") { return "correction" }
            if p.contains("You are drafting") { return "drafter" }
            if p.contains("competing models") { return "synthesizer" }
            if p.contains("refinement round") { return "reviewer" }
            if p.contains("Integrate these revisions") { return "integrator" }
            if p.contains("Turn ALL of the plan") { return "encoder" }
            return "polisher"
        }
        /// codex's schema file lives in this call's `runs/<name>/`.
        var runDirectory: URL? {
            guard let i = arguments.firstIndex(of: "--output-schema") else { return nil }
            return URL(fileURLWithPath: arguments[i + 1]).deletingLastPathComponent()
        }
        var isResume: Bool { arguments.contains("resume") || arguments.contains("--resume") || arguments.contains("--conversation") }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    // `bv` calls fall through to the default "polisher" role (their argv has no prompt for
    // `role` to match against), so exclude them here the same way `br` already is — otherwise
    // `calls("polisher").first` would return FD's own bv analytics call instead of the
    // polisher's actual harness turn, since the analytics run before it.
    func calls(_ role: String) -> [Call] { calls.filter { $0.executable != "br" && $0.executable != "bv" && $0.role == role } }

    var graphList = #"{"issues":[{"id":"fd-1","title":"Existing","status":"open","labels":[]}]}"#
    var graphEdges = #"{"components":[{"edges":[]}]}"#
    /// Controls `RoundExecutor.buildShadowAnalytics`'s three `bv` calls: `0` (default) answers
    /// every one with `bvStdout`; any other code simulates a `bv` failure, which the redirect
    /// requires to drop the analytics but still let the round run to completion.
    var bvExitCode: Int32 = 0
    var bvStdout = #"{"ok":true}"#
    var nextPID: Int32 = 4000
    /// What `agy models` (the gemini sign-in preflight) answers. Signed in by default, so a
    /// gemini seat runs; a test sets the signed-out text to exercise the preflight.
    var agyModels = CommandResult(stdout: Data("gemini-3.8-pro\n".utf8), stderr: "", exitCode: 0)
    let script: @Sendable (Call) -> CommandResult
    var onCall: (@Sendable (Call) -> Void)?

    init(_ script: @escaping @Sendable (Call) -> CommandResult) { self.script = script }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                        processGroup: processGroup)
        let pid: Int32 = lock.withLock { _calls.append(call); nextPID += 1; return nextPID }
        if executable == "br" {
            // A polish round's `ShadowGraph.build` (Task 7b wiring) puts `--db <path>` first,
            // ahead of the subcommand — dispatch on `arguments[2]` rather than `arguments.first`
            // for those, and reuse the same `graphList`/`graphEdges` fixtures a test already set
            // for the live graph read: nothing in these tests needs the shadow to diverge from it.
            if arguments.first == "--db" {
                guard arguments.count >= 3 else { return CommandResult(stdout: Data(), stderr: "", exitCode: 127) }
                switch arguments[2] {
                case "list": return CommandResult(stdout: Data(graphList.utf8), stderr: "", exitCode: 0)
                case "graph": return CommandResult(stdout: Data(graphEdges.utf8), stderr: "", exitCode: 0)
                case "create":
                    let title = arguments[arguments.firstIndex(of: "--title")! + 1]
                    return CommandResult(stdout: Data(#"{"id":"shadow-\#(title)"}"#.utf8), stderr: "", exitCode: 0)
                default: return CommandResult(stdout: Data(), stderr: "", exitCode: 0)   // update, dep add
                }
            }
            let out = arguments.first == "list" ? graphList : graphEdges
            return CommandResult(stdout: Data(out.utf8), stderr: "", exitCode: 0)
        }
        if executable == "agy", arguments == ["models"] { return agyModels }
        if executable == "bv" {
            // `RoundExecutor.buildShadowAnalytics` — FD's own `bv --robot-insights/-plan/-priority`
            // runs against the shadow, never the agent's. Scripted the same way `br` is above:
            // the tests never need these to diverge from `bvStdout`/`bvExitCode`.
            return CommandResult(stdout: Data(bvStdout.utf8), stderr: bvExitCode == 0 ? "" : "bv: failed", exitCode: bvExitCode)
        }
        onCall?(call)
        onSpawn?(pid)
        return script(call)
    }
}

// MARK: - AgentID-shaped outputs

func codexOK(_ session: String, _ json: String) -> CommandResult {
    let started = #"{"type":"thread.started","thread_id":"\#(session)"}"#
    let message = try! JSONSerialization.data(withJSONObject: ["type": "item.completed",
                                                               "item": ["type": "agent_message", "text": json]])
    return CommandResult(stdout: Data((started + "\n" + String(decoding: message, as: UTF8.self) + "\n").utf8),
                         stderr: "", exitCode: 0)
}

/// `claude -p --output-format stream-json --verbose`'s shape: an init line, then (after the
/// turn's own events) the final `result` carrying the structured output.
func claudeOK(_ session: String, _ json: String) -> CommandResult {
    let structured = try! JSONSerialization.jsonObject(with: Data(json.utf8))
    let initLine = try! JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "init", "session_id": session])
    let result = try! JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
                                                              "session_id": session, "structured_output": structured])
    return CommandResult(stdout: Data((String(decoding: initLine, as: UTF8.self) + "\n" + String(decoding: result, as: UTF8.self) + "\n").utf8),
                         stderr: "", exitCode: 0)
}

/// `agy --output-format stream-json`'s shape: init, then the final `result` with
/// `structured_output`.
func agyOK(_ session: String, _ json: String) -> CommandResult {
    let structured = try! JSONSerialization.jsonObject(with: Data(json.utf8))
    let initLine = try! JSONSerialization.data(withJSONObject: ["event": "init", "conversation_id": session])
    let result = try! JSONSerialization.data(withJSONObject: ["event": "result", "result": [
        "conversation_id": session, "status": "SUCCESS", "response": json, "structured_output": structured]])
    return CommandResult(stdout: Data((String(decoding: initLine, as: UTF8.self) + "\n" + String(decoding: result, as: UTF8.self) + "\n").utf8),
                         stderr: "", exitCode: 0)
}

/// Answers in whichever shape the call's harness speaks.
func ok(_ call: ScriptedHarnessRunner.Call, _ session: String, _ json: String) -> CommandResult {
    switch call.executable {
    case "claude": claudeOK(session, json)
    case "agy": agyOK(session, json)
    default: codexOK(session, json)
    }
}

func failed(_ stderr: String) -> CommandResult { CommandResult(stdout: Data(), stderr: stderr, exitCode: 1) }

func json<T: Encodable>(_ value: T) -> String { String(decoding: try! IntakeJSON.encoder.encode(value), as: UTF8.self) }
