import Foundation
import IntakeKit

struct OpenTaskReadError: Error, Equatable, Sendable {
    let message: String
}

/// Open tasks with their `agent_context` — what a kind change re-routes and what the Task kinds
/// pane counts. A protocol so `RoutingService`'s tests never run `br`.
protocol OpenTaskReading: Sendable {
    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError>
}

/// `br list --status open --json`. Never `br ready`: it does not carry `agent_context`
/// (L3-0 §4, probed on br 0.6.0).
struct BrOpenTaskReader: OpenTaskReading {
    let runner: FlywheelProcessRunner
    let brPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), brPath: String = "br") {
        self.runner = runner
        self.brPath = brPath
    }

    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> {
        guard let (stdout, code) = try? await runner.run(brPath, ["list", "--status", "open", "--json"], cwd: project) else {
            return .failure(OpenTaskReadError(message: "br could not be started"))
        }
        guard code == 0 else { return .failure(OpenTaskReadError(message: "br list exited \(code): \(stdout.firstLine)")) }
        do { return .success(try TaskContextRow.parse(brList: Data(stdout.utf8))) }
        catch { return .failure(OpenTaskReadError(message: "br list printed JSON Flight Deck cannot read")) }
    }
}
