import Foundation
import IntakeKit

struct SwarmBackendError: Error, Equatable { let message: String }

/// Everything the swarm asks of br and am. A protocol so the controller is tested against a
/// scripted fake (`FakeSwarmBackend`) and the argv is tested once, here, against `MultiRunner`.
@MainActor
protocol SwarmBackend: AnyObject {
    func readyTasks(project: URL) async -> Result<[ReadyTask], SwarmBackendError>
    func taskDetail(_ id: String, project: URL) async -> TaskDetail?
    func status(_ id: String, project: URL) async -> TaskStatusReading?
    func claim(_ id: String, actor: String, project: URL) async -> ClaimOutcome
    func returnToOpen(_ id: String, project: URL) async -> Bool
    func writeBlock(_ block: ExecutionBlock, task: String, existingContext: String?, project: URL) async -> Bool
    func releaseReservations(agent: String, project: URL) async -> Bool
}

/// `br`/`am` through the same `FlywheelProcessRunner` seam Observe and release use. Every call
/// runs with `cwd` = the project, which is how br finds `.beads` and how am scopes nothing by
/// accident (the project path is also passed explicitly to `am`, which is one global store).
@MainActor
final class BrSwarmBackend: SwarmBackend {
    private let runner: FlywheelProcessRunner
    private let brPath: String
    private let amPath: String

    init(runner: FlywheelProcessRunner, brPath: String = "br", amPath: String = "am") {
        self.runner = runner; self.brPath = brPath; self.amPath = amPath
    }

    private func run(_ exe: String, _ args: [String], _ project: URL) async -> (stdout: String, exitCode: Int32)? {
        try? await runner.run(exe, args, cwd: project.path)
    }

    func readyTasks(project: URL) async -> Result<[ReadyTask], SwarmBackendError> {
        guard let ready = await run(brPath, ["ready", "--json"], project), ready.exitCode == 0,
              let rows = SwarmTaskDecoding.readyRows(Data(ready.stdout.utf8)) else {
            return .failure(SwarmBackendError(message: "br ready failed"))
        }
        // A scheduler that fails or changes schema degrades to priority order rather than
        // stopping the swarm: the ready set is what must be right, the order is a preference.
        let scheduler = await run(brPath, ["scheduler", "--format", "json"], project)
        let ranks = scheduler.flatMap { $0.exitCode == 0 ? SwarmTaskDecoding.schedulerRanks(Data($0.stdout.utf8)) : nil } ?? [:]
        // `br ready` does not carry `agent_context` (probed, br 0.6.0), so blocks come from here.
        let list = await run(brPath, ["list", "--status", "open", "--json"], project)
        let contexts = list.flatMap { $0.exitCode == 0 ? SwarmTaskDecoding.listContexts(Data($0.stdout.utf8)) : nil } ?? [:]
        return .success(SwarmTaskDecoding.join(ready: rows, ranks: ranks, contexts: contexts))
    }

    func taskDetail(_ id: String, project: URL) async -> TaskDetail? {
        guard let out = await run(brPath, ["show", id, "--json"], project), out.exitCode == 0 else { return nil }
        return SwarmTaskDecoding.detail(Data(out.stdout.utf8))
    }

    func status(_ id: String, project: URL) async -> TaskStatusReading? {
        await taskDetail(id, project: project).map { TaskStatusReading(status: $0.status, assignee: $0.assignee) }
    }

    func claim(_ id: String, actor: String, project: URL) async -> ClaimOutcome {
        guard let out = await run(brPath, ["update", id, "--claim", "--actor", actor, "--json"], project) else {
            return .failed("br did not run")
        }
        return SwarmTaskDecoding.claimOutcome(exitCode: out.exitCode, stdout: out.stdout)
    }

    /// The same argv release delivery's reclaim uses (`IntakeDelivery.swift:96`); `--assignee ""`
    /// was probed to clear the assignee to null.
    func returnToOpen(_ id: String, project: URL) async -> Bool {
        await run(brPath, ["update", id, "--status", "open", "--assignee", "", "--actor", "flight-deck"], project)?.exitCode == 0
    }

    /// Read-merge-write: the block is merged into whatever `agent_context` already holds, so br's
    /// own governing instructions in the same field survive an override.
    func writeBlock(_ block: ExecutionBlock, task: String, existingContext: String?, project: URL) async -> Bool {
        guard let json = try? ExecutionBlockCodec.encode(block, into: existingContext) else { return false }
        return await run(brPath, ["update", task, "--agent-context", json], project)?.exitCode == 0
    }

    func releaseReservations(agent: String, project: URL) async -> Bool {
        await run(amPath, ["file_reservations", "release", project.path, agent], project)?.exitCode == 0
    }
}
