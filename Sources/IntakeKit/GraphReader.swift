import Foundation

/// A `br list`/`br graph` call that exited non-zero. `detail` is the first line of that
/// call's stdout — `br`'s own error text, not a stack trace — kept short enough for a log
/// line or `Outcome.error` to hold without dumping a whole JSON payload.
public struct GraphReadFailed: Error, Equatable, Sendable {
    public let command: String
    public let exitCode: Int32
    public let detail: String
    public init(command: String, exitCode: Int32, detail: String) {
        self.command = command; self.exitCode = exitCode; self.detail = detail
    }
}

/// Reads the live bead graph for a project: `br list --all --json` (every bead, closed
/// included) plus `br graph --all --json` (dependency edges across every open/blocked
/// component), decoded together by `GraphSnapshot.decode`. The app's `IntakeGraphReader`
/// and the CLI runner (Task 2) both delegate here rather than each hand-rolling the
/// two-call sequence and its envelope shapes.
public struct GraphReader: Sendable {
    private let runner: CommandRunner
    private let brPath: String
    private let environment: [String: String]

    public init(runner: CommandRunner, brPath: String = "br", environment: [String: String]) {
        self.runner = runner
        self.brPath = brPath
        self.environment = environment
    }

    public func read(project: String) async throws -> GraphSnapshot {
        let cwd = URL(fileURLWithPath: project, isDirectory: true)
        let list = try await run(["list", "--all", "--json"], cwd: cwd, label: "br list")
        let graph = try await run(["graph", "--all", "--json"], cwd: cwd, label: "br graph")
        return try GraphSnapshot.decode(list: list, graph: graph)
    }

    private func run(_ arguments: [String], cwd: URL, label: String) async throws -> Data {
        let result = try await runner.run(executable: brPath, arguments: arguments, cwd: cwd,
                                          environment: environment)
        guard result.exitCode == 0 else {
            throw GraphReadFailed(command: label, exitCode: result.exitCode,
                                  detail: Self.firstLine(of: result.stdout))
        }
        return result.stdout
    }

    private static func firstLine(of data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        return s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
}
