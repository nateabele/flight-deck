import Foundation

/// How `FlywheelCoordinator` invokes external commands (`am`, chiefly). A protocol so
/// tests can substitute a fake that records argv and returns canned output instead of
/// actually spawning `am`.
protocol FlywheelProcessRunner: Sendable {
    func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32)
}

/// Spawns real processes via `Foundation.Process`, going through `/usr/bin/env` so a
/// bare executable name (e.g. `"am"`) resolves on `PATH` the same way it would in a
/// shell, without this type having to duplicate `LoginShellPath`'s PATH-repair logic.
struct SystemFlywheelProcessRunner: FlywheelProcessRunner {
    func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // An undrained stderr pipe is the classic Foundation.Process deadlock shape —
        // see `LoginShellPath.defaultRun` — even though this call only needs stdout.
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Read before waiting: a child that writes more than the pipe buffer holds
        // (64KB on macOS) blocks on write() until someone drains it, so waiting first
        // would deadlock. `LoginShellPath.defaultRun` documents the same ordering.
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: data, encoding: .utf8) ?? ""
        return (stdout, process.terminationStatus)
    }
}
