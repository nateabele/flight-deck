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
            steps.append("task sync hook")
        }

        return steps
    }

    /// Turns a plain git repo — one `FlywheelProjectProbe` finds neither `.beads/` nor
    /// `.agent-mail.yaml` in — into a flywheel project, then runs `enable`'s own steps on it.
    /// Composes the same safe primitives `flywheel-new` runs for an existing repo (`br init`,
    /// `br agents --add`, `am projects discovery-init`) rather than shelling out to
    /// `flywheel-new` itself, which also runs `git init` (wrong here — the project already is
    /// a repo), `ntm init` (NTM hooks this app doesn't use) and `cm init --repo` (unrelated
    /// repo memory) — none of which "Set Up Flight Control…" asked for. Idempotent the same way
    /// `enable` is, but NOT on one shared gate: `br init` is gated on `status.hasBeads`, `am
    /// projects discovery-init` on `status.hasAgentMailMarker`, and `br agents --add` on its
    /// OWN marker (`hasAgentsSection`, below) rather than reusing `hasBeads`. Sharing `hasBeads`
    /// used to mean a `br init` that succeeded followed by a `br agents --add` that failed left
    /// `.beads/` on disk, so a re-run saw `hasBeads == true` and skipped the agents step
    /// forever — `AGENTS.md` never got its section. Each step is now independently gated, so
    /// calling this twice (or once on a repo missing only some of the markers) runs exactly
    /// what is still missing.
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
            steps.append("task workspace (br init)")
        }

        if !Self.hasAgentsSection(repo: repo) {
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

    /// The fence `br agents --add` wraps its appended section in. `FlywheelProjectProbe` has
    /// no signal for it — that probe only reads git hooks and the two bootstrap markers — so
    /// `hasAgentsSection` checks directly rather than growing `FlywheelStatus` for one caller.
    private static let agentsSectionMarker = "<!-- br-agent-instructions-v1 -->"

    /// Whether `AGENTS.md` already carries `br agents --add`'s fenced section — see the gate
    /// on `initialize`'s `br agents --add` step for why this is checked on its own rather than
    /// folded into `status.hasBeads`. `br agents --add --force` is non-destructive (it backs up
    /// the file to `AGENTS.md.bak` and appends inside the fence, never overwriting
    /// hand-authored content) and idempotently re-fences on every run, so calling it again when
    /// the fence is already present would be harmless — this check exists to make a *missing*
    /// section resumable, not to avoid a redundant call.
    private static func hasAgentsSection(repo: URL) -> Bool {
        let url = repo.appendingPathComponent("AGENTS.md")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains(agentsSectionMarker)
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
