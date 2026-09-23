import Foundation

/// One-time per-repo setup for a flywheel project: `enable` installs whatever
/// `flywheel-new` omits so an FD-spawned agent's reservation guard actually enforces —
/// the Agent-Mail pre-commit guard, and a beads-sync hook — and `initialize` additionally
/// bootstraps a plain (non-flywheel) repo's `.beads/`, AGENTS.md and `.agent-mail.yaml`
/// before running those same steps. Both are idempotent: they consult
/// `FlywheelProjectProbe` and only run the steps that are still missing. Neither flips
/// any project flag; the store does that separately.
struct FlywheelSetup {
    let runner: FlywheelProcessRunner
    let amPath: String
    let brPath: String

    init(
        runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), amPath: String = "am",
        brPath: String = "br"
    ) {
        self.runner = runner
        self.amPath = amPath
        self.brPath = brPath
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

    /// Turns a plain git repo — one `FlywheelProjectProbe` finds neither `.beads/` nor
    /// `.agent-mail.yaml` in — into a flywheel project, then runs `enable`'s own steps on it.
    /// Composes the same safe primitives `flywheel-new` runs for an existing repo (`br init`,
    /// `br agents --add`, `am projects discovery-init`) rather than shelling out to
    /// `flywheel-new` itself, which also runs `git init` (wrong here — the project already is
    /// a repo), `ntm init` (NTM hooks this app doesn't use) and `cm init --repo` (unrelated
    /// repo memory) — none of which "Setup Flywheel…" asked for. Idempotent the same way
    /// `enable` is: each step is gated on the probe status, so calling this twice (or once on
    /// a repo that already has some of the markers) only runs what's still missing.
    @discardableResult
    func initialize(repo: URL) async throws -> [String] {
        var steps: [String] = []
        let status = FlywheelProjectProbe.status(of: repo)

        if !status.hasBeads {
            let (stdout, exitCode) = try await runner.run(
                brPath, ["init", "--prefix", Self.beadsPrefix(for: repo), "--actor", NSUserName()],
                cwd: repo.path
            )
            guard exitCode == 0 else {
                throw FlywheelError.initializeStep(step: "br init", exitCode: exitCode, output: stdout)
            }
            steps.append("beads workspace (br init)")

            let (agentsOutput, agentsExitCode) = try await runner.run(
                brPath, ["agents", "--add", "--force"], cwd: repo.path
            )
            guard agentsExitCode == 0 else {
                throw FlywheelError.initializeStep(
                    step: "br agents --add", exitCode: agentsExitCode, output: agentsOutput
                )
            }
            steps.append("AGENTS.md (br agents --add)")
        }

        if !status.hasAgentMailMarker {
            let (stdout, exitCode) = try await runner.run(
                amPath, ["projects", "discovery-init", repo.path], cwd: repo.path
            )
            guard exitCode == 0 else {
                throw FlywheelError.initializeStep(
                    step: "am projects discovery-init", exitCode: exitCode, output: stdout
                )
            }
            steps.append("agent-mail marker (am projects discovery-init)")
        }

        steps.append(contentsOf: try await enable(repo: repo))
        return steps
    }

    /// `br init --prefix` wants a short identifier, not a path — mirrors `flywheel-new`'s own
    /// derivation (lowercase, non-alphanumeric collapsed to `-`, capped at 16 chars) so a
    /// project Flight Deck sets up gets the same style of issue ID a manually-run
    /// `flywheel-new` would have given it.
    private static func beadsPrefix(for repo: URL) -> String {
        let lowered = repo.lastPathComponent.lowercased()
        let dashed = lowered.map { $0.isWhitespace ? "-" : String($0) }.joined()
        let slug = String(dashed.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(16))
        return slug.isEmpty ? "proj" : slug
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
