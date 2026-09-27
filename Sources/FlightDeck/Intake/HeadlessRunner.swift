import Foundation

/// Runs one headless agent turn (`codex exec` / `claude -p`) as built by
/// `HarnessCommand.build`. A protocol so `IntakeService`'s tests can hand back canned harness
/// output without spawning a model.
///
/// Separate from `FlywheelProcessRunner` because a harness turn needs three things that
/// runner deliberately doesn't do: stdout as raw `Data` (codex's JSONL is parsed byte-wise),
/// stderr kept rather than discarded (a harness that dies before its first JSON line says why
/// only there), and environment variables removed (see `HarnessCommand.build`'s claude arm).
protocol HeadlessRunner: Sendable {
    func run(
        _ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
        cwd: URL
    ) async throws -> (stdout: Data, stderr: String, exitCode: Int32)
}

struct SystemHeadlessRunner: HeadlessRunner {
    func run(
        _ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
        cwd: URL
    ) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments
        process.currentDirectoryURL = cwd
        // The login shell's PATH, appended: a Finder-launched app has launchd's bare PATH,
        // which contains neither `~/.local/bin` (codex, claude) nor `/opt/homebrew/bin` — see
        // `LoginShellPath`. `/usr/bin/env` alone would report "no such file" for both.
        var environment = LoginShellPath.repairing(ProcessInfo.processInfo.environment)
        for key in command.unsetEnvironment { environment.removeValue(forKey: key) }
        process.environment = environment
        // Both CLIs look at stdin when it is not a TTY (as extra prompt input); an inherited
        // stdin that never reaches EOF would stall a turn that should need no input at all.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try Task.checkCancellation()
        try process.run()

        // Both pipes drain on their own threads, off the cooperative pool: a triage turn runs
        // for minutes, and either stream filling its 64KB buffer while we block on the other
        // is the classic Foundation.Process deadlock (see `LoginShellPath.defaultRun`).
        let result: (Data, Data, Int32, Bool) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let group = DispatchGroup()
                let out = Buffer(), err = Buffer()
                group.enter()
                DispatchQueue.global().async {
                    out.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.data = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.notify(queue: .global()) {
                    process.waitUntilExit()
                    continuation.resume(returning: (out.data, err.data, process.terminationStatus,
                                                    process.terminationReason == .uncaughtSignal))
                }
            }
        } onCancel: {
            // Closes the child's pipes, so both reads above hit EOF and the continuation
            // resumes — a discarded or retried intake stops its model turn instead of
            // letting it run to completion unobserved.
            process.terminate()
        }

        // Same rule as `SystemFlywheelProcessRunner`: a run we killed is a cancellation, not
        // an exit code the caller should classify.
        if result.3 || Task.isCancelled { throw CancellationError() }
        return (result.0, String(decoding: result.1, as: UTF8.self), result.2)
    }

    private final class Buffer: @unchecked Sendable { var data = Data() }
}
