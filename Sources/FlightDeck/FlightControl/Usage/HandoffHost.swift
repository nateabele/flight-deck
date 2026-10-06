import Foundation
import IntakeKit

/// Everything the hand-off driver does to the world, behind one seam so the driver is a pure
/// state machine its tests can run against a fake.
@MainActor
protocol HandoffHost: AnyObject {
    func activity(of session: SessionRef) -> SessionActivity?
    func isRateLimited(_ session: SessionRef) -> Bool
    /// True only when Escape was actually sent; the store refuses an idle composer or a dialog.
    @discardableResult
    func interrupt(_ session: SessionRef) -> Bool
    func confirm(_ request: HandoffRequest) async -> Bool
    func kind(for block: ExecutionBlock, project: URL) -> TaskKind?
    func catalogs() async -> AdapterCatalogs
    /// Nil keeps the planner's list.
    func reservedFiles(of agent: String, project: URL) async -> [String]?
    /// Each returns a warning, or nil when it worked.
    func reassign(task: TaskRef, to agentName: String) async -> String?
    func releaseReservations(of agent: String, project: URL) async -> String?
    /// True only when the exit command was accepted for delivery; false means the old agent is still running.
    func stopAgent(_ session: SessionRef) async -> Bool
    func markHandedOff(_ old: SessionRef, to new: SessionRef)
    func record(_ entry: HandoffLogEntry)
    func notify(title: String, body: String, session: SessionRef)
}

/// One line of the hand-off log (L3-U §5.8): both tabs and both accounts, so "where did my
/// agent go" has an answer after the fact.
struct HandoffLogEntry: Codable, Equatable {
    enum Outcome: String, Codable { case handedOff, spawnFailed, waitingForCapacity, declined, interrupted, stopFailed }
    var at: Date
    var outcome: Outcome
    var task: String
    var oldSession: UUID
    var oldAgent: String
    var newSession: UUID?
    var newAgent: String?
    var fromAccount: String
    var toAccount: String?
    var detail: String?
}

/// `br update --assignee` and `am file_reservations release`, with the warning-not-throw shape
/// `IntakeDelivery` uses: a hand-off that already spawned its new agent must not roll back
/// because a bookkeeping command failed — it is logged and the user is told.
struct BrAmHandoffCommands {
    var runner: FlywheelProcessRunner = SystemFlywheelProcessRunner()
    var brPath = "br"
    var amPath = "am"
    static let actor = "flightdeck-handoff"

    func reassign(task: TaskRef, to agent: String) async -> String? {
        await run(brPath, ["update", task.id, "--assignee", agent, "--actor", Self.actor], cwd: task.project.path,
                  describing: "br update \(task.id) --assignee \(agent)")
    }

    func releaseReservations(of agent: String, project: URL) async -> String? {
        await run(amPath, ["file_reservations", "release", project.path, agent], cwd: project.path,
                  describing: "am file_reservations release for \(agent)")
    }

    private func run(_ executable: String, _ args: [String], cwd: String, describing: String) async -> String? {
        do {
            let (stdout, code) = try await runner.run(executable, args, cwd: cwd)
            guard code != 0 else { return nil }
            let first = stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "(no output)"
            return "\(describing) failed (exit \(code)): \(first)"
        } catch {
            return "\(describing) failed: \(error)"
        }
    }
}

/// The production host. The parts only the swarm knows — how to ask for confirmation, a task's
/// kind for spill, the catalogs, an agent's reservations, marking the old tab "handed off →",
/// where the swarm log lives — are hooks L3-S sets at integration; their defaults are the safe
/// answer (no spill, keep the planner's list, a log file of its own).
@MainActor
final class StoreHandoffHost: HandoffHost {
    private weak var store: SessionStore?
    private let commands: BrAmHandoffCommands
    private let logURL: URL

    var confirmer: ((HandoffRequest) async -> Bool)?
    var kindLookup: (ExecutionBlock, URL) -> TaskKind? = { _, _ in nil }
    var catalogProvider: () async -> AdapterCatalogs = { AdapterCatalogs([]) }
    var reservationLookup: (String, URL) async -> [String]? = { _, _ in nil }
    var onHandedOff: (SessionRef, SessionRef) -> Void = { _, _ in }

    init(store: SessionStore, commands: BrAmHandoffCommands = BrAmHandoffCommands(), logURL: URL = StoreHandoffHost.defaultLogURL) {
        self.store = store; self.commands = commands; self.logURL = logURL
    }

    /// Split by build like every other Flight Deck runtime file, so a debug build's hand-offs
    /// never appear in the real fleet's history.
    nonisolated static var defaultLogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("swarm-log", isDirectory: true)
            .appendingPathComponent("handoffs-\(ClaudePluginLocation.buildTag).jsonl")
    }

    func activity(of session: SessionRef) -> SessionActivity? { store?.statuses[session.id]?.activity }

    func isRateLimited(_ session: SessionRef) -> Bool {
        guard let e = store?.apiErrors[session.id] else { return false }
        return RateLimitClassifier.isRateLimit(status: e.status, kind: e.kind)
    }

    func interrupt(_ session: SessionRef) -> Bool { store?.interruptTurn(session.id) ?? false }

    /// With "Confirm hand-offs" on and nothing installed to ask, the answer is no — never a
    /// silent yes on the user's behalf — and the user is told why their agent stayed put.
    func confirm(_ request: HandoffRequest) async -> Bool {
        guard let confirmer else {
            notify(title: "Hand-off needs a confirmation",
                   body: "Confirm hand-offs is on, but there is nowhere to confirm yet. \(request.oldAgent) stays on its account.",
                   session: request.oldSession)
            return false
        }
        return await confirmer(request)
    }

    func kind(for block: ExecutionBlock, project: URL) -> TaskKind? { kindLookup(block, project) }
    func catalogs() async -> AdapterCatalogs { await catalogProvider() }
    func reservedFiles(of agent: String, project: URL) async -> [String]? { await reservationLookup(agent, project) }
    func reassign(task: TaskRef, to agentName: String) async -> String? { await commands.reassign(task: task, to: agentName) }
    func releaseReservations(of agent: String, project: URL) async -> String? { await commands.releaseReservations(of: agent, project: project) }
    func stopAgent(_ session: SessionRef) async -> Bool {
        // `.sent`/`.queued` are accepted; `.duplicate` means this exact command was already
        // accepted. Every other case typed nothing, and reporting those as delivered would let the
        // driver mark the hand-off done while the old agent keeps burning the over-limit account.
        switch store?.retireAgent(session.id) {
        case .sent?, .queued?, .duplicate?: return true
        default: return false
        }
    }
    func markHandedOff(_ old: SessionRef, to new: SessionRef) { onHandedOff(old, new) }

    func record(_ entry: HandoffLogEntry) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard var line = try? enc.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL)
        }
    }

    func notify(title: String, body: String, session: SessionRef) {
        store?.notifier?.notify(sessionID: session.id, title: title, subtitle: "Flight Control", body: body)
    }
}
