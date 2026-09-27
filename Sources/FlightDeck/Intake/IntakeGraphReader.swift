import Foundation
import IntakeKit

/// Reads the live bead graph for a project: `br list --all --json` (every bead, closed
/// included) plus `br graph --all --json` (dependency edges across every open/blocked
/// component), decoded together by `GraphSnapshot.decode`. Both `Harness` (Task 16, graph
/// snapshot for triage) and `BeadWriter`'s live test use this rather than each hand-rolling
/// the two-call sequence and its envelope shapes.
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
        let (listOut, listCode) = try await runner.run(brPath, ["list", "--all", "--json"], cwd: project)
        guard listCode == 0 else {
            throw CommandFailed(command: "br list", exitCode: listCode, firstLineOfOutput: listOut.firstLine)
        }
        let (graphOut, graphCode) = try await runner.run(brPath, ["graph", "--all", "--json"], cwd: project)
        guard graphCode == 0 else {
            throw CommandFailed(command: "br graph", exitCode: graphCode, firstLineOfOutput: graphOut.firstLine)
        }
        return try GraphSnapshot.decode(list: Data(listOut.utf8), graph: Data(graphOut.utf8))
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
