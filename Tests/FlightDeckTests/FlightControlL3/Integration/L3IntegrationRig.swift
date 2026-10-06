import Foundation
import IntakeKit
@testable import FlightDeck

/// The real Level 3 graph with only the process boundary faked: `br`/`am` are a `MultiRunner`,
/// tab creation is L3-S's `FakeSwarmAgentLauncher` (each "spawn" opens a real store tab with a
/// spy injector, so the hand-off's exit command and transcript lookup hit the real store), and
/// the clock is a `UsageTestClock`. Routing, capacity, the hand-off driver and the swarm
/// controller are the production types, wired by `FlightControlComposition.install`.
///
/// Helpers carry no assertions: every check lives in the test that reads it.
@MainActor
final class L3IntegrationRig {
    /// One tab the swarm or the hand-off driver started, as the brief's `spawns` reads it.
    struct Spawn {
        let session: SessionRef
        let block: ExecutionBlock
        let lease: AccountLease?
        /// The first prompt delivered to that tab ("" when none landed).
        let firstPrompt: String
    }

    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// The contract's one-call spawn over the fake launcher, through production's own
    /// `ContractSpawn` sequence (create → claim → prompt, closing the tab on a failure after it
    /// exists), so a hand-off's first prompt is recorded like any other.
    final class RigSpawner: SwarmSpawner {
        let launcher: FakeSwarmAgentLauncher
        let backend: SwarmBackend
        /// Runs at the start of every hand-off spawn: the window between the old claim going
        /// back to open and the new one landing, where a test plays the Observe watcher.
        var onSpawn: (() async -> Void)?
        /// What `StoreSwarmSpawner.live` does with a tab it cannot use: the rig closes the store tab.
        var discard: (UUID) -> Void = { _ in }
        init(launcher: FakeSwarmAgentLauncher, backend: SwarmBackend) { self.launcher = launcher; self.backend = backend }
        func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
            await onSpawn?()
            return await ContractSpawn.run(
                create: { [launcher] in
                    let result = await launcher.createAgent(task: task, block: block, lease: lease)
                    return (result, try? result.get().id)
                },
                claim: { [backend] in await backend.claim(task.id, actor: $0.agentName ?? "", project: task.project) },
                deliver: { [launcher] in await launcher.deliver(firstPrompt, to: $0) },
                discard: discard, task: task)
        }
    }

    /// The real ledger behind a release counter, so "released exactly once" is observable: the
    /// ledger itself forgets an unknown lease silently, which would hide a double release.
    final class CountingAllocator: PoolAllocator, CapacityReader, @unchecked Sendable {
        let ledger: CapacityLedger
        private let lock = NSLock()
        private var counts: [UUID: Int] = [:]
        init(_ ledger: CapacityLedger) { self.ledger = ledger }
        func lease(pool: PoolID) -> AccountLease? { ledger.lease(pool: pool) }
        func release(_ lease: AccountLease) {
            lock.withLock { counts[lease.id, default: 0] += 1 }
            ledger.release(lease)
        }
        func headroom(pool: PoolID) -> [AccountHeadroom] { ledger.headroom(pool: pool) }
        func releases(of lease: AccountLease) -> Int { lock.withLock { counts[lease.id] ?? 0 } }
    }

    let root: URL
    let projectURL: URL
    var project: String { projectURL.path }
    let clock = UsageTestClock()
    let preferences: PreferencesStore
    let store: SessionStore
    let routing: RoutingService
    let usage: UsageService
    let runner = MultiRunner()
    let log = SwarmCallLog()
    let launcher: FakeSwarmAgentLauncher
    let spawner: RigSpawner
    let swarm: SwarmService
    /// The next tab creation fails, as a launch that never got a tab would.
    var failNextCreate = false
    /// A second Flight Control project, for state that must not leak between swarms.
    let secondProjectURL: URL
    let allocator: CountingAllocator
    let watch = WatchClock(appIsActive: { true })
    let spy = SpyInjector()
    /// Every notification the store raised (the hand-off host notifies through it).
    let notifier = UsageSpyNotifier()
    /// The name the next opened tab's agent gets instead of `AgentN` (e.g. "" for a nameless one).
    var nextAgentName: String?
    private(set) var createdSessions: [SessionRef] = []
    private var tabStatuses: [UUID: SessionStatus] = [:]
    private var blocks: [String: ExecutionBlock] = [:]
    private var titles: [String: String] = [:]
    private let claudeAccount: AgentAccount

    private init(accounts: [String], harness: HarnessID, rule: RoutingRule) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-l3-rig-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        projectURL = root.appendingPathComponent("project", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        secondProjectURL = root.appendingPathComponent("project-b", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: secondProjectURL, withIntermediateDirectories: true)

        // Hermetic: a nil persistence never reads or writes the real preferences domain.
        preferences = PreferencesStore(persistence: nil)
        guard let agent = AgentID(rawValue: harness.rawValue) else { throw CocoaError(.featureUnsupported) }
        // The tabs the rig opens are claude tabs (no process, no app-server); their transcripts
        // resolve under this synthetic account's home, never the developer's ~/.claude.
        claudeAccount = AgentAccount(agent: .claude, displayName: "Rig Claude", home: root.appendingPathComponent("claude-home"))
        preferences.preferences.accounts = accounts.map {
            AgentAccount(agent: agent, displayName: $0, home: root.appendingPathComponent("home-\($0)"))
        } + [claudeAccount]
        preferences.globalRoutingRules = [rule]

        // Catalogs as production builds them: a harness whose agent is not in Settings is disabled.
        // The swarm's own (empty) registry is deliberately not the source of catalogs.
        routing = RoutingServiceSupport.make(prefs: preferences, loadCatalogs: { [prefs = preferences] in
            let on = Set(prefs.preferences.agents.map(\.id.harnessID))
            return RoutingTestData.catalogsDisabling(Set(RoutingTestData.catalogs.order).subtracting(on))
        })

        store = SessionStore(provider: StubProvider(), persistence: nil)
        store.launchFailureReporter = SilentReporter()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        store.notifier = notifier

        let clock = self.clock
        let prefs = preferences
        let claudeID = claudeAccount.id
        let env = UsageEnvironment(
            sessions: { [weak store] in store?.repos.flatMap(\.sessions) ?? [] },
            apiErrors: { [weak store] in store?.apiErrors ?? [:] },
            accounts: { [weak prefs] in prefs?.preferences.accounts ?? [] },
            resolvedAccountID: { agent, stored in stored ?? (agent == .claude ? claudeID : nil) },
            capacity: { [weak prefs] in prefs?.capacity ?? CapacityPreferences() },
            usageDirectory: root.appendingPathComponent("usage", isDirectory: true),
            codexRead: { _ in nil }, seatActivities: { [] }, notifier: { nil }, isSwarmSession: { _ in false })
        let ledger = CapacityLedger(now: { clock.now })
        usage = UsageService(environment: env, ledger: ledger, now: { clock.now })
        usage.reconfigure()
        allocator = CountingAllocator(ledger)

        launcher = FakeSwarmAgentLauncher(log: log)
        let backend = BrSwarmBackend(runner: runner)
        spawner = RigSpawner(launcher: launcher, backend: backend)
        swarm = SwarmService(store: SwarmStore(root: root.appendingPathComponent("swarms", isDirectory: true)),
                             backend: backend, launcher: launcher, spawner: spawner,
                             host: store, registry: RoutingCapabilityRegistry([]), clock: watch, now: { clock.now })
        launcher.onCreateAttempt = { [weak self] in self?.openTab() }
        spawner.discard = { [weak store] in store?.closeSession($0, recordingHistory: false) }
    }

    static func make(accounts: [String], harness: HarnessID, rule: RoutingRule, readyTasks: [String]) throws -> L3IntegrationRig {
        let rig = try L3IntegrationRig(accounts: accounts, harness: harness, rule: rule)
        rig.store.useSwarmService(rig.swarm)
        rig.store.flightControlRouting = rig.routing
        // The result is deliberately dropped: only the store may keep the graph alive, which is
        // what `testTheInstalledDriverOutlivesInstall` checks.
        FlightControlComposition.install(
            on: rig.store, preferences: rig.preferences, usage: rig.usage,
            commands: BrAmHandoffCommands(runner: rig.runner),
            logURL: rig.root.appendingPathComponent("handoffs.jsonl"),
            allocator: rig.allocator, now: { [clock = rig.clock] in clock.now })
        // "Released": each task's block is what the real router, holding the confirmed rule and
        // the capacity pools install wired in, assigns to its kind — as intake release writes it.
        for id in readyTasks { try rig.release(id) }
        return rig
    }

    /// Another released task, routed by whatever rules are in force now. For a task that becomes
    /// ready mid-test.
    func release(_ id: String) throws {
        let kinds = try routing.kindStore.kinds(project: projectURL)
        let tests = try XCTUnwrapRig(KindResolution.resolve("tests", in: kinds))
        blocks[id] = routing.makeRouter().assign(kind: tests, project: projectURL, catalogs: RoutingTestData.catalogs,
                                                 now: clock.now).block
        titles[id] = "Synthetic task \(id)"
        scriptBr()
    }

    // MARK: - Driving

    var now: Date { clock.now }

    /// The id the capacity ledger and `MeterFormatter` know the account by.
    func accountID(_ label: String) -> UUID? {
        preferences.preferences.accounts.first { $0.displayName == label }?.id
    }

    func feed(account label: String, utilization: Double) {
        guard let account = preferences.preferences.accounts.first(where: { $0.displayName == label }) else { return }
        clock.advance(1)
        usage.ingest(UsageReading(account: CapacityPreferences.accountRef(account),
                                  windows: [UsageWindow(name: "five_hour", utilization: utilization, resetsAt: nil)],
                                  readAt: clock.now, source: "rig", hardRejection: false))
    }

    func launch(cap: Int, project: String? = nil) async throws {
        guard swarm.launch(project: project ?? self.project, cap: cap, poolCaps: [:], filter: .allReady) != nil else {
            throw CocoaError(.featureUnsupported)
        }
        await swarm.settle()
    }

    /// One clock beat past the swarm's throttle, then everything it started.
    func tick() async {
        clock.advance(SwarmService.tickInterval)
        watch.fire()
        await swarm.settle()
    }

    func markIdle(_ session: SessionRef) {
        tabStatuses[session.id] = SessionStatus(activity: .idle)
        store.applyRegistryForTesting(tabStatuses)
    }

    /// The tab reports no status at all: a boundary for the driver, and a tab the exit command
    /// cannot be typed into (`submitPrompt` answers `notRunning`), so stopping it fails.
    func clearStatus(_ session: SessionRef) {
        tabStatuses[session.id] = nil
        store.applyRegistryForTesting(tabStatuses)
    }

    func addPool(id: PoolID, accounts labels: [String]) {
        let ids = preferences.preferences.accounts.filter { labels.contains($0.displayName) }.map(\.id)
        let harness = preferences.preferences.accounts.first { labels.contains($0.displayName) }?.agent.harnessID ?? "codex"
        preferences.updateCapacity { capacity in
            capacity.pools = (capacity.pools ?? []) + [.hosted(id: id, label: id.rawValue, harness: harness, accounts: ids)]
        }
        usage.reconfigure()
    }

    func setBlockPool(task: String, pool: PoolID, pinned: Bool) {
        blocks[task]?.pool = pool
        blocks[task]?.pinned = pinned
        scriptBr()
    }

    // MARK: - Reading

    var spawns: [Spawn] {
        zip(launcher.created, createdSessions).map { call, ref in
            Spawn(session: ref, block: call.block, lease: call.lease,
                  firstPrompt: launcher.delivered.first { $0.session == ref.id }?.prompt ?? "")
        }
    }

    /// The Observe watcher's projection change, with nothing in progress: what it reports once a
    /// claim goes back to open.
    func watcherSeesNothingInProgress() async {
        let empty = FlywheelProjection.project(
            FlywheelSnapshot(agents: [], beads: [], reservations: nil, depEdges: nil, events: nil),
            now: clock.now, stallThreshold: 600, previous: nil)
        await swarm.applyProjections([SwarmService.key(project): empty])
    }

    /// `br show` from now on answers with this status and assignee, as br would after a write.
    func brShows(_ task: String, status: String, assignee: String?) {
        var detail: [String: Any] = ["id": task, "title": titles[task] ?? task, "status": status,
                                     "description": "Synthetic description.", "acceptance_criteria": "- synthetic"]
        if let assignee { detail["assignee"] = assignee }
        runner.responses["br show \(task)"] = (json([detail]), 0)
    }

    func waitingReason(task: String) -> String? {
        swarm.record(forProject: project)?.waiting.first { $0.task == task }?.reason
    }

    func isHandedOff(_ session: SessionRef) -> Bool {
        swarm.agentRecord(session.id)?.1.state == .handedOff
    }

    /// The hand-off log the composition writes (`HandoffLogEntry`, one per line).
    var handoffLog: [HandoffLogEntry] {
        (try? Data(contentsOf: root.appendingPathComponent("handoffs.jsonl"))).map(HandoffHistory.parse) ?? []
    }

    func transcriptPath(of session: SessionRef) -> String {
        guard case .path(let path)? = usage.transcriptPointer(for: session)?.locator else { return "<no transcript>" }
        return path
    }

    // MARK: - Internals

    /// A real tab for every spawn the launcher is asked for, busy at its first turn, with a
    /// transcript file where the claude pointer looks, so the hand-off prompt can name it.
    private func openTab() {
        if failNextCreate {
            failNextCreate = false
            launcher.createResults = [.failure(.launchFailed("rig: no tab"))]
            return
        }
        let session = store.newSession(in: projectURL, selecting: false)
        let ref = SessionRef(id: session.id, agentName: nextAgentName ?? "Agent\(createdSessions.count + 1)")
        nextAgentName = nil
        createdSessions.append(ref)
        launcher.createResults = [.success(ref)]
        tabStatuses[session.id] = SessionStatus(activity: .busy)
        store.applyRegistryForTesting(tabStatuses)
        let transcript = ClaudeSession.transcriptURL(
            sessionID: session.pinnedConversationID, workingDirectory: session.transcriptDirectory,
            projectsRoot: claudeAccount.home.appendingPathComponent("projects", isDirectory: true))
        try? FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}\n".utf8).write(to: transcript)
    }

    /// `br ready`/`scheduler`/`list` from the current blocks; every `update`, `show` and `am`
    /// release succeeds. Synthetic rows only.
    private func scriptBr() {
        let ids = blocks.keys.sorted()
        let ready = ids.map { id -> [String: Any] in
            ["id": id, "title": titles[id] ?? id, "status": "open", "priority": 1, "issue_type": "task"]
        }
        let list = ids.map { id -> [String: Any] in
            var row: [String: Any] = ["id": id, "title": titles[id] ?? id, "status": "open", "priority": 1,
                                      "issue_type": "task", "labels": [String](),
                                      "created_at": "2026-10-04T18:00:00Z", "updated_at": "2026-10-04T18:00:00Z"]
            if let block = blocks[id], let context = try? ExecutionBlockCodec.encode(block, into: nil) { row["agent_context"] = context }
            return row
        }
        runner.responses["br ready --json"] = (json(ready), 0)
        runner.responses["br scheduler --format"] = (json(["schema": "br.scheduler.v1", "recommendations": [[String: Any]]()]), 0)
        runner.responses["br list --status"] = (json(["total": ids.count, "issues": list]), 0)
        for id in ids {
            runner.responses["br update \(id)"] = ("{}", 0)
            let detail: [String: Any] = ["id": id, "title": titles[id] ?? id, "status": "in_progress",
                                         "description": "Synthetic description.", "acceptance_criteria": "- synthetic"]
            runner.responses["br show \(id)"] = (json([detail]), 0)
        }
        runner.responses["am file_reservations release"] = ("", 0)
    }

    private func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// `XCTUnwrap` without importing XCTest into the rig: the rig throws, the test reports.
func XCTUnwrapRig<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.coderValueNotFound) }
    return value
}
