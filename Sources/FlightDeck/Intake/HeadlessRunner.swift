import Foundation
import IntakeKit

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

/// A thin adapter over `IntakeKit.SystemCommandRunner`, which carries the actual process
/// logic (moved there so the CLI runner process can use it too — see IntakeKit/
/// CommandRunner.swift). All this does is compute the environment `SystemHeadlessRunner`
/// always used and unwrap `CommandResult` back into the tuple shape `HeadlessRunner` promises.
struct SystemHeadlessRunner: HeadlessRunner {
    private let runner = SystemCommandRunner()

    func run(
        _ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
        cwd: URL
    ) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        // The login shell's PATH, appended: a Finder-launched app has launchd's bare PATH,
        // which contains neither `~/.local/bin` (codex, claude) nor `/opt/homebrew/bin` — see
        // `LoginShellPath`. `/usr/bin/env` alone would report "no such file" for both.
        let environment = HarnessCommand.environment(for: command, base: LoginShellPath.repairing(ProcessInfo.processInfo.environment))
        let result = try await runner.run(executable: command.executable, arguments: command.arguments,
                                          cwd: cwd, environment: environment)
        return (result.stdout, result.stderr, result.exitCode)
    }
}
