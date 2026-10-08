import Foundation
import IntakeKit

/// Errors `FlywheelCoordinator.boot` can throw.
enum FlywheelError: Error, LocalizedError {
    /// `am macros start-session` exited non-zero. `output` is its stdout, for
    /// surfacing to the user/logs.
    case startSession(exitCode: Int32, output: String)
    /// `am macros start-session` exited zero but its stdout wasn't the JSON shape
    /// `boot` expects.
    case unparseable(String)
    /// `am guard install` (part of `FlywheelSetup.enable`) exited non-zero. `output`
    /// is its stdout, for surfacing to the user/logs.
    case guardInstall(exitCode: Int32, output: String)
    /// One of `FlywheelSetup.initialize`'s bootstrap steps (`br init`, `br agents --add`,
    /// `am projects discovery-init`) exited non-zero before `enable` ever ran. `step` names
    /// which one, so a plain-repo "Set Up Flight Control…" failure reads as specifically as an
    /// already-flywheel project's `enable` failure does.
    case initializeStep(step: String, exitCode: Int32, output: String)

    /// Read by `SessionStore.launchError(from:)`'s generic `default` branch — the one path
    /// that surfaces this to the user — so a boot failure reads as one clean sentence rather
    /// than `String(describing:)`'s `startSession(exitCode: 1, output: "...")`.
    var errorDescription: String? {
        switch self {
        case .startSession(let exitCode, let output):
            "Agent Mail start-session failed (exit \(exitCode)): \(Self.firstLine(of: output))"
        case .unparseable(let output):
            "Agent Mail start-session returned something unparseable: \(Self.firstLine(of: output))"
        case .guardInstall(let exitCode, let output):
            "Agent Mail guard install failed (exit \(exitCode)): \(Self.firstLine(of: output))"
        case .initializeStep(let step, let exitCode, let output):
            "Flight Control setup step `\(step)` failed (exit \(exitCode)): \(Self.firstLine(of: output))"
        }
    }

    /// `output` is a whole process's stdout — often several lines of Agent-Mail's own
    /// logging — and the alert/log line this feeds wants one sentence, not a dump.
    private static func firstLine(of output: String) -> String {
        output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? "(no output)"
    }
}

/// Maps a Flight Deck `AgentID` to the `--program` value Agent-Mail's CLI expects.
enum FlywheelProgram {
    static func rawValue(for agent: AgentID) -> String {
        switch agent {
        case .claude: "claude-code"
        case .codex: "codex-cli"
        // Unverified spellings: Agent-Mail's `--program` is free text, and no grok or gemini
        // agent has been spawned into a real Flight Control swarm yet. The binary name is the
        // least surprising label until a live swarm shows what `am` displays.
        case .grok: "grok"
        case .gemini: "agy"
        }
    }
}

/// Boots an Agent-Mail identity for a spawned agent by shelling out to
/// `am macros start-session`, and hands back the `FlywheelIdentity` later tasks use
/// to build that agent's environment.
struct FlywheelCoordinator {
    let runner: FlywheelProcessRunner
    let amPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), amPath: String = "am") {
        self.runner = runner
        self.amPath = amPath
    }

    /// Minimal decode target for `am macros start-session --json`'s stdout — only the
    /// field this coordinator needs, not a full mirror of Agent-Mail's response shape.
    private struct StartSessionResponse: Decodable {
        struct Agent: Decodable {
            let name: String
        }
        let agent: Agent
    }

    func boot(project: String, program: String, model: String, name: String?) async throws -> FlywheelIdentity {
        let argv = ["macros", "start-session", "--project", project, "--program", program, "--model", model]
            + (name.map { ["-n", $0] } ?? [])
            + ["--json"]

        let (stdout, exitCode) = try await runner.run(amPath, argv, cwd: project)
        guard exitCode == 0 else {
            throw FlywheelError.startSession(exitCode: exitCode, output: stdout)
        }

        guard let data = stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(StartSessionResponse.self, from: data)
        else {
            throw FlywheelError.unparseable(stdout)
        }

        return FlywheelIdentity(agentName: response.agent.name, project: project)
    }
}
