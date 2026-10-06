import Foundation
import IntakeKit

/// Builds the real Level 3 graph once and installs it on the store. Each branch shipped with a
/// stand-in for its siblings (`NullCapabilityIndex`, `NoRuleHints`, `DefaultPoolDirectory`, a nil
/// `swarmDependencies`, no hand-off driver); this is the only place those stand-ins are replaced,
/// so "which real thing talks to which" can be read in one file.
///
/// Called once by `FlightDeckApp.makeStore`, after the routing service and the capability index
/// exist. It does not need `UsageService` to be attached first: everything it takes from usage
/// (the ledger, the planner, the swarm predicate) is read lazily, and attach keeps the predicate.
@MainActor
enum FlightControlComposition {
    @discardableResult
    static func install(on store: SessionStore, preferences: PreferencesStore,
                        usage: UsageService = .shared) -> FlightControlGraph? {
        install(on: store, preferences: preferences, usage: usage,
                // The store's tool paths, not PATH's: under the Debug fixture backend `br`/`am`
                // are its stubs, and a hand-off must not reach the real ones.
                commands: BrAmHandoffCommands(brPath: store.flywheelTools.br, amPath: store.flywheelTools.am),
                logURL: StoreHandoffHost.defaultLogURL, allocator: usage.ledger, now: Date.init)
    }

    /// The seams a test replaces: the `br`/`am` runner, where the hand-off log goes, the
    /// allocator (a counting wrapper over the real ledger) and the clock.
    @discardableResult
    static func install(on store: SessionStore, preferences: PreferencesStore, usage: UsageService,
                        commands: BrAmHandoffCommands, logURL: URL,
                        allocator: any PoolAllocator & CapacityReader,
                        now: @escaping () -> Date) -> FlightControlGraph? {
        if let installed = store.flightControlGraph { return installed }
        // Without routing there is nothing to route or spill with; a store a test built bare.
        guard let routing = store.flightControlRouting else { return nil }

        // Routing: the pools in force (one `<agent>-default` per agent with a live account, then
        // the stored pools) — never the stored list alone, which is empty on a fresh install and
        // would make every task unroutable.
        let ledger = usage.ledger
        let pools = CapacityPoolDirectory { [weak preferences] in
            // Read on the main actor in practice (every router user is). A Router is Sendable,
            // though, so an off-main read answers from the ledger, which `UsageService` configures
            // from these same effective pools on every preferences change.
            guard Thread.isMainThread else { return ledger.allPools }
            return MainActor.assumeIsolated {
                guard let preferences else { return ledger.allPools }
                return preferences.capacity.effectivePools(accounts: preferences.preferences.accounts)
            }
        }
        routing.pools = pools
        if let indexService = store.capabilityIndexService {
            let live = indexService.live
            routing.index = live
            // The overlaid scores `live` ranks with, and the snapshot they came from, so a
            // dismissed hint comes back only when the index moves.
            routing.hints = CapabilityRuleHintSource {
                let current = live.current
                guard let date = current.snapshotDate else { return nil }
                return (current.scores, date)
            }
        }

        // Swarm: routes through L3-R, leases through L3-U. `makeRouter` asks the service every
        // time — it snapshots the rules, so a cached router would route on stale rules.
        store.swarmDependencies = SwarmDependencies(makeRouter: { routing.makeRouter() }, kinds: routing.kindStore,
                                                    allocator: allocator, capacity: allocator, pools: pools,
                                                    // Settings' enabled agents, like release and validation: not every registered harness.
                                                    catalogs: { [weak routing] in await routing?.catalogs() ?? AdapterCatalogs([]) })

        // Usage: which tabs are swarm agents, so manual tabs alone get the over-limit notice.
        // Never builds the lazy swarm service: a Mac that never ran a swarm has no swarm tabs.
        usage.setSwarmPredicate { [weak store] id in store?.swarmServiceIfBuilt?.agentRecord(id) != nil }

        let graph = FlightControlGraph(store: store, preferences: preferences, routing: routing, usage: usage,
                                       allocator: allocator, commands: commands, logURL: logURL, now: now)
        store.flightControlGraph = graph
        if let swarm = store.swarmServiceIfBuilt { graph.attach(swarm: swarm) }
        return graph
    }
}

/// What `install` leaves behind: the hand-off half, which can only be built once the (lazy) swarm
/// service exists — `SessionStore.useSwarmService` calls `attach` when it does. The store holds
/// this strongly; the swarm holds the driver weakly.
@MainActor
final class FlightControlGraph {
    let routing: RoutingService
    let usage: UsageService
    private(set) var host: StoreHandoffHost?
    private(set) var driver: HandoffDriver?
    /// `CapacityPreferences.confirmSurfaceExists`, settable so a test can drive the driver's
    /// confirmation machinery, which production keeps off until something can answer it.
    var confirmSurfaceExists = CapacityPreferences.confirmSurfaceExists

    private weak var store: SessionStore?
    private weak var preferences: PreferencesStore?
    private weak var attached: SwarmService?
    private let allocator: any PoolAllocator
    private let commands: BrAmHandoffCommands
    private let logURL: URL
    private let now: () -> Date

    init(store: SessionStore, preferences: PreferencesStore, routing: RoutingService, usage: UsageService,
         allocator: any PoolAllocator, commands: BrAmHandoffCommands, logURL: URL, now: @escaping () -> Date) {
        self.store = store; self.preferences = preferences; self.routing = routing; self.usage = usage
        self.allocator = allocator; self.commands = commands; self.logURL = logURL; self.now = now
    }

    /// L3-U's driver over L3-S's spawner and records. Once per service.
    func attach(swarm: SwarmService) {
        guard attached !== swarm, let store, let spawner = swarm.spawner else { return }
        attached = swarm
        let routing = self.routing

        let host = StoreHandoffHost(store: store, commands: commands, logURL: logURL)
        host.kindLookup = { [weak routing] block, project in routing?.kind(for: block, project: project) }
        host.catalogProvider = { [weak routing] in await routing?.catalogs() ?? AdapterCatalogs([]) }
        // What the old agent holds, from the same Observe projection the swarm reads. Nil (keep
        // the planner's list) only when there is no swarm to ask.
        host.reservationLookup = { [weak swarm] agent, project in
            guard let swarm else { return nil }
            return swarm.reservationsLookup(SwarmService.key(project.path)).filter { $0.holder == agent }.map(\.pattern)
        }
        let allocator = self.allocator
        let now = self.now
        host.onHandedOff = { [weak swarm, weak host] done in
            // The task is recorded on the new agent now (or never will be): it stops being "in
            // hand-off" either way.
            defer { swarm?.endHandoff(project: done.task.project.path, task: done.task.id) }
            guard let swarm, !swarm.recordHandoff(project: done.task.project.path, from: done.old.id, to: done.new,
                                                  block: done.block, lease: done.lease) else { return }
            // Refused: the new session has no name, or the swarm no longer holds the old agent
            // (stopped or swept mid-hand-off). The new agent runs with the task but outside the
            // swarm. Its lease is released: no record holds it, so nothing (stop, the sweep, a
            // later hand-off) would ever release it, and a lease held forever takes a slot out
            // of a local pool for the life of the app. The agent itself keeps running; a hosted
            // account's capacity follows its readings, not its leases.
            allocator.release(done.lease)
            host?.record(HandoffLogEntry(at: now(), outcome: .unrecorded, task: done.task.id, oldSession: done.old.id,
                                         oldAgent: done.old.agentName ?? "", newSession: done.new.id,
                                         newAgent: done.new.agentName, fromAccount: done.fromAccount.label,
                                         toAccount: done.lease.account.label,
                                         detail: "the swarm could not record the new agent; it runs outside the swarm"))
            host?.notify(title: "Hand-off not recorded",
                         body: "\(done.new.agentName ?? "The new agent") took task \(done.task.id), but the swarm could not record it, so Flight Control will not manage that tab. Check it in its tab.",
                         session: done.new)
        }

        let driver = HandoffDriver(
            planner: usage.planner, allocator: allocator,
            router: FreshRouter { MainActor.assumeIsolated { routing.makeRouter() } },
            spawner: HandoffClaimSpawner(inner: spawner, swarm: swarm), host: host,
            settings: { [weak self, weak preferences] in
                (preferences?.capacity ?? CapacityPreferences())
                    .handoffSettings(confirmSurfaceExists: self?.confirmSurfaceExists ?? CapacityPreferences.confirmSurfaceExists)
            },
            now: now)
        swarm.handoffDecisions = driver
        // One pass over every swarm's working agents (see `SwarmService.onTick`). Every hand-off
        // the pass began has finished when `evaluate` returns, and passes never overlap, so any
        // mark still set (a path that returned before `onHandedOff`) is cleared here.
        swarm.onTick = { [weak swarm, weak driver] agents in
            guard let driver else { return }
            await driver.evaluate(agents)
            swarm?.endAllHandoffs()
        }
        self.host = host
        self.driver = driver
    }
}

/// A `Router` that asks the routing service for a fresh one on every call. `HandoffDriver` stores
/// its router once, and `RoutingService.makeRouter()` snapshots the rules: a router built at
/// install would spill on the rules of that moment forever.
private struct FreshRouter: Router {
    let make: @Sendable () -> any Router
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        make().assign(kind: kind, project: project, catalogs: catalogs, now: now)
    }
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment? {
        make().spill(block, kind: kind, project: project, exhausted: exhausted, catalogs: catalogs, now: now)
    }
}

/// The hand-off's spawn, given back the old agent's claim first. The old agent holds the task in
/// br (`in_progress`, assigned to it), and the spawner's `br update --claim` for the new agent
/// is refused as a conflict while it does — so without this every hand-off failed.
///
/// The task is marked "in hand-off" on the swarm before the claim goes back: from then until the
/// new agent is recorded, br reads it as open, and the swarm must neither treat that as "back to
/// open" (resetting the old agent, so the new one would be recorded with no task) nor claim it for
/// another agent. The mark ends in `onHandedOff`, here on a failed spawn, or after the pass.
///
/// If the spawn fails (the spawner has closed any tab it opened), the claim is returned to open
/// and then goes back to the agent the swarm records as holding the task:
/// the driver's promise is that a failed spawn leaves the old agent running and still assigned.
/// The holder comes from the swarm's record, not a br read, so an unreadable br cannot lose it.
/// No holder means the swarm already let the task go (stopped or swept): nobody to give it to,
/// and an open task is then the right state. A claim-back refused because someone outside the
/// swarm took the task in that moment is left to `taskSetChanged`, which sees it taken over.
@MainActor
private final class HandoffClaimSpawner: SwarmSpawner {
    private let inner: SwarmSpawner
    private weak var swarm: SwarmService?

    init(inner: SwarmSpawner, swarm: SwarmService) { self.inner = inner; self.swarm = swarm }

    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
        guard let swarm else { return .failure(.launchFailed("the swarm is gone")) }
        let project = task.project.path
        let holder = swarm.record(forProject: project)?.agents
            .first { $0.task == task.id && ($0.state == .working || $0.state == .idle) }?.agentName
        swarm.beginHandoff(project: project, task: task.id)
        _ = await swarm.returnClaimToOpen(project: project, task: task.id)
        let result = await inner.spawn(task: task, block: block, lease: lease, firstPrompt: firstPrompt)
        if case .failure = result {
            if let holder {
                // Back to open first: a spawn that failed after its own claim landed (the prompt
                // never arrived) left the task claimed by the new agent, whose tab the spawner
                // has closed. Claiming back over that claim conflicts, and the task stayed with
                // an agent that no longer exists while the swarm still recorded the old one.
                _ = await swarm.returnClaimToOpen(project: project, task: task.id)
                _ = await swarm.backend.claim(task.id, actor: holder, project: task.project)
            }
            swarm.endHandoff(project: project, task: task.id)
        }
        return result
    }
}
