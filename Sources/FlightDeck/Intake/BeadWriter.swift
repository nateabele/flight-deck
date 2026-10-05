import Foundation
import IntakeKit

/// Applies a released `ApplyPlanner` plan to the real `br` CLI, one `ApplyStep` at a time,
/// in the exact order it was planned (creates, then edges, then edits, then reopens, then
/// held edges — see `ApplyPlanner.plan`). The first failed command or mismatched `recheck`
/// ends the run right there: nothing after it is attempted, so a release either lands in
/// full or stops with a precise account of how far it got.
struct BeadWriter {
    /// `applied` counts `ApplyStep`s, not underlying `br` invocations — a `.reopen` step
    /// that runs `br reopen` then `br comments add` only increments this once, after both
    /// succeed. `error` is non-nil exactly when a step failed or a recheck no longer
    /// matches; when it is, `applied` is how many steps ran *before* the one that failed.
    struct Outcome {
        var applied: Int = 0
        var idMap: [String: String] = [:]
        var error: String?
    }

    /// What one step produced: a minted id to fold into `Outcome.idMap` (only `.create`),
    /// plain success, or a failure message already formatted as `"<step description>: exit
    /// <code>[: <first line of stdout>]"`.
    private enum StepOutcome {
        case created(tempId: String, id: String)
        case ok
        case failed(String)
    }

    let runner: FlywheelProcessRunner
    let brPath: String
    /// `--actor` on every write, so `br`'s audit trail attributes a release to Flight
    /// Deck's intake rather than whichever shell user happened to run it.
    let actor: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), brPath: String = "br", actor: String) {
        self.runner = runner
        self.brPath = brPath
        self.actor = actor
    }

    func apply(_ steps: [ApplyStep], project: String, agentContexts: [String: String] = [:]) async -> Outcome {
        var outcome = Outcome()
        for step in steps {
            switch await run(step, idMap: outcome.idMap, project: project, agentContexts: agentContexts) {
            case .created(let tempId, let id):
                outcome.applied += 1
                outcome.idMap[tempId] = id
            case .ok:
                outcome.applied += 1
            case .failed(let message):
                outcome.error = message
            }
            if outcome.error != nil { break }
        }
        // Not itself a step — a failed release leaves the DB exactly as `br` left it, with
        // nothing new to export, so this only runs after every step above has succeeded.
        if outcome.error == nil {
            _ = try? await runner.run(brPath, ["sync", "--flush-only", "--actor", actor], cwd: project)
        }
        return outcome
    }

    private func run(_ step: ApplyStep, idMap: [String: String], project: String, agentContexts: [String: String]) async -> StepOutcome {
        let description = describe(step)
        switch step {
        case .create(let bead):
            var args = ["create", "--title", bead.title, "-t", bead.type, "-p", String(bead.priority),
                        "--description", bead.description]
            // `--acceptance` here, `--acceptance-criteria` on `.update` below — both spellings
            // verified live against `br 0.6.0 --help` (create's is a documented alias); this
            // is not a mismatch to "fix".
            if let acceptance = bead.acceptance { args += ["--acceptance", acceptance] }
            if !bead.labels.isEmpty { args += ["-l", bead.labels.joined(separator: ",")] }
            // L3-R §4: the routed execution block. A new task has no other `agent_context` to
            // keep, so this is the whole value (`ExecutionBlockCodec.encode(_, into: nil)`).
            if let context = agentContexts[bead.tempId] { args += ["--agent-context", context] }
            args += ["--actor", actor, "--json"]
            switch await exec(args, description: description, project: project) {
            case .failure(let error): return .failed(error.message)
            case .success(let stdout):
                struct Reply: Decodable { let id: String }
                guard let data = stdout.data(using: .utf8),
                      let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                    return .failed("\(description): unexpected output: \(stdout.firstLine)")
                }
                return .created(tempId: bead.tempId, id: reply.id)
            }

        case .depend(let dependent, let dependency, let kind):
            guard let dependentID = resolve(dependent, idMap: idMap) else {
                return .failed("\(description): unresolved temp id \(dependent.wireValue)")
            }
            guard let dependencyID = resolve(dependency, idMap: idMap) else {
                return .failed("\(description): unresolved temp id \(dependency.wireValue)")
            }
            let args = ["dep", "add", dependentID, dependencyID, "--type", kind.rawValue, "--actor", actor]
            switch await exec(args, description: description, project: project) {
            case .failure(let error): return .failed(error.message)
            case .success: return .ok
            }

        case .update(let id, let set):
            var args = ["update", id]
            if let title = set.title { args += ["--title", title] }
            if let value = set.description { args += ["--description", value] }
            if let acceptance = set.acceptance { args += ["--acceptance-criteria", acceptance] }
            if let priority = set.priority { args += ["-p", String(priority)] }
            args += ["--actor", actor]
            switch await exec(args, description: description, project: project) {
            case .failure(let error): return .failed(error.message)
            case .success: return .ok
            }

        case .reopen(let id, let reason):
            switch await exec(["reopen", id, "--actor", actor], description: description, project: project) {
            case .failure(let error): return .failed(error.message)
            case .success: break
            }
            let comment = "Reopened by Flight Deck intake: \(reason)"
            switch await exec(["comments", "add", id, comment, "--actor", actor], description: description, project: project) {
            case .failure(let error): return .failed(error.message)
            case .success: return .ok
            }

        case .recheck(let id, let pre):
            // Read-only, so no `--actor` — matches `IntakeGraphReader`, which never writes.
            switch await exec(["show", id, "--json"], description: description, project: project) {
            case .failure(let error): return .failed(error.message)
            case .success(let stdout):
                struct Reply: Decodable { let id: String; let status: String; let assignee: String? }
                guard let data = stdout.data(using: .utf8),
                      let replies = try? JSONDecoder().decode([Reply].self, from: data),
                      let match = replies.first else {
                    return .failed("\(description): task not found: \(stdout.firstLine)")
                }
                if let pre, Precondition(status: match.status, assignee: match.assignee) != pre {
                    return .failed("\(description): precondition mismatch (status=\(match.status), assignee=\(match.assignee ?? "nil"))")
                }
                return .ok
            }
        }
    }

    private func resolve(_ ref: BeadRef, idMap: [String: String]) -> String? {
        switch ref {
        case .existing(let id): id
        case .new(let tempId): idMap[tempId]
        }
    }

    /// Short, stable text naming the step — used only to prefix an error, e.g. `"dep add
    /// new:n1 b1: exit 1: database is locked"`.
    private func describe(_ step: ApplyStep) -> String {
        switch step {
        case .create(let bead): "create \(bead.tempId)"
        case .depend(let dependent, let dependency, _): "dep add \(dependent.wireValue) \(dependency.wireValue)"
        case .update(let id, _): "update \(id)"
        case .reopen(let id, _): "reopen \(id)"
        case .recheck(let id, _): "recheck \(id)"
        }
    }

    /// `String` isn't `Error`, so `exec`'s `Result` needs a wrapper — the message itself is
    /// the whole point, already formatted as `"<description>: exit <code>[: <first line of
    /// stdout>]"`.
    private struct ExecFailure: Error { let message: String }

    /// Runs one `br` command, folding a non-zero exit (or a runner that couldn't even
    /// start the process) into `Result.failure`. The exit code is always in the message —
    /// `FlywheelProcessRunner` discards stderr, so a `br` failure that writes only there
    /// (or nothing at all) would otherwise report just `"<description>: "`, naming the step
    /// but nothing about what went wrong. The first line of stdout, when there is one, is
    /// appended after it.
    private func exec(_ args: [String], description: String, project: String) async -> Result<String, ExecFailure> {
        guard let (stdout, exitCode) = try? await runner.run(brPath, args, cwd: project) else {
            return .failure(ExecFailure(message: "\(description): process could not be started"))
        }
        guard exitCode == 0 else {
            let firstLine = stdout.firstLine
            let detail = firstLine.isEmpty ? "" : ": \(firstLine)"
            return .failure(ExecFailure(message: "\(description): exit \(exitCode)\(detail)"))
        }
        return .success(stdout)
    }
}

/// What `writeBlock` did to one task.
enum BlockWriteOutcome: Equatable, Sendable {
    case written
    case skippedPinned
    case failed(String)
}

/// Writes one task's execution block after a re-route (spec L3-R §5: "when a kind is merged or
/// re-weighted"). A protocol so `RoutingService`'s tests never run `br`.
protocol BlockWriting: Sendable {
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome
}

extension BeadWriter: BlockWriting {
    /// Reads the task's `agent_context`, replaces only `flight_deck.execution`, writes the whole
    /// value back. Never over a pinned block, a newer block, an invalid block or a context that
    /// is not a JSON object: each of those belongs to someone else, and is reported instead.
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome {
        let description = "route \(id)"
        let existing: String?
        switch await exec(["show", id, "--json"], description: description, project: project) {
        case .failure(let error):
            return .failed(error.message)
        case .success(let stdout):
            guard let data = stdout.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else {
                return .failed("\(description): task not found: \(stdout.firstLine)")
            }
            existing = row["agent_context"] as? String
        }
        switch ExecutionBlockCodec.decode(agentContext: existing) {
        case .success(let old?) where old.pinned: return .skippedPinned
        case .failure(let error): return .failed("\(description): \(error.message)")
        default: break
        }
        let merged: String
        do { merged = try ExecutionBlockCodec.encode(block, into: existing) }
        catch let error as ExecutionBlockError { return .failed("\(description): \(error.message)") }
        catch { return .failed("\(description): \(error)") }
        var args = ["update", id, "--agent-context", merged]
        // br 0.6.0 refuses a write that keeps less than half the old length (exit 4) unless
        // forced — a shorter reason would otherwise make the re-route fail. Only then: `--force`
        // also bypasses br's blocked-task guard, which this write has no business overriding.
        if Self.shrinksBelowHalf(old: existing, new: merged) { args.append("--force") }
        args += ["--actor", actor]
        switch await exec(args, description: description, project: project) {
        case .failure(let error): return .failed(error.message)
        case .success: return .written
        }
    }

    /// Both measures, because br counts characters and an emoji-heavy reason makes the two disagree.
    static func shrinksBelowHalf(old: String?, new: String) -> Bool {
        guard let old, !old.isEmpty else { return false }
        return new.count * 2 < old.count || new.utf8.count * 2 < old.utf8.count
    }
}
