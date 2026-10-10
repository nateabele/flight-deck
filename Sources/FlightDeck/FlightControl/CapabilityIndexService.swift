import Foundation
import IntakeKit

/// The `CapabilityIndex` the router holds (integration passes this to L3-R). A lock-guarded
/// box: the protocol is nonisolated and `Sendable`, so the router may read it from any context,
/// while the service swaps in a new frozen `SnapshotCapabilityIndex` on the main actor
/// whenever a snapshot applies, a rollback happens or a hand score changes.
final class LiveCapabilityIndex: CapabilityIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var index = SnapshotCapabilityIndex.empty

    func update(_ new: SnapshotCapabilityIndex) { lock.withLock { index = new } }
    var current: SnapshotCapabilityIndex { lock.withLock { index } }

    func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] { current.rank(kind: kind, candidates: candidates) }
    var snapshotDate: Date? { current.snapshotDate }

    func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] {
        current.hints(for: ruleDimensions, assigned: assigned, candidates: candidates)
    }
}

/// Owns the capability index: its config, its snapshots, the weekly refresh and the live index.
///
/// A new snapshot applies the moment it is written (spec §7) — safe because the index only
/// drives fallback routing and hints, never a rule. Rollback is one call. Built and scheduled
/// only by `FlightDeckApp.makeStore`; every test builds its own with a scratch directory and a
/// scripted runner, so no test can start a refresh that spends tokens.
@MainActor
final class CapabilityIndexService: ObservableObject {
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var config: IndexConfig
    @Published private(set) var currentRef: SnapshotRef?
    @Published private(set) var current: IndexSnapshot?
    @Published private(set) var previous: IndexSnapshot?
    @Published private(set) var changes: [ScoreChange] = []
    /// The current snapshot's scores with hand and inherited scores laid over them — what the
    /// heatmap draws and what `live` ranks.
    @Published private(set) var scores: [ModelScores] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastLog: [String] = []
    @Published private(set) var problem: String?
    /// One per source run by the latest refresh (the one in flight, if any), each stamped with
    /// the account it billed. `UsageService` folds these with planning's seats, so a refresh's
    /// `rate_limit_event`s meter the account it leased — the pool then stops leasing an account
    /// the refresh found exhausted.
    @Published private(set) var seatActivities: [SeatActivity] = []
    /// The catalogs the last refresh saw, for the alias "Map to…" menu.
    @Published private(set) var knownCatalogs = AdapterCatalogs([])

    let live = LiveCapabilityIndex()
    let directory: URL
    /// The refresh in flight, if any — exposed so tests (and nothing else) can await it.
    private(set) var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    private let store: IndexSnapshotStore
    private let runner: IndexRefreshRunner
    private let catalogs: @MainActor () async -> AdapterCatalogs
    private let now: () -> Date
    private weak var clock: WatchClock?
    /// Which claude login a refresh bills: the index's own assignment (Settings → Flight Control
    /// → Capability Index), Default claude's pool, leased for the length of the refresh. Before
    /// round 2 the refresh always ran in the built-in `~/.claude`; item 11 then resolved it as an
    /// unassigned project, which billed claude's first live account and never leased. nil
    /// (tests, reset launches): the built-in home. Weak: the store owns the resolver.
    weak var accountResolver: IndexAccountResolving?

    init(directory: URL, runner: IndexRefreshRunner = IndexRefreshRunner(),
         catalogs: @escaping @MainActor () async -> AdapterCatalogs = { AdapterCatalogs([]) },
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.store = IndexSnapshotStore(directory: directory)
        self.runner = runner
        self.catalogs = catalogs
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = IndexConfig.load(from: directory.appendingPathComponent("config.json"))
        config = loaded.config
        problem = loaded.problem
        reload()
    }

    /// `<state dir>/capability-index`. The state dir already differs between Debug and Release
    /// (`FileSessionPersistence.defaultDirectory`), so a Debug build never applies, rolls back
    /// or overwrites the installed app's index.
    static func directory(stateRoot: URL) -> URL {
        stateRoot.appendingPathComponent("capability-index", isDirectory: true)
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }

    var canRollBack: Bool { previous != nil }

    /// Re-reads the snapshots and republishes everything derived from them, `live` included.
    func reload() {
        let cur = store.current()
        currentRef = cur?.ref
        current = cur?.snapshot
        previous = cur.flatMap { store.previous(before: $0.ref)?.snapshot }
        changes = current.map { SnapshotDiff.changes(from: previous, to: $0) } ?? []
        scores = CapabilityScoring.overlay(current?.scores ?? [], manual: config.manual)
        live.update(SnapshotCapabilityIndex(scores: scores, snapshotDate: current?.createdAt))
    }

    // MARK: - The weekly check

    /// Due a week after the last attempt (or, failing that, the current snapshot). Never due
    /// before either exists: the first refresh is the user's "Refresh now", so a fresh install
    /// never spends tokens nobody asked for.
    var isDue: Bool {
        guard let last = config.lastRefreshAttemptAt ?? current?.createdAt else { return false }
        return now().timeIntervalSince(last) >= Self.refreshInterval
    }

    /// Registers on the app's one `WatchClock` rather than owning a weekly timer: a beat costs a
    /// date comparison, and a second timer would be a second wakeup source.
    func startScheduling(clock: WatchClock) {
        self.clock = clock
        clock.add(self) { [weak self] in self?.tick() }
    }

    func stopScheduling() { clock?.remove(self) }

    func tick() {
        guard isDue else { return }
        startRefresh()
    }

    // MARK: - Refresh

    /// Starts a refresh unless one is running. `lastRefreshAttemptAt` is written HERE, before
    /// the run, not when it succeeds: a run that fails would otherwise leave the index due, and
    /// the next clock beat 500 ms later would start another — a token-burning retry loop.
    @discardableResult
    func startRefresh() -> Task<Void, Never>? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        mutateConfig { $0.lastRefreshAttemptAt = now() }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        return task
    }

    func refreshNow() async {
        await startRefresh()?.value
    }

    /// Stops the refresh in flight: the running claude is terminated, the sources not yet run
    /// are skipped, no snapshot is written, and the account lease is given back.
    func cancelRefresh() {
        refreshTask?.cancel()
    }

    private func performRefresh() async {
        let cats = await catalogs()
        knownCatalogs = cats
        let work = directory.appendingPathComponent("work", isDirectory: true)
        // A broken STORED assignment refuses: never another login. The lease (when the
        // assignment is a pool) is held for the whole refresh and given back below on every
        // path that got one — success, failed sources, cancel — since `runner.refresh` never
        // throws and every path after it falls through to the release.
        var billing: ResolvedAccount?
        if let accountResolver {
            switch accountResolver.acquireIndexAccount(.claude) {
            case .failure(let error):
                problem = "Could not refresh the index: \(Self.message(error))"
                lastLog = ["refused: \(Self.message(error))"]
                isRefreshing = false
                return
            case .success(let resolved):
                billing = resolved
            }
        }
        var plan = IndexRefreshPlan(sources: config.sources, aliases: config.aliases, catalogs: cats, agent: config.agent,
                                    previous: current, workDirectory: work)
        plan.account = billing?.entry.ref
        plan.accountID = billing?.account?.id
        seatActivities = []
        refreshGeneration += 1
        let generation = refreshGeneration
        let outcome = await runner.refresh(plan) { activity in
            // Generation-checked: a hop still queued when the refresh ends (or when the next one
            // starts) must not add a source twice, or add last week's to this week's list.
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == generation, !self.seatActivities.contains(activity) else { return }
                self.seatActivities.append(activity)
            }
        }
        if let lease = billing?.lease { accountResolver?.release(lease) }
        // The outcome's list is complete; the hops above may still be queued behind this one.
        refreshGeneration += 1
        seatActivities = outcome.activities
        var log = outcome.log
        if let billing { log.insert("billed: \(billing.label)", at: 0) }
        if let notice = billing?.notice { log.insert("\(notice.title). \(notice.body)", at: 1) }
        lastLog = log
        guard !outcome.cancelled else {
            // Nothing is written: a snapshot of a cancelled refresh would push a real one out of
            // the twelve kept, and its skipped sources would read as failures.
            lastLog.append("refresh cancelled; no snapshot written")
            isRefreshing = false
            return
        }
        mutateConfig { $0.aliases.addProposals(outcome.proposals) }
        // The plan captured aliases and sources before a run that can last minutes. Re-score with
        // the config as it is NOW: an edit made mid-run otherwise leaves a newer snapshot scored
        // with the old mapping as current, and the config and the displayed scores disagree.
        let written = IndexRefreshRunner.rescore(outcome.snapshot, sources: config.sources, aliases: config.aliases, now: outcome.snapshot.createdAt)
        do {
            try store.write(written)
            try store.prune()
        } catch {
            problem = "Could not save the snapshot: \(error.localizedDescription)"
        }
        reload()
        isRefreshing = false
    }

    /// `AccountResolutionError.message` names "this project" and Settings → Projects; the index
    /// has neither, and its fix is its own picker.
    static func message(_ error: AccountResolutionError) -> String {
        switch error {
        case .accountMissing:
            "the account chosen for the capability index no longer exists — choose another under Refresh agent"
        case .poolUnavailable(let pool, _):
            "the pool chosen for the capability index (\(pool)) has no account to use — choose another under Refresh agent"
        }
    }

    // MARK: - Rollback

    func rollBack() {
        do {
            try store.rollBack()
            problem = nil
        } catch IndexStoreError.nothingToRollBackTo {
            problem = "There is no earlier snapshot to roll back to."
        } catch {
            problem = "Could not roll back: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: - Aliases, sources, hand scores, agent

    func confirmAlias(source: String, benchmarkModel: String) {
        mutateAliases { $0.confirm(source: source, benchmarkModel: benchmarkModel) }
    }

    func rejectAlias(source: String, benchmarkModel: String) {
        mutateAliases { $0.reject(source: source, benchmarkModel: benchmarkModel) }
    }

    func removeAlias(source: String, benchmarkModel: String) {
        mutateAliases { $0.remove(source: source, benchmarkModel: benchmarkModel) }
    }

    func mapAlias(source: String, benchmarkModel: String, to model: ModelRef) {
        mutateAliases { $0.set(source: source, benchmarkModel: benchmarkModel, model: model, status: .confirmed) }
    }

    func setSourceEnabled(_ id: String, _ enabled: Bool) {
        mutateConfig { c in
            if let i = c.sources.firstIndex(where: { $0.id == id }) { c.sources[i].enabled = enabled }
        }
        rescoreCurrent()
    }

    /// Saves a hand-entered entry; `replacing` drops the entry it was edited from, so renaming a
    /// local model in the editor does not leave its old name behind.
    func setManual(_ entry: ManualModelScores, replacing old: ModelRef? = nil) {
        mutateConfig { c in
            c.manual.removeAll { $0.model == entry.model || $0.model == old }
            c.manual.append(entry)
        }
        reload()
    }

    func removeManual(_ model: ModelRef) {
        mutateConfig { $0.manual.removeAll { $0.model == model } }
        reload()
    }

    func setAgent(_ settings: IndexAgentSettings) {
        mutateConfig { $0.agent = settings }
    }

    func citations(model: ModelRef, dimension: String) -> [Citation] {
        guard let current else { return [] }
        return CapabilityScoring.citations(for: model, dimension: dimension, snapshot: current, sources: config.sources)
    }

    func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] {
        live.hints(for: ruleDimensions, assigned: assigned, candidates: candidates)
    }

    /// Only a change to what MAPS rescoring: a new pending proposal or a rejected one that was
    /// never confirmed changes no score, and writing a snapshot for it would push a real one out
    /// of the twelve kept.
    private func mutateAliases(_ change: (inout AliasTable) -> Void) {
        let before = config.aliases.confirmed
        mutateConfig { change(&$0.aliases) }
        guard config.aliases.confirmed != before else { return }
        rescoreCurrent()
    }

    private func rescoreCurrent() {
        guard let current else { reload(); return }
        let rescored = IndexRefreshRunner.rescore(current, sources: config.sources, aliases: config.aliases, now: now())
        // A rescore that moves no score and no unmapped name is skipped: every toggle or alias
        // edit would otherwise write a snapshot, and about twelve no-op edits would evict every
        // real refresh from the twelve kept. The config change itself is already saved.
        guard rescored.scores != current.scores || rescored.unmapped != current.unmapped else { reload(); return }
        do {
            try store.write(rescored)
            try store.prune()
        } catch {
            problem = "Could not save the rescored snapshot: \(error.localizedDescription)"
        }
        reload()
    }

    private func mutateConfig(_ change: (inout IndexConfig) -> Void) {
        var c = config
        change(&c)
        config = c
        do { try c.save(to: configURL) }
        catch { problem = "Could not save capability index settings: \(error.localizedDescription)" }
    }
}
