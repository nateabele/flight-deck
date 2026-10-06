import Combine
import Foundation
import IntakeKit

/// Where `am` and `br` are. `system` resolves them on PATH; the UI-test fixture backend points
/// them at its stubs (Task 14).
struct FlywheelToolPaths: Equatable {
    var am: String
    var br: String
    static let system = FlywheelToolPaths(am: "am", br: "br")
}

/// The L3-R/L3-U conformers a swarm routes and leases through. Nil until the integration branch
/// (or the Debug fixture backend) supplies them; without them nothing launches.
struct SwarmDependencies {
    /// A factory so no caller holds a stale router; each launch plan, spill and sheet open asks again.
    var makeRouter: () -> any Router
    var kinds: any KindRegistry
    var allocator: any PoolAllocator
    var capacity: any CapacityReader
    /// The pools the launch sheet's Override picker offers; L3-U's pool store replaces the stand-in.
    var pools: any PoolDirectory = DefaultPoolDirectory(harnesses: ["claude", "codex"])
}

/// L3-U's hand-off driver answers these; L3-S only routes the phone's decision to it.
@MainActor
protocol HandoffDecisionSink: AnyObject {
    var pendingHandoffs: Set<UUID> { get }
    func confirmHandoff(session: UUID) -> Bool
    func declineHandoff(session: UUID) -> Bool
}

/// Owns every project's swarm: the records (`swarms.json`), one controller per live swarm, the
/// clock subscription, and the API every view, the wire and L3-U's hand-off driver use.
@MainActor
final class SwarmService: ObservableObject {
    /// A tick reads three br commands; the clock beats twice a second. Five seconds is quick
    /// enough to feel fed and cheap enough for a background Mac.
    static let tickInterval: TimeInterval = 5

    @Published private(set) var revision = 0
    var onChange: (() -> Void)?
    weak var handoffDecisions: HandoffDecisionSink?
    /// L3-U's hand-off driver, run on this service's clock: called ONCE per (throttled) tick with
    /// every swarm's working agents together — paused swarms included, because pause stops new
    /// claims, not hand-offs. One call, not one per project: the driver forgets every agent
    /// missing from its argument, so a per-project call wiped the other projects' pending
    /// confirmations, declines and `.stopFailed`. Called with an empty list too, so agents that
    /// left are forgotten. A pass still running when the next tick lands is not overlapped.
    /// Set by `FlightControlComposition`.
    var onTick: (([SwarmAgentSnapshot]) async -> Void)?
    private var handoffPassRunning = false
    /// Project key → tasks a hand-off is moving between agents right now. Between the old claim
    /// going back to open and the new one landing br reads such a task as open; the controllers
    /// must neither reset its old agent for that nor claim it for anyone else.
    private var handoffTasks: [String: Set<String>] = [:]

    /// Whether a session is contested right now: wired in `init` to `contest(for:)`; a test may
    /// override it.
    var isContested: (UUID) -> Bool = { _ in false }
    /// The last guard block and BLOCKED: line per session (spec §7.4).
    private(set) var signals: [UUID: SessionSignals] = [:]
    /// The project's held reservations, from the Observe projection (wired by `SessionStore.useSwarmService`).
    var reservationsLookup: (String) -> [HeldReservation] = { _ in [] }

    let store: SwarmStore
    let backend: SwarmBackend
    let launcher: SwarmAgentLauncher
    let spawner: SwarmSpawner?
    /// Weak: the store owns the service, and the service must not own the store back.
    private(set) weak var host: SwarmHost?
    let registry: RoutingCapabilityRegistry
    private let now: () -> Date
    private weak var clock: WatchClock?

    private(set) var records: [String: SwarmRecord] = [:]
    private var controllers: [String: SwarmController] = [:]
    private var needsReconcile: Set<String> = []
    private var lastClockTick = Date.distantPast
    /// Keyed so each task can drop itself when it finishes: one starts per throttled tick and per
    /// projection change, and a list only `settle()` pruned grew without bound in a long-running app.
    private var work: [UUID: Task<Void, Never>] = [:]

    var dependencies: SwarmDependencies? {
        didSet { rebuildControllers() }
    }

    init(store: SwarmStore, backend: SwarmBackend, launcher: SwarmAgentLauncher, spawner: SwarmSpawner?,
         host: SwarmHost, registry: RoutingCapabilityRegistry, clock: WatchClock?, now: @escaping () -> Date = Date.init) {
        self.store = store; self.backend = backend; self.launcher = launcher; self.spawner = spawner
        self.host = host; self.registry = registry; self.clock = clock; self.now = now
        for record in store.restore() {
            let key = Self.key(record.project)
            records[key] = record
            if record.state != .stopped { needsReconcile.insert(key) }
        }
        isContested = { [weak self] in self?.contest(for: $0) != nil }
        clock?.add(self) { [weak self] in self?.clockTick() }
    }

    static func key(_ path: String) -> String { FlywheelObserveService.key(path) }

    func record(forProject path: String) -> SwarmRecord? { records[Self.key(path)] }
    func controller(forProject path: String) -> SwarmController? { controllers[Self.key(path)] }
    var currentTime: Date { now() }
    var allRecords: [SwarmRecord] { records.values.sorted { $0.createdAt < $1.createdAt } }

    /// At most one swarm per project (spec §2): a stopped one is replaced, a live one refuses.
    @discardableResult
    func launch(project: String, cap: Int, poolCaps: [String: Int], filter: SwarmFilter) -> SwarmRecord? {
        guard dependencies != nil else { return nil }
        let key = Self.key(project)
        if let existing = records[key], existing.state != .stopped { return nil }
        let record = SwarmRecord(id: UUID(), project: key, cap: max(1, cap), poolCaps: poolCaps, filter: filter,
                                 state: .running, agents: [], createdAt: now())
        guard let controller = makeController(record) else { return nil }
        records[key] = record
        controllers[key] = controller
        store.append(SwarmLogEntry(at: now(), kind: .launch, detail: "cap \(record.cap)"), swarm: record.id)
        persist(); publish()
        track { await controller.tick() }
        return record
    }

    @discardableResult func pause(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        c.pause(); return true
    }
    @discardableResult func resume(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        track { await c.resume() }; return true
    }
    @discardableResult func drain(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        c.drain(); return true
    }
    @discardableResult func stop(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        c.stop(reason: "stopped from the menu"); return true
    }

    /// The Observe watcher's projections. Only in-progress ids matter: a claimed task leaving
    /// that set is what `SwarmController.taskSetChanged` investigates.
    func projectionsChanged(_ projections: [String: FlywheelProjection]) {
        track { await self.applyProjections(projections) }
    }

    func applyProjections(_ projections: [String: FlywheelProjection]) async {
        for (key, projection) in projections {
            guard let controller = controllers[key] else { continue }
            let inProgress = Set(projection.beadsByID.values.filter { $0.status == "in_progress" }.map(\.id))
            await controller.taskSetChanged(inProgress: inProgress)
        }
    }

    /// Test seam: tasks this service started that have not finished.
    var pendingWorkCount: Int { work.count }

    /// Waits for every task this service started and every launch its controllers started.
    func settle() async {
        while let next = work.values.first { await next.value }
        for controller in controllers.values { await controller.settle() }
    }

    // MARK: Hand-off (consumed by L3-U's HandoffDriver)

    func agentSnapshots(project: String) -> [SwarmAgentSnapshot] {
        guard let record = record(forProject: project) else { return [] }
        let url = URL(fileURLWithPath: record.project, isDirectory: true)
        return record.agents.filter { $0.state == .working }.map { agent in
            SwarmAgentSnapshot(session: SessionRef(id: agent.session, agentName: agent.agentName), agentName: agent.agentName,
                               block: agent.block.block, lease: agent.lease?.lease,
                               task: agent.task.map { TaskRef(id: $0, project: url) })
        }
    }

    @discardableResult
    func recordHandoff(project: String, from old: UUID, to new: SessionRef, block: ExecutionBlock, lease: AccountLease?) -> Bool {
        controller(forProject: project)?.recordHandoff(from: old, to: new, block: block, lease: lease) ?? false
    }

    /// A hand-off driver returns the old agent's claim before `spawner.spawn` claims for the new one.
    func returnClaimToOpen(project: String, task: String) async -> Bool {
        await backend.returnToOpen(task, project: URL(fileURLWithPath: Self.key(project), isDirectory: true))
    }

    /// Marks `task` as moving between agents until `endHandoff` (see `handoffTasks`).
    func beginHandoff(project: String, task: String) { handoffTasks[Self.key(project), default: []].insert(task) }
    func endHandoff(project: String, task: String) {
        let key = Self.key(project)
        handoffTasks[key]?.remove(task)
        if handoffTasks[key]?.isEmpty == true { handoffTasks[key] = nil }
    }
    /// After a driver pass every hand-off it began has ended one way or another — including a
    /// `.stopFailed`, which never reaches the success hook that ends its mark.
    func endAllHandoffs() { handoffTasks = [:] }
    func isHandingOff(project: String, task: String) -> Bool { handoffTasks[Self.key(project)]?.contains(task) ?? false }

    func confirmHandoff(session: UUID) -> Bool { handoffDecisions?.confirmHandoff(session: session) ?? false }
    func declineHandoff(session: UUID) -> Bool { handoffDecisions?.declineHandoff(session: session) ?? false }

    // MARK: Internals

    /// Paused swarms tick too: `tick()` fills no slots while paused, but its restored-claim retry
    /// and closed-tab sweep must still run — and a restored swarm is always paused, so without
    /// this its unreadable claims were never retried.
    private func clockTick() {
        guard now().timeIntervalSince(lastClockTick) >= Self.tickInterval else { return }
        lastClockTick = now()
        for controller in controllers.values where controller.record.state != .stopped {
            track { await controller.tick() }
        }
        guard let onTick, !handoffPassRunning else { return }
        let agents = records.keys.sorted().flatMap { agentSnapshots(project: $0) }
        handoffPassRunning = true
        track { [weak self] in
            await onTick(agents)
            self?.handoffPassRunning = false
        }
    }

    /// Controllers are rebuilt from the records whenever the dependencies change — the records,
    /// not the controllers, are the source of truth. A restored swarm is reconciled once.
    private func rebuildControllers() {
        controllers = [:]
        guard dependencies != nil else { return }
        for (key, record) in records where record.state != .stopped {
            guard let controller = makeController(record) else { continue }
            controllers[key] = controller
            if needsReconcile.remove(key) != nil { track { await controller.reconcileAfterRestart() } }
        }
    }

    private func makeController(_ record: SwarmRecord) -> SwarmController? {
        guard let deps = dependencies else { return nil }
        let registry = self.registry
        let key = Self.key(record.project)
        let controller = SwarmController(
            record: record, store: store,
            deps: .init(backend: backend, launcher: launcher, host: WeakSwarmHost(host), makeRouter: deps.makeRouter, kinds: deps.kinds,
                        allocator: deps.allocator, capacity: deps.capacity,
                        catalogs: { await registry.catalogs(enabled: Set(registry.harnesses)) }, pools: deps.pools,
                        inHandoff: { [weak self] task in self?.handoffTasks[key]?.contains(task) ?? false }),
            now: now)
        // A rebuild orphans the old controller, which may still have launches in flight; only
        // the controller the service currently owns may write the record.
        controller.onChange = { [weak self, weak controller] updated in
            guard let self, let controller, self.controllers[Self.key(updated.project)] === controller else { return }
            self.records[Self.key(updated.project)] = updated
            self.persist()
            self.publish()
        }
        return controller
    }

    /// The task cannot finish before it is filed: both run on the main actor, and this function
    /// does not suspend between creating it and storing it.
    private func track(_ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        work[id] = Task { [weak self] in
            await body()
            self?.work[id] = nil
        }
    }

    private func persist() { store.save(allRecords) }

    private func publish() {
        revision += 1
        onChange?()
    }
}

/// What controllers hold instead of the host itself: a controller is owned by the service, which
/// the store owns, so a strong reference back to the store would be a retain cycle. A host that
/// is gone answers as a store with no tabs.
@MainActor
private final class WeakSwarmHost: SwarmHost {
    private weak var host: SwarmHost?
    init(_ host: SwarmHost?) { self.host = host }
    func sessionExists(_ id: UUID) -> Bool { host?.sessionExists(id) ?? false }
    func isAgentIdle(_ id: UUID) -> Bool { host?.isAgentIdle(id) ?? false }
    func wakeIfAsleep(_ id: UUID) { host?.wakeIfAsleep(id) }
    func lastActiveAt(for id: UUID) -> Date? { host?.lastActiveAt(for: id) }
    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)] {
        host?.flywheelAgents(inProject: project) ?? []
    }
}

extension SwarmService {
    func recordSignals(_ new: [AgentOutputSignal], session: UUID) {
        guard !new.isEmpty else { return }
        var current = signals[session] ?? SessionSignals()
        for signal in new {
            switch signal {
            case .guardBlock(let block): current.guardBlock = block; current.guardBlockAt = now()
            case .blocked(let text): current.blocked = text; current.blockedAt = now()
            }
        }
        signals[session] = current
        objectWillChange.send()
        onChange?()
    }

    func contest(for session: UUID) -> Contest? {
        guard let signals = signals[session], let (record, agent) = agentRecord(session) else { return nil }
        return ContestedRelation.contest(agent: agent.agentName, signals: signals,
                                         reservations: reservationsLookup(Self.key(record.project)), now: currentTime)
    }

    /// Agent name to contest, for every flywheel tab in the project: the Observe enrichment's input.
    func contests(project: String) -> [String: Contest] {
        let key = Self.key(project)
        var out: [String: Contest] = [:]
        for (session, name) in host?.flywheelAgents(inProject: key) ?? [] {
            guard let s = signals[session],
                  let c = ContestedRelation.contest(agent: name, signals: s, reservations: reservationsLookup(key), now: currentTime)
            else { continue }
            out[name] = c
        }
        return out
    }

    /// Agents that said BLOCKED: and have not started working since: the notifier's block trigger.
    func declaredBlocked(project: String) -> Set<String> {
        Set((host?.flywheelAgents(inProject: Self.key(project)) ?? []).compactMap { session, name in
            guard signals[session]?.blocked != nil, host?.isAgentIdle(session) == true else { return nil }
            return name
        })
    }
}

extension SwarmService {
    /// Spec §9 steps 1–2: drain then stop the project's swarm, then return to open every task it
    /// claimed that is not closed. Returns those ids. Agents keep running in their tabs.
    ///
    /// A status that cannot be read is not "not closed": it is left alone, as is a task whose
    /// return-to-open failed (it is not reported as reopened), so a br hiccup never reopens work
    /// that finished and never claims a reopen that did not happen.
    ///
    /// The claims are read from the record, not a controller: after a relaunch with no routing
    /// dependencies there is no controller, and Turn Off must still give back what the swarm
    /// took. Without one, the record is stopped directly so a later launch does not restore it;
    /// its leases belong to an allocator this run never had.
    func turnOff(project: String) async -> [String] {
        let key = Self.key(project)
        guard let record = records[key] else { return [] }
        let url = URL(fileURLWithPath: key, isDirectory: true)
        let held = Set(record.agents.flatMap { [$0.task, $0.pendingClaim].compactMap { $0 } })
        if let controller = controllers[key] {
            controller.drain()
            controller.stop(reason: "Flight Control turned off")
        } else if record.state != .stopped {
            var stopped = record
            stopped.state = .stopped
            for agent in stopped.agents where agent.state != .done && agent.state != .handedOff {
                stopped.update(agent.session) { $0.state = .done; $0.stateSince = now() }
            }
            records[key] = stopped
            store.append(SwarmLogEntry(at: now(), kind: .stop, detail: "Flight Control turned off"), swarm: record.id)
            persist(); publish()
        }
        var reopened: [String] = []
        for task in held.sorted() {
            guard let reading = await backend.status(task, project: url), reading.status != "closed" else { continue }
            if await backend.returnToOpen(task, project: url) { reopened.append(task) }
        }
        store.append(SwarmLogEntry(at: now(), kind: .released, detail: "returned to open: \(reopened.joined(separator: ", "))"),
                     swarm: record.id)
        return reopened
    }
}
