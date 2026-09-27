import Foundation
import IntakeKit

/// Reads the live bead graph for a project: `br list --all --json` (every bead, closed
/// included) plus `br graph --all --json` (dependency edges across every open/blocked
/// component), decoded together by `GraphSnapshot.decode`. Both `Harness` (Task 16, graph
/// snapshot for triage) and `BeadWriter`'s live test use this rather than each hand-rolling
/// the two-call sequence and its envelope shapes.
///
/// The actual sequencing now lives in `IntakeKit.GraphReader` (moved there so the CLI runner
/// can use it too); this stays a thin adapter so `IntakeService` and `BeadWriterLiveTests`
/// keep passing this a `FlywheelProcessRunner` — the same fakes and the same real `br`
/// spawning (stdout as `String`, no explicit environment override) as before.
struct IntakeGraphReader {
    let runner: FlywheelProcessRunner
    let brPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), brPath: String = "br") {
        self.runner = runner
        self.brPath = brPath
    }

    struct CommandFailed: Error, Equatable {
        let command: String
        let exitCode: Int32
        let firstLineOfOutput: String
    }

    func read(project: String) async throws -> GraphSnapshot {
        let reader = GraphReader(runner: Adapter(runner: runner), brPath: brPath, environment: [:])
        do {
            return try await reader.read(project: project)
        } catch let failure as GraphReadFailed {
            throw CommandFailed(command: failure.command, exitCode: failure.exitCode,
                                firstLineOfOutput: failure.detail)
        }
    }

    /// Adapts `FlywheelProcessRunner` (stdout as `String`, no explicit environment argument —
    /// `SystemFlywheelProcessRunner` just inherits whatever Flight Deck's own process has) to
    /// `IntakeKit.CommandRunner`, so `GraphReader`'s br-list/br-graph/decode logic runs
    /// unchanged for both this and the CLI runner. `environment` is ignored: the wrapped
    /// runner never took one, so passing it through would change nothing it could act on.
    private struct Adapter: CommandRunner {
        let runner: FlywheelProcessRunner
        func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
                 processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
            let (stdout, exitCode) = try await runner.run(executable, arguments, cwd: cwd.path)
            return CommandResult(stdout: Data(stdout.utf8), stderr: "", exitCode: exitCode)
        }
    }
}

extension String {
    /// `br`'s stdout is often one JSON line, but an error message could still wrap — this
    /// is what both `IntakeGraphReader` and `BeadWriter` use to keep a failure's reported
    /// text to something a log line or `Outcome.error` can hold without dumping a whole
    /// JSON payload.
    var firstLine: String {
        split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
}
