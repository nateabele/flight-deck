import Foundation

/// One-time per-repo setup for a flywheel project: installs whatever `flywheel-new`
/// omits so an FD-spawned agent's reservation guard actually enforces — the
/// Agent-Mail pre-commit guard, and a beads-sync hook. Idempotent: consults
/// `FlywheelProjectProbe` and only runs the steps that are still missing. Does not
/// flip any project flag; the store does that separately.
struct FlywheelSetup {
    let runner: FlywheelProcessRunner
    let amPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), amPath: String = "am") {
        self.runner = runner
        self.amPath = amPath
    }

    /// Runs only the missing steps (idempotent via `FlywheelProjectProbe`). Returns the
    /// human-readable list of steps actually performed (for the confirm UI / logging).
    @discardableResult
    func enable(repo: URL) async throws -> [String] {
        var steps: [String] = []
        let status = FlywheelProjectProbe.status(of: repo)

        if !status.guardInstalled {
            let (stdout, exitCode) = try await runner.run(amPath, ["guard", "install", repo.path, repo.path], cwd: repo.path)
            guard exitCode == 0 else {
                throw FlywheelError.guardInstall(exitCode: exitCode, output: stdout)
            }
            steps.append("am guard install")
        }

        if !status.beadsSyncHooksInstalled {
            try installBeadsSyncHook(repo: repo)
            steps.append("beads sync hook")
        }

        return steps
    }

    /// Installs beads-sync as its own script under `hooks.d/pre-commit/` — the directory
    /// `am guard install`'s Python chain-runner dispatches every executable in — rather
    /// than appending shell lines to the `pre-commit` file itself. That file is the
    /// chain-runner (`#!/usr/bin/env python3 ... sys.exit(first_failure)`); appending shell
    /// to it is a `SyntaxError` that fails every commit. Never touch `pre-commit`.
    private func installBeadsSyncHook(repo: URL) throws {
        let hooksDDir = repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit")
        try FileManager.default.createDirectory(at: hooksDDir, withIntermediateDirectories: true)

        let scriptURL = hooksDDir.appendingPathComponent("60-beads-sync.sh")
        let contents = "#!/bin/sh\nbr sync --flush-only\ngit add -A .beads\n"
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
