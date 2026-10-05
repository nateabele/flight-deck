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
    private var work: [Task<Void, Never>] = []

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
        clock?.add(self) { [weak self] in self?.clockTick() }
    }

    static func key(_ path: String) -> String { FlywheelObserveService.key(path) }

    func record(forProject path: String) -> SwarmRecord? { records[Self.key(path)] }
    func controller(forProject path: String) -> SwarmController? { controllers[Self.key(path)] }
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

    /// Waits for every task this service started and every launch its controllers started.
    func settle() async {
        while !work.isEmpty {
            let pending = work; work = []
            for task in pending { await task.value }
        }
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

    func confirmHandoff(session: UUID) -> Bool { handoffDecisions?.confirmHandoff(session: session) ?? false }
    func declineHandoff(session: UUID) -> Bool { handoffDecisions?.declineHandoff(session: session) ?? false }

    // MARK: Internals

    private func clockTick() {
        guard now().timeIntervalSince(lastClockTick) >= Self.tickInterval else { return }
        lastClockTick = now()
        for controller in controllers.values where controller.record.state == .running || controller.record.state == .draining {
            track { await controller.tick() }
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
        let controller = SwarmController(
            record: record, store: store,
            deps: .init(backend: backend, launcher: launcher, host: WeakSwarmHost(host), makeRouter: deps.makeRouter, kinds: deps.kinds,
                        allocator: deps.allocator, capacity: deps.capacity,
                        catalogs: { await registry.catalogs(enabled: Set(registry.harnesses)) }),
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

    private func track(_ body: @escaping @MainActor () async -> Void) {
        work.append(Task { await body() })
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
