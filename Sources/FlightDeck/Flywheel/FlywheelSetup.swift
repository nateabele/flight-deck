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

    /// Chains onto whatever `am guard install` may have created/relocated in step 1
    /// rather than clobbering it: appends the `br sync` line to an existing
    /// `pre-commit` hook (guarding against double-append), or creates a fresh one.
    private func installBeadsSyncHook(repo: URL) throws {
        let hookURL = repo.appendingPathComponent(".git/hooks/pre-commit")
        let beadsSyncLines = "br sync --flush-only\ngit add -A .beads\n"

        if let existing = try? String(contentsOf: hookURL, encoding: .utf8) {
            guard !existing.contains("br sync") else { return }
            let updated = existing.hasSuffix("\n") ? existing + beadsSyncLines : existing + "\n" + beadsSyncLines
            try updated.write(to: hookURL, atomically: true, encoding: .utf8)
        } else {
            let contents = "#!/bin/sh\n" + beadsSyncLines
            try contents.write(to: hookURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
        }
    }
}
