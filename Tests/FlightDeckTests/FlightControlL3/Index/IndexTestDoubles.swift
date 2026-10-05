import Foundation
import IntakeKit
@testable import FlightDeck

/// A `HeadlessRunner` that answers per source. The source is recognised by the `(id <source>)`
/// line the extraction prompt carries; an unscripted source exits 1, which the runner must
/// treat as a failed source, not a crash. Implements only `run(_:cwd:)`, so the streaming
/// overload falls back to the protocol extension and delivers stdout once, at exit — the path
/// on which the token cap is enforced after the fact.
final class ScriptedIndexHeadless: HeadlessRunner, @unchecked Sendable {
    private let lock = NSLock()
    var answers: [String: (stdout: Data, stderr: String, exitCode: Int32)] = [:]
    private(set) var ran: [String] = []
    private(set) var prompts: [String] = []
    private(set) var commands: [[String]] = []

    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        let prompt = command.arguments.count > 1 ? command.arguments[1] : ""
        return lock.withLock {
            commands.append(command.arguments)
            prompts.append(prompt)
            guard let id = answers.keys.sorted().first(where: { prompt.contains("(id \($0))") }),
                  let answer = answers[id] else {
                return (Data(), "no script for this source", 1)
            }
            ran.append(id)
            return answer
        }
    }
}

/// A headless runner that streams, like the real one: it feeds `onStdout` a stream-json
/// `assistant` line whose usage is `tokens`, then waits (up to 5 s) for its task to be cancelled — the
/// way the real process runs on until the runner SIGTERMs it — and throws `CancellationError`.
/// Exists because `ScriptedIndexHeadless` only delivers stdout at exit, so it cannot exercise
/// the MID-RUN cap stop; a runner that never stopped the process leaves `cancelled` false.
final class StreamingIndexHeadless: HeadlessRunner, @unchecked Sendable {
    private let lock = NSLock()
    let tokens: Int
    private var wasCancelled = false
    private(set) var ran: [String] = []
    /// True only if the run ended because its task was cancelled — what tells a mid-stream stop
    /// apart from the runner's after-exit cap check, which yields the same outcome.
    var cancelled: Bool { lock.withLock { wasCancelled } }
    init(tokens: Int) { self.tokens = tokens }

    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        try await run(command, cwd: cwd, onStdout: nil)
    }

    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]), cwd: URL,
             onStdout: (@Sendable (Data) -> Void)?) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        let prompt = command.arguments.count > 1 ? command.arguments[1] : ""
        lock.withLock { ran.append(prompt) }
        let line = #"{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"# + "\n"
        onStdout?(Data(line.utf8))
        // Bounded so a regressed stop fails the test instead of hanging the suite.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Task.isCancelled {
                lock.withLock { wasCancelled = true }
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return (Data(), "timed out waiting for cancel", 1)
    }
}
