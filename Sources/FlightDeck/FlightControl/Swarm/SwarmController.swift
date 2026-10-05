import Foundation
import IntakeKit

/// One swarm's keep-it-fed loop (spec §4). Ticked by `SwarmService` on the shared `WatchClock`
/// and on events. Launches run as their own tasks so a two-minute composer wait never holds the
/// tick; `settle()` lets a test wait for them.
@MainActor
final class SwarmController {
    struct Dependencies {
        var backend: SwarmBackend
        var launcher: SwarmAgentLauncher
        var host: SwarmHost
        var router: any Router
        var kinds: any KindRegistry
        var allocator: any PoolAllocator
        var capacity: any CapacityReader
        var catalogs: () async -> AdapterCatalogs
    }

    enum LaunchPlan: Equatable {
        case spawn(block: ExecutionBlock, lease: AccountLease?)
        case reuse(session: UUID)
        case waiting(String)
    }

    private(set) var record: SwarmRecord
    private let deps: Dependencies
    private let store: SwarmStore
    private let now: () -> Date
    /// The service persists `swarms.json` (every swarm in one file) and republishes.
    var onChange: (SwarmRecord) -> Void = { _ in }

    /// Task id → its launch. A launch owns the task from slot to prompt.
    private var launches: [String: Task<Void, Never>] = [:]
    /// Spawns whose agent record does not exist yet, per pool — they hold a slot and pool load.
    private var pendingSpawns: [PoolID: Int] = [:]
    private var isTicking = false

    init(record: SwarmRecord, store: SwarmStore, deps: Dependencies, now: @escaping () -> Date = Date.init) {
        self.record = record; self.store = store; self.deps = deps; self.now = now
    }

    var project: URL { URL(fileURLWithPath: record.project, isDirectory: true) }
    private var pendingSpawnCount: Int { pendingSpawns.values.reduce(0, +) }
    var freeSlots: Int { max(0, record.cap - record.activeCount - pendingSpawnCount) }
    var inFlightTasks: Set<String> { Set(launches.keys) }

    func settle() async {
        while let next = launches.values.first { await next.value }
    }

    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        switch record.state {
        case .running: await fillSlots()
        case .draining, .paused, .stopped: break
        }
        changed()
    }

    private func fillSlots() async {
        guard freeSlots > 0 else { return }
        let ready: [ReadyTask]
        switch await deps.backend.readyTasks(project: project) {
        case .success(let tasks): ready = tasks
        case .failure(let error): log(.error, detail: error.message); return
        }
        let taken = Set(record.agents.compactMap(\.task))
            .union(record.agents.compactMap(\.pendingClaim))
            .union(inFlightTasks)
        let candidates = SwarmPlanner.candidates(ready, filter: record.filter, excluding: taken)
        var waiting: [WaitingTask] = []
        var unroutable: [WaitingTask] = []
        for task in candidates {
            guard record.state == .running else { break }
            let block: ExecutionBlock
            switch task.block {
            case .success(let decoded?): block = decoded
            case .success(nil):
                unroutable.append(WaitingTask(task: task.id, reason: "no execution block")); continue
            case .failure(let error):
                unroutable.append(WaitingTask(task: task.id, reason: error.message)); continue
            }
            // Out of slots: keep classifying (a block-less task must still be listed as
            // unroutable) but stop starting launches, and never lease for one we cannot start.
            guard freeSlots > 0 else { continue }
            let plan = await plan(task, block: block)
            if case .waiting(let reason) = plan {
                waiting.append(WaitingTask(task: task.id, reason: reason))
                continue
            }
            start(plan, for: task)
        }
        record.waiting = waiting
        record.unroutable = unroutable
    }

    /// Where a task's agent comes from. Tasks 7b and 7c replace this body (reuse, spill, caps).
    func plan(_ task: ReadyTask, block: ExecutionBlock, allowReuse: Bool = true) async -> LaunchPlan {
        if let lease = deps.allocator.lease(pool: block.pool) { return .spawn(block: block, lease: lease) }
        return .waiting("no account in \(block.pool) is under its soft limit")
    }

    private func start(_ plan: LaunchPlan, for task: ReadyTask) {
        switch plan {
        case .waiting: return
        case .reuse(let session):
            record.update(session) { $0.state = .starting; $0.stateSince = now(); $0.marker = nil }
        case .spawn(let block, _):
            pendingSpawns[block.pool, default: 0] += 1
        }
        let id = task.id
        launches[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(plan, for: task)
            self.launches[id] = nil
            self.changed()
        }
    }

    private func run(_ plan: LaunchPlan, for task: ReadyTask) async {
        switch plan {
        case .waiting, .reuse: return
        case .spawn(let block, let lease): await spawn(block, lease: lease, for: task)
        }
    }

    private func spawn(_ block: ExecutionBlock, lease: AccountLease?, for task: ReadyTask) async {
        let key = ConfigKey(block)
        let created = await deps.launcher.createAgent(task: TaskRef(id: task.id, project: project), block: block, lease: lease)
        pendingSpawns[block.pool] = max(0, (pendingSpawns[block.pool] ?? 1) - 1)
        switch created {
        case .failure(let error):
            if let lease { deps.allocator.release(lease) }
            noteSpawnFailure(key, error: error)
        case .success(let ref):
            record.spawnFailures[key.rawValue] = nil
            record.agents.append(SwarmAgentRecord(session: ref.id, agentName: ref.agentName ?? "", block: block,
                                                  lease: lease, task: nil, state: .starting, stateSince: now()))
            log(.spawn, task: task.id, session: ref.id, detail: "\(ref.agentName ?? "?") on \(key)")
            await claimAndPrompt(task, session: ref.id)
        }
    }

    /// Spec §4 steps 5–7. The claim comes after the spawn because it names the agent the spawn
    /// booted; a claim that fails leaves an idle agent the next tick can reuse.
    private func claimAndPrompt(_ task: ReadyTask, session: UUID) async {
        guard let agent = record.agent(session) else { return }
        // Saved BEFORE the claim runs (Review Focus: a crash mid-claim).
        record.update(session) { $0.pendingClaim = task.id }
        changed()
        switch await deps.backend.claim(task.id, actor: agent.agentName, project: project) {
        case .claimed:
            record.update(session) { $0.pendingClaim = nil; $0.task = task.id }
            log(.claim, task: task.id, session: session, detail: agent.agentName)
        case .conflict:
            becomeIdle(session)
            log(.conflict, task: task.id, session: session, detail: "claimed elsewhere; the next tick takes another task")
            return
        case .failed(let why):
            becomeIdle(session)
            log(.error, task: task.id, session: session, detail: "claim failed: \(why)")
            return
        }
        let detail = await deps.backend.taskDetail(task.id, project: project)
            ?? TaskDetail(id: task.id, title: task.title, description: "", acceptance: "",
                          status: "in_progress", assignee: agent.agentName)
        switch await deps.launcher.deliver(TaskPrompt.text(for: detail), to: session) {
        case .success:
            record.update(session) { $0.state = .working; $0.stateSince = now() }
            log(.prompt, task: task.id, session: session)
        case .failure(let error):
            await deliveryFailed(session, task: task.id, error: error)
        }
    }

    /// Task 7f replaces this body with the spec §10 stuck-at-start handling.
    private func deliveryFailed(_ session: UUID, task: String, error: SpawnError) async {
        _ = await deps.backend.returnToOpen(task, project: project)
        becomeIdle(session)
        log(.error, task: task, session: session, detail: Self.describe(error))
    }

    /// Task 7f replaces this body with the three-in-a-row pause.
    private func noteSpawnFailure(_ key: ConfigKey, error: SpawnError) {
        record.spawnFailures[key.rawValue, default: 0] += 1
        log(.spawnFailed, detail: "\(key): \(Self.describe(error))")
    }

    private func becomeIdle(_ session: UUID) {
        record.update(session) { $0.pendingClaim = nil; $0.task = nil; $0.state = .idle; $0.stateSince = now() }
    }

    static func describe(_ error: SpawnError) -> String {
        switch error {
        case .launchFailed(let why): why
        case .composerTimeout: "no composer within two minutes"
        case .unsupportedHarness(let harness): "no adapter named \(harness)"
        case .claimConflict(let task): "\(task) was claimed elsewhere"
        }
    }

    func log(_ kind: SwarmLogEntry.Kind, task: String? = nil, session: UUID? = nil, detail: String = "") {
        store.append(SwarmLogEntry(at: now(), kind: kind, task: task, session: session, detail: detail), swarm: record.id)
    }

    private func changed() { onChange(record) }
}
