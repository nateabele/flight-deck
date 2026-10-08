import Foundation
import IntakeKit

/// Everything one refresh needs, captured on the main actor and handed off whole, so the run
/// never reads the service's state while the user edits it in Settings.
struct IndexRefreshPlan: Sendable {
    var sources: [IndexSource]
    var aliases: AliasTable
    var catalogs: AdapterCatalogs
    var agent: IndexAgentSettings
    var previous: IndexSnapshot?
    var workDirectory: URL
}

struct IndexRefreshOutcome: Sendable {
    var snapshot: IndexSnapshot
    var proposals: [AliasEntry]
    var log: [String]
    var tokensUsed: Int
}

enum IndexRefreshError: Error, Equatable {
    case overCap(used: Int)
    case harness(String)
    case noValidRows(Int)
}

/// Counts one run's tokens from its stream as it arrives — `ActivityParser` already folds
/// claude's per-message usage without double counting — and fires once when the run's budget is
/// crossed, so the process can be stopped mid-run rather than allowed to finish over the cap.
final class IndexTokenMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: ActivityParser
    private let budget: Int
    private var over = false
    private var onOver: (() -> Void)?

    init(cwd: URL, budget: Int) {
        parser = ActivityParser(agent: .claude, project: cwd, now: { Date() })
        self.budget = budget
    }

    private static func total(_ a: SeatActivity) -> Int { (a.inputTokens ?? 0) + (a.outputTokens ?? 0) }

    var total: Int { lock.withLock { Self.total(parser.activity) } }
    var isOver: Bool { lock.withLock { over } }

    func feed(_ chunk: Data) {
        let fire: (() -> Void)? = lock.withLock {
            parser.feed(chunk)
            guard !over, Self.total(parser.activity) > budget else { return nil }
            over = true
            return onOver
        }
        fire?()
    }

    /// Registers the stop action; runs it at once if the budget was already crossed — a fast
    /// run can cross it before the caller gets to register.
    func whenOver(_ action: @escaping () -> Void) {
        let alreadyOver: Bool = lock.withLock {
            onOver = action
            return over
        }
        if alreadyOver { action() }
    }
}

/// The refresh (spec §4): one headless claude run per enabled source, in registry order, each
/// answer validated before anything is scored. Runs sequentially on purpose — the token cap is
/// a running total, and parallel runs could each start under it and finish far over it.
///
/// A source that fails, is cut off by the cap, or returns no valid row keeps its PREVIOUS rows,
/// marked stale with the reason: one bad week must not erase a model's data.
struct IndexRefreshRunner: Sendable {
    let headless: HeadlessRunner
    let now: @Sendable () -> Date

    init(headless: HeadlessRunner = SystemHeadlessRunner(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.headless = headless
        self.now = now
    }

    func refresh(_ plan: IndexRefreshPlan) async -> IndexRefreshOutcome {
        var used = 0
        var results: [SourceResult] = []
        var log: [String] = []
        try? FileManager.default.createDirectory(at: plan.workDirectory, withIntermediateDirectories: true)

        for source in plan.sources where source.enabled {
            let prior = plan.previous?.sources.first { $0.sourceID == source.id }
            guard used < plan.agent.tokenCap else {
                results.append(Self.stale(source, prior, "token cap reached"))
                log.append("\(source.id): skipped, token cap reached (\(used) of \(plan.agent.tokenCap))")
                continue
            }
            do {
                let (payload, tokens) = try await extract(source, plan: plan, budget: plan.agent.tokenCap - used)
                used += tokens
                let checked = ExtractionValidator.validate(payload, for: source)
                for r in checked.rejected { log.append("\(source.id): rejected \"\(r.row.benchmarkModel)\": \(r.reason)") }
                guard !checked.accepted.isEmpty else { throw IndexRefreshError.noValidRows(checked.rejected.count) }
                results.append(SourceResult(sourceID: source.id, rows: checked.accepted, rejected: checked.rejected,
                                            refreshedAt: now(), tokens: tokens))
                log.append("\(source.id): \(checked.accepted.count) rows, \(tokens) tokens")
            } catch IndexRefreshError.overCap(let spent) {
                used += spent
                results.append(Self.stale(source, prior, "token cap reached"))
                log.append("\(source.id): stopped at the token cap after \(spent) tokens")
            } catch {
                results.append(Self.stale(source, prior, Self.describe(error)))
                log.append("\(source.id): failed: \(Self.describe(error))")
            }
        }

        let snapshot = IndexSnapshot.assemble(results: results, sources: plan.sources, aliases: plan.aliases, createdAt: now())
        let proposals = AliasProposer.propose(snapshot.unmapped, table: plan.aliases, catalogs: plan.catalogs)
        return IndexRefreshOutcome(snapshot: snapshot, proposals: proposals, log: log, tokensUsed: used)
    }

    /// Re-scores a snapshot's rows under a changed alias table or source list — no agent run, no
    /// tokens. Used when the user confirms or edits an alias, so the change is a new snapshot
    /// that rollback can undo.
    static func rescore(_ snapshot: IndexSnapshot, sources: [IndexSource], aliases: AliasTable, now: Date) -> IndexSnapshot {
        IndexSnapshot.assemble(results: snapshot.sources, sources: sources, aliases: aliases, createdAt: now)
    }

    private func extract(_ source: IndexSource, plan: IndexRefreshPlan, budget: Int) async throws -> (ExtractionPayload, Int) {
        let command = IndexExtraction.command(prompt: IndexExtraction.prompt(source: source, catalogs: plan.catalogs),
                                              settings: plan.agent)
        let meter = IndexTokenMeter(cwd: plan.workDirectory, budget: budget)
        let headless = self.headless
        let cwd = plan.workDirectory
        let run = Task { try await headless.run(command, cwd: cwd, onStdout: { meter.feed($0) }) }
        // Cancelling the task terminates the process (`SystemCommandRunner`'s cancellation
        // handler sends SIGTERM), which is how a run is stopped at the cap.
        meter.whenOver { run.cancel() }
        let result: (stdout: Data, stderr: String, exitCode: Int32)
        do {
            result = try await run.value
        } catch {
            if meter.isOver { throw IndexRefreshError.overCap(used: meter.total) }
            throw error
        }
        // A runner that cannot stream hands stdout over at exit, too late to stop it — the cap
        // still applies: over is over, whether or not the process could be stopped early.
        if meter.isOver { throw IndexRefreshError.overCap(used: meter.total) }
        guard result.exitCode == 0 else {
            throw IndexRefreshError.harness("claude exited \(result.exitCode): \(result.stderr.prefix(200))")
        }
        return (try IndexExtraction.parse(stdout: result.stdout), meter.total)
    }

    static func stale(_ source: IndexSource, _ prior: SourceResult?, _ why: String) -> SourceResult {
        SourceResult(sourceID: source.id, rows: prior?.rows ?? [], stale: true, error: why,
                     refreshedAt: prior?.refreshedAt, tokens: 0)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? IndexRefreshError {
            switch e {
            case .harness(let why): return why
            case .noValidRows(let n): return "no valid rows (\(n) rejected)"
            case .overCap(let used): return "token cap reached after \(used) tokens"
            }
        }
        if let e = error as? HeadlessOutput.ParseError { return "unreadable answer: \(e)" }
        if error is DecodingError { return "the answer did not match the row format" }
        return String(describing: error)
    }
}
