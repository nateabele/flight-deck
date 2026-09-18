import Foundation

/// Errors `FlywheelCoordinator.boot` can throw.
enum FlywheelError: Error {
    /// `am macros start-session` exited non-zero. `output` is its stdout, for
    /// surfacing to the user/logs.
    case startSession(exitCode: Int32, output: String)
    /// `am macros start-session` exited zero but its stdout wasn't the JSON shape
    /// `boot` expects.
    case unparseable(String)
}

/// Maps a Flight Deck `AgentID` to the `--program` value Agent-Mail's CLI expects.
enum FlywheelProgram {
    static func rawValue(for agent: AgentID) -> String {
        switch agent {
        case .claude: "claude-code"
        case .codex: "codex-cli"
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
