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
        await sweepClosedTabs()
        switch record.state {
        case .running: await fillSlots()
        case .draining: finishDrainIfIdle()
        case .paused, .stopped: break
        }
        changed()
    }

    /// Called with the Observe watcher's in-progress task ids for this project. A working agent
    /// whose task left that set is asked about through `br show`, because "left in_progress"
    /// means closed, reopened, or merely a watcher snapshot that predates the claim.
    func taskSetChanged(inProgress: Set<String>) async {
        var freed = false
        for agent in record.agents where agent.state == .working {
            guard let task = agent.task, !inProgress.contains(task),
                  let reading = await deps.backend.status(task, project: project) else { continue }
            if reading.status == "closed" {
                record.update(agent.session) { $0.state = .idle; $0.lastTask = task; $0.task = nil; $0.stateSince = now() }
                log(.close, task: task, session: agent.session, detail: agent.agentName)
                freed = true
            } else if reading.status == "in_progress", reading.assignee == agent.agentName {
                continue
            } else {
                // Spec §4: back to open (or taken over) while its agent still held it.
                record.update(agent.session) { $0.state = .idle; $0.task = nil; $0.stateSince = now() }
                let who = reading.assignee.map { " · \($0)" } ?? ""
                log(.reopen, task: task, session: agent.session, detail: "now \(reading.status)\(who) while \(agent.agentName) held it")
                freed = true
            }
        }
        changed()
        if freed { await tick(); await settle() }
    }

    /// A tab the user closed (Review Focus): its claim goes back to open unless the task is
    /// already closed or someone else holds it, its lease is released, and it leaves the swarm.
    private func sweepClosedTabs() async {
        for agent in record.agents where [.starting, .working, .idle].contains(agent.state)
            && !deps.host.sessionExists(agent.session) {
            // Read every task first: a status that could not be read (br show failed) must never
            // be treated as "open and ours". The agent stays untouched, lease included, so the
            // next tick re-reads it and the slot accounting stays consistent meanwhile.
            var readings: [(task: String, reading: TaskStatusReading)] = []
            var unreadable = false
            for task in Set([agent.task, agent.pendingClaim].compactMap { $0 }).sorted() {
                guard let reading = await deps.backend.status(task, project: project) else { unreadable = true; break }
                readings.append((task, reading))
            }
            if unreadable { continue }
            for (task, reading) in readings {
                let ours = reading.assignee == nil || reading.assignee == agent.agentName
                if reading.status != "closed", ours {
                    _ = await deps.backend.returnToOpen(task, project: project)
                    log(.released, task: task, session: agent.session, detail: "\(agent.agentName)'s tab was closed")
                }
            }
            if let lease = agent.lease { deps.allocator.release(lease.lease) }
            record.update(agent.session) {
                $0.state = .done; $0.task = nil; $0.pendingClaim = nil; $0.marker = "tab closed"; $0.stateSince = now()
            }
        }
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
        let claimable = candidates.count - unroutable.count
        if record.state == .running, SwarmPlanner.isFinished(claimable: claimable, waiting: waiting.count,
                                                              active: record.activeCount,
                                                              launching: launches.count + pendingSpawnCount) {
            stop(reason: "nothing left to do")
        }
    }

    /// No new claims or spawns; running agents continue (spec §4).
    func pause() {
        guard record.state == .running || record.state == .draining else { return }
        record.state = .paused
        log(.pause)
        changed()
    }

    func resume() async {
        guard record.state == .paused || record.state == .draining else { return }
        record.state = .running
        record.banner = nil
        record.spawnFailures = [:]
        log(.resume)
        changed()
        await tick()
    }

    /// Like pause, and the swarm becomes stopped when the last working agent goes idle.
    func drain() {
        guard record.state == .running || record.state == .paused else { return }
        record.state = .draining
        log(.drain)
        finishDrainIfIdle()
        changed()
    }

    /// The swarm keeps nothing running: leases are released and agents leave it. Their tabs stay
    /// open, and their claims stay with them — turning Flight Control off is what returns claims.
    /// An agent already `.done` (its tab was closed) had its lease released then; the record keeps
    /// the lease for history, so releasing it again here would double-free the account.
    func stop(reason: String) {
        guard record.state != .stopped else { return }
        record.state = .stopped
        for agent in record.agents where agent.state != .done && agent.state != .handedOff {
            retire(agent)
        }
        log(.stop, detail: reason)
        changed()
    }

    private func retire(_ agent: SwarmAgentRecord) {
        if let lease = agent.lease { deps.allocator.release(lease.lease) }
        record.update(agent.session) { $0.state = .done; $0.stateSince = now() }
    }

    private func finishDrainIfIdle() {
        guard record.state == .draining, record.activeCount == 0, launches.isEmpty, pendingSpawnCount == 0 else { return }
        stop(reason: "drained")
    }

    /// Reuse is checked before leasing (deviation 3): an idle agent already holds a lease on an
    /// account under soft, and leasing first would hold two for one agent. Then: a lease in the
    /// block's pool if the pool is under its own cap; else, unless the block is pinned, L3-R's
    /// spill for this one spawn; else the task waits, with why.
    func plan(_ task: ReadyTask, block: ExecutionBlock, allowReuse: Bool = true) async -> LaunchPlan {
        if allowReuse, let agent = SwarmPlanner.reuseCandidate(
            for: ConfigKey(block), in: record.agents,
            isAvailable: { [deps] id in deps.host.sessionExists(id) && deps.host.isAgentIdle(id) },
            headroom: { [weak self] in self?.headroom(of: $0) ?? .unknown }) {
            return .reuse(session: agent.session)
        }
        if let lease = leaseIfRoom(block.pool) { return .spawn(block: block, lease: lease) }
        // A pinned block is a human's decision; L3-0 says it never spills.
        if block.pinned { return .waiting("pinned to \(block.pool), which has no account under its soft limit") }
        guard let kind = resolveKind(block.kind) else {
            return .waiting("\(block.pool) is full and kind \(block.kind) is unknown")
        }
        let catalogs = await deps.catalogs()
        let spill = deps.router.spill(block, kind: kind, project: project, exhausted: [block.pool],
                                      catalogs: catalogs, now: now())
        // An unroutable spill has pool "": leasing it would hand out nothing and name no pool.
        guard let spill, !spill.isUnroutable else {
            return .waiting("\(block.pool) is full and \(spill?.unroutableReason ?? "nothing else fits")")
        }
        let spilled = spill.block
        guard let lease = leaseIfRoom(spilled.pool) else {
            return .waiting("\(block.pool) is full and \(spilled.pool) is full too")
        }
        log(.spill, task: task.id, detail: "\(block.pool) → \(spilled.pool) (\(spilled.model))")
        return .spawn(block: spilled, lease: lease)
    }

    /// A pool at its own cap is full without asking the allocator: the cap is about concurrency
    /// (a local model serves one agent at a time), which no account's headroom can answer.
    private func leaseIfRoom(_ pool: PoolID) -> AccountLease? {
        if let cap = record.poolCap(pool), record.load(of: pool) + (pendingSpawns[pool] ?? 0) >= cap { return nil }
        return deps.allocator.lease(pool: pool)
    }

    private func resolveKind(_ id: KindID) -> TaskKind? {
        guard let kinds = try? deps.kinds.kinds(project: project) else { return nil }
        return KindResolution.resolve(id, in: kinds)
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
            self.finishDrainIfIdle()
            self.changed()
        }
    }

    private func run(_ plan: LaunchPlan, for task: ReadyTask) async {
        switch plan {
        case .waiting: return
        case .reuse(let session): await reuse(session, for: task)
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

    private func reuse(_ session: UUID, for task: ReadyTask) async {
        guard let agent = record.agent(session) else { return }
        log(.reuse, task: task.id, session: session, detail: agent.agentName)
        // Reservations first (Review Focus): a reused agent still holds its last task's files, and
        // would block every other agent's commit on them.
        if !(await deps.backend.releaseReservations(agent: agent.agentName, project: project)) {
            log(.error, session: session, detail: "could not release \(agent.agentName)'s reservations")
        }
        deps.host.wakeIfAsleep(session)
        guard await deps.launcher.resetContext(session) else {
            record.update(session) {
                $0.state = .idle; $0.stateSince = now(); $0.excludedFromReuse = true; $0.marker = "reset failed"
            }
            log(.resetFailed, task: task.id, session: session, detail: "spawning a fresh agent instead")
            // Spec §10: spawn a new agent instead. The task is still unclaimed.
            if record.state == .running,
               case .spawn(let block, let lease) = await plan(task, block: agent.block.block, allowReuse: false) {
                pendingSpawns[block.pool, default: 0] += 1
                await spawn(block, lease: lease, for: task)
            }
            return
        }
        await claimAndPrompt(task, session: session)
    }

    func headroom(of agent: SwarmAgentRecord) -> HeadroomState {
        guard let lease = agent.lease?.lease else { return .unknown }
        return deps.capacity.headroom(for: lease)?.state ?? .unknown
    }

    /// Spec §4 steps 5–7. The claim comes after the spawn because it names the agent the spawn
    /// booted; a claim that fails leaves an idle agent the next tick can reuse.
    private func claimAndPrompt(_ task: ReadyTask, session: UUID) async {
        guard let agent = record.agent(session), agent.state != .done else { return }
        // The swarm may have been paused, drained or stopped while the spawn or reset ran (R4).
        switch record.state {
        case .running: break
        case .stopped: retire(agent); return
        case .paused, .draining: becomeIdle(session); return
        }
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

extension CapacityReader {
    /// The headroom row for the account a lease holds, or nil when the reader does not list it.
    func headroom(for lease: AccountLease) -> AccountHeadroom? {
        headroom(pool: lease.pool).first { $0.account == lease.account }
    }
}
