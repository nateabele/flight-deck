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
        /// A factory, never a stored router: L3-R rebuilds its router when rules or the index change, so each plan asks fresh.
        var makeRouter: () -> any Router
        var kinds: any KindRegistry
        var allocator: any PoolAllocator
        var capacity: any CapacityReader
        var catalogs: () async -> AdapterCatalogs
        /// The pools Settings defines. Only asked when a lease fails, to tell "full" from "gone";
        /// nil skips the question (tests that predate it, and any caller with no directory).
        var pools: (any PoolDirectory)? = nil
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
    /// Restored agents whose claim could not be read or reopened; every tick retries exactly these.
    private var unreconciled: Set<UUID> = []

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
        await retryUnreconciled()
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
            // The loop walks a snapshot. A sweep (closed tab) or stop() may have retired this
            // agent during the read, releasing its lease; setting it idle again would revive it
            // with that lease, and the next sweep would release it a second time.
            guard isLive(agent.session), let current = record.agent(agent.session),
                  current.state == .working, current.task == task else { continue }
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
            let settled = await giveBackHeldTasks(of: agent, detail: "\(agent.agentName)'s tab was closed") { reading in
                reading.status != "closed" && (reading.assignee == nil || reading.assignee == agent.agentName)
            }
            if !settled { continue }
            // Re-read after the awaits: stop() may have retired the agent meanwhile, and it
            // released the lease then. Its held tasks were still given back, so the record
            // drops them either way; only a live agent's lease is released here.
            guard let current = record.agent(agent.session), current.state != .handedOff else { continue }
            if isLive(agent.session), let lease = current.lease { deps.allocator.release(lease.lease) }
            record.update(agent.session) {
                $0.state = .done; $0.task = nil; $0.pendingClaim = nil; $0.marker = "tab closed"; $0.stateSince = now()
            }
        }
    }

    /// Whether the controller may still act on this agent: it is in the swarm, not retired or
    /// handed off, and the swarm is not stopped. Every path re-checks this after an await,
    /// because stop() and the closed-tab sweep can retire the agent (and release its lease)
    /// while br answers.
    private func isLive(_ session: UUID) -> Bool {
        guard record.state != .stopped, let agent = record.agent(session) else { return false }
        return agent.state == .starting || agent.state == .working || agent.state == .idle
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

    /// L3-U's hand-off (spec §4): the old agent is marked handed off and the new agent carries
    /// the same task forward. The old lease is NOT released here: the hand-off driver owns it
    /// (it releases only once the old agent's exit command went out, and keeps it when that
    /// failed), and releasing here too freed it twice. A handed-off agent is skipped by `stop()`
    /// and the closed-tab sweep, so nothing else releases it either.
    @discardableResult
    func recordHandoff(from old: UUID, to new: SessionRef, block: ExecutionBlock, lease: AccountLease?) -> Bool {
        guard let previous = record.agent(old), previous.state == .working || previous.state == .idle else { return false }
        // An agent named "" can neither claim nor be messaged, and would be recorded as working
        // the task with no way to find it: refuse rather than record it.
        guard let newName = new.agentName, !newName.isEmpty else { return false }
        record.update(old) {
            $0.state = .handedOff; $0.handedOffTo = new.id; $0.lastTask = $0.task; $0.task = nil; $0.stateSince = now()
        }
        var next = SwarmAgentRecord(session: new.id, agentName: newName, block: block, lease: lease,
                                    task: previous.task, state: .working, stateSince: now())
        next.handedOffFrom = old
        record.agents.append(next)
        log(.handoff, task: previous.task, session: new.id, detail: "\(previous.agentName) → \(newName)")
        changed()
        return true
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
        // A pool deleted in Settings is not "full": saying so sends the user looking at usage,
        // and spilling would quietly route around a block that names a pool nobody has. The
        // task waits until its block is re-routed or the pool comes back. Asked only after the
        // lease failed, so a pool the allocator can still lease from is never called gone.
        if let directory = deps.pools, !directory.pools().contains(where: { $0.id == block.pool }) {
            return .waiting("pool \(block.pool) no longer exists")
        }
        // A pinned block is a human's decision; L3-0 says it never spills.
        if block.pinned { return .waiting("pinned to \(block.pool), which has no account under its soft limit") }
        guard let kind = resolveKind(block.kind) else {
            return .waiting("\(block.pool) is full and kind \(block.kind) is unknown")
        }
        let catalogs = await deps.catalogs()
        // The swarm may have been paused or stopped during that await; no lease for a spawn that
        // will not start.
        guard record.state == .running else { return .waiting("the swarm is no longer running") }
        let spill = deps.makeRouter().spill(block, kind: kind, project: project, exhausted: [block.pool],
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
        // A launch runs as its own task, after the tick that planned it: a pause or stop that
        // landed in between must not open a tab. The lease it was planned with goes back.
        guard record.state == .running else {
            pendingSpawns[block.pool] = max(0, (pendingSpawns[block.pool] ?? 1) - 1)
            if let lease { deps.allocator.release(lease) }
            return
        }
        let created = await deps.launcher.createAgent(task: TaskRef(id: task.id, project: project), block: block, lease: lease)
        pendingSpawns[block.pool] = max(0, (pendingSpawns[block.pool] ?? 1) - 1)
        // An agent with no name cannot claim (br would record an empty actor), so a launch that
        // returns none is a failed launch; its tab is left alone, as with any failed spawn.
        let outcome: Result<(ref: SessionRef, name: String), SpawnError> = created.flatMap { ref in
            guard let name = ref.agentName, !name.isEmpty else {
                return .failure(.launchFailed("the launcher returned no agent name"))
            }
            return .success((ref, name))
        }
        switch outcome {
        case .failure(let error):
            if let lease { deps.allocator.release(lease) }
            noteSpawnFailure(key, error: error)
        case .success(let (ref, name)):
            // The failure count is NOT reset here: a tab that opens but never shows a composer
            // is a failed launch too (spec §10), and resetting on the tab alone let a stuck
            // config open a fresh tab every two minutes forever. The prompt landing resets it.
            record.agents.append(SwarmAgentRecord(session: ref.id, agentName: name, block: block,
                                                  lease: lease, task: nil, state: .starting, stateSince: now()))
            log(.spawn, task: task.id, session: ref.id, detail: "\(name) on \(key)")
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
        // stop() may have retired this agent (lease released) while the release ran: never wake,
        // reset or type into it. A pause or drain means no new work either — waking the tab and
        // typing `/clear` is the start of new work — so the agent goes back to idle, reusable on
        // resume.
        guard isLive(session) else { return }
        guard record.state == .running else { becomeIdle(session); return }
        deps.host.wakeIfAsleep(session)
        guard await deps.launcher.resetContext(session) else {
            // ...or while the reset ran: a retired agent stays retired.
            if isLive(session) { exclude(session, marker: "reset failed") }
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
        let outcome = await deps.backend.claim(task.id, actor: agent.agentName, project: project)
        // stop() (the menu, or Turn Off) or the closed-tab sweep may have retired the agent while
        // the claim ran, releasing its lease. A claim that landed anyway is given back — Turn Off
        // has already read the claims it returns, so this one would otherwise stay in progress
        // under an agent nobody prompts — and nothing is typed or revived.
        guard isLive(session) else {
            if outcome == .claimed, await deps.backend.returnToOpen(task.id, project: project) {
                log(.released, task: task.id, session: session, detail: "claimed after \(agent.agentName) left the swarm")
            }
            record.update(session) { $0.pendingClaim = nil }
            return
        }
        switch outcome {
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
        // The same race across the detail read: never type into a retired agent. stop() leaves
        // it holding a claim it was never told about, so that claim goes back; a sweep has
        // already given it back and cleared `task`, so there is nothing left to do then.
        guard isLive(session) else {
            if record.agent(session)?.task == task.id, record.agent(session)?.state == .done,
               await deps.backend.returnToOpen(task.id, project: project) {
                log(.released, task: task.id, session: session, detail: "claimed after \(agent.agentName) left the swarm")
                record.update(session) { $0.task = nil }
            }
            return
        }
        switch await deps.launcher.deliver(TaskPrompt.text(for: detail), to: session) {
        case .success:
            record.spawnFailures[agent.config.rawValue] = nil
            // A prompt typed into an agent stop() retired meanwhile has been sent; the agent
            // keeps its claim (stop never returns claims) but stays retired.
            guard isLive(session) else { return }
            record.update(session) { $0.state = .working; $0.stateSince = now() }
            log(.prompt, task: task.id, session: session)
        case .failure(let error):
            await deliveryFailed(session, config: agent.config, task: task.id, error: error)
        }
    }

    private func deliveryFailed(_ session: UUID, config: ConfigKey, task: String, error: SpawnError) async {
        // Spec §10: the claim goes back to open and the agent is left alone (not killed), but a
        // tab that never showed a composer is never typed into again.
        _ = await deps.backend.returnToOpen(task, project: project)
        // stop() may have retired the agent while the deliver or this give-back awaited; a retired
        // agent keeps its done state and its marker (its lease is already released).
        guard isLive(session) else { return }
        exclude(session, marker: error == .composerTimeout ? "stuck at start" : "prompt failed")
        log(error == .composerTimeout ? .stuck : .error, task: task, session: session, detail: Self.describe(error))
        // A tab that never took its prompt is a failed launch (spec §10). Counted, so a config
        // that is stuck every time pauses the swarm after three instead of opening a fresh tab
        // per slot every two minutes forever.
        noteSpawnFailure(config, error: error)
    }

    /// Idle and never reused again (spec §10). Such an agent never takes work, so its lease goes
    /// back now rather than sitting held, uncounted against the cap, until the swarm stops;
    /// `lease` is cleared so stop() does not release it a second time.
    private func exclude(_ session: UUID, marker: String) {
        if let lease = record.agent(session)?.lease { deps.allocator.release(lease.lease) }
        becomeIdle(session)
        record.update(session) { $0.excludedFromReuse = true; $0.marker = marker; $0.lease = nil }
    }

    private func noteSpawnFailure(_ key: ConfigKey, error: SpawnError) {
        let count = (record.spawnFailures[key.rawValue] ?? 0) + 1
        record.spawnFailures[key.rawValue] = count
        log(.spawnFailed, detail: "\(key): \(Self.describe(error))")
        // Spec §10: three in a row on one config pause the swarm, so a broken login or a missing
        // Agent Mail does not chew through every ready task. Only a running swarm pauses: a
        // launch that fails after stop() must not resurrect the swarm as paused.
        guard count >= SwarmTiming.spawnFailureLimit, record.state == .running else { return }
        record.state = .paused
        record.banner = "Paused: \(count) launches in a row failed for \(key) — \(Self.describe(error))"
        log(.pause, detail: record.banner ?? "")
    }

    /// Run once for a swarm restored from disk (`SwarmService` calls it). A `starting` agent or one
    /// with a `pendingClaim` was cut off before its prompt landed: any claim it holds goes back
    /// to open, because the agent never heard about the task, and the agent becomes idle.
    /// An agent whose claim cannot be read or reopened is left untouched and retried each tick.
    func reconcileAfterRestart() async {
        for agent in record.agents where agent.state == .starting || agent.pendingClaim != nil {
            await reconcileRestored(agent)
        }
        changed()
    }

    private func retryUnreconciled() async {
        for session in unreconciled {
            guard let agent = record.agent(session), agent.state == .starting || agent.pendingClaim != nil else {
                unreconciled.remove(session); continue
            }
            await reconcileRestored(agent)
        }
    }

    private func reconcileRestored(_ agent: SwarmAgentRecord) async {
        let settled = await giveBackHeldTasks(of: agent, detail: "claimed before a restart but never prompted") {
            $0.status == "in_progress" && $0.assignee == agent.agentName
        }
        guard settled else { unreconciled.insert(agent.session); return }
        unreconciled.remove(agent.session)
        // Turn Off's stop() or a sweep may have retired the agent during the reads (its lease is
        // released then): the claims it held are given back either way, but only a live agent
        // becomes idle — becoming idle would revive a retired one with a released lease.
        if isLive(agent.session) { becomeIdle(agent.session) }
        else { record.update(agent.session) { $0.pendingClaim = nil; $0.task = nil } }
    }

    /// Returns every task the agent holds (`task`, `pendingClaim`) that `shouldReopen` accepts to
    /// open. False means nothing may be concluded yet and the agent must stay untouched: a status
    /// that could not be read is never treated as "open and ours", and a reopen that failed leaves
    /// the task in_progress under that name, so clearing the record would orphan it.
    private func giveBackHeldTasks(of agent: SwarmAgentRecord, detail: String,
                                   shouldReopen: (TaskStatusReading) -> Bool) async -> Bool {
        var readings: [(task: String, reading: TaskStatusReading)] = []
        for task in Set([agent.task, agent.pendingClaim].compactMap { $0 }).sorted() {
            guard let reading = await deps.backend.status(task, project: project) else { return false }
            readings.append((task, reading))
        }
        var allReopened = true
        for (task, reading) in readings where shouldReopen(reading) {
            if await deps.backend.returnToOpen(task, project: project) {
                log(.released, task: task, session: agent.session, detail: detail)
            } else { allReopened = false }
        }
        return allReopened
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
