import Foundation
import IntakeKit
@testable import FlightDeck

/// One ordered log shared by the L3-S fakes, so a test can assert the ORDER of side effects
/// across the backend and the launcher — "release" before "reset" is a Review Focus item.
@MainActor
final class SwarmCallLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
    func index(of entry: String) -> Int? { entries.firstIndex(of: entry) }
}

/// br/am as a scripted table. A successful claim takes the task out of `ready`, as br does.
@MainActor
final class FakeSwarmBackend: SwarmBackend {
    let log: SwarmCallLog
    var ready: [ReadyTask] = []
    var readyFails = false
    /// Tasks whose `writeBlock` fails (and records nothing).
    var writeFails: Set<String> = []
    var claimResults: [String: ClaimOutcome] = [:]
    /// Runs inside `releaseReservations`, so a test can act while a reuse is mid-flight.
    var onReleaseReservations: (() -> Void)?
    /// Runs inside `claim`, before its outcome is returned, so a test can stop the swarm mid-claim.
    var onClaim: ((String) -> Void)?
    /// Runs inside `status`, before the reading is returned. Async so a test can run a whole
    /// tick inside another path's await, which is how two controller paths interleave live.
    var onStatus: ((String) async -> Void)?
    var statuses: [String: TaskStatusReading] = [:]
    /// Tasks whose `returnToOpen` fails (leaving the status untouched) until the test clears them.
    var returnToOpenFails: Set<String> = []
    var details: [String: TaskDetail] = [:]
    struct ClaimCall: Equatable { let task: String; let actor: String }
    struct WriteCall: Equatable { let task: String; let block: ExecutionBlock }
    private(set) var readyCalls = 0
    private(set) var claims: [ClaimCall] = []
    private(set) var returned: [String] = []
    private(set) var released: [String] = []
    private(set) var written: [WriteCall] = []

    init(log: SwarmCallLog) { self.log = log }

    func readyTasks(project: URL) async -> Result<[ReadyTask], SwarmBackendError> {
        readyCalls += 1
        return readyFails ? .failure(SwarmBackendError(message: "br ready failed")) : .success(ready)
    }
    func taskDetail(_ id: String, project: URL) async -> TaskDetail? { details[id] }
    func status(_ id: String, project: URL) async -> TaskStatusReading? {
        await onStatus?(id)
        return statuses[id]
    }
    func claim(_ id: String, actor: String, project: URL) async -> ClaimOutcome {
        claims.append(ClaimCall(task: id, actor: actor)); log.add("claim \(id) \(actor)")
        onClaim?(id)
        let outcome = claimResults[id] ?? .claimed
        if outcome == .claimed {
            statuses[id] = TaskStatusReading(status: "in_progress", assignee: actor)
            ready.removeAll { $0.id == id }
        }
        return outcome
    }
    func returnToOpen(_ id: String, project: URL) async -> Bool {
        if returnToOpenFails.contains(id) { return false }
        returned.append(id); log.add("open \(id)")
        statuses[id] = TaskStatusReading(status: "open", assignee: nil)
        return true
    }
    func writeBlock(_ block: ExecutionBlock, task: String, existingContext: String?, project: URL) async -> Bool {
        if writeFails.contains(task) { return false }
        written.append(WriteCall(task: task, block: block)); return true
    }
    func releaseReservations(agent: String, project: URL) async -> Bool {
        released.append(agent); log.add("release \(agent)"); onReleaseReservations?(); return true
    }
}

/// The spawner as a script. With nothing scripted, a creation succeeds as `Agent<n>`.
@MainActor
final class FakeSwarmAgentLauncher: SwarmAgentLauncher {
    let log: SwarmCallLog
    var createResults: [Result<SessionRef, SpawnError>] = []
    var deliverFailures: [UUID: SpawnError] = [:]
    var resetResults: [UUID: Bool] = [:]
    var onCreate: ((SessionRef) -> Void)?
    /// Runs at the start of every `createAgent`, success or not.
    var onCreateAttempt: (() -> Void)?
    /// Runs inside `resetContext`, before its result is returned.
    var onReset: (() -> Void)?
    /// Runs inside `deliver`, before its result is returned.
    var onDeliver: (() -> Void)?
    /// Structs rather than tuples so tests can map them with key paths.
    struct CreateCall { let task: String; let block: ExecutionBlock; let lease: AccountLease? }
    struct DeliverCall { let session: UUID; let prompt: String }
    private(set) var created: [CreateCall] = []
    private(set) var delivered: [DeliverCall] = []
    private(set) var resets: [UUID] = []
    private var names: [UUID: String] = [:]

    init(log: SwarmCallLog) { self.log = log }

    /// A session the test placed in the record itself, so the log can name it.
    func register(_ ref: SessionRef) { names[ref.id] = ref.agentName }
    func name(_ id: UUID) -> String { names[id] ?? "?" }

    func createAgent(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async -> Result<SessionRef, SpawnError> {
        created.append(CreateCall(task: task.id, block: block, lease: lease))
        onCreateAttempt?()
        let result = createResults.isEmpty
            ? .success(SessionRef(id: UUID(), agentName: "Agent\(created.count)"))
            : createResults.removeFirst()
        if case .success(let ref) = result {
            register(ref); onCreate?(ref); log.add("create \(task.id) \(ref.agentName ?? "?")")
        } else {
            log.add("create-failed \(task.id)")
        }
        return result
    }
    func deliver(_ prompt: String, to session: UUID) async -> Result<Void, SpawnError> {
        delivered.append(DeliverCall(session: session, prompt: prompt)); log.add("prompt \(name(session))")
        onDeliver?()
        if let error = deliverFailures[session] { return .failure(error) }
        return .success(())
    }
    func resetContext(_ session: UUID) async -> Bool {
        resets.append(session); log.add("reset \(name(session))")
        onReset?()
        return resetResults[session] ?? true
    }
}

@MainActor
final class FakeSwarmHost: SwarmHost {
    let log: SwarmCallLog
    var existing: Set<UUID> = []
    var busy: Set<UUID> = []
    var activity: [UUID: Date] = [:]
    var agentsByProject: [String: [(session: UUID, agentName: String)]] = [:]
    private(set) var woken: [UUID] = []
    init(log: SwarmCallLog) { self.log = log }
    func sessionExists(_ id: UUID) -> Bool { existing.contains(id) }
    func isAgentIdle(_ id: UUID) -> Bool { existing.contains(id) && !busy.contains(id) }
    func wakeIfAsleep(_ id: UUID) { woken.append(id); log.add("wake") }
    func lastActiveAt(for id: UUID) -> Date? { activity[id] }
    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)] { agentsByProject[project] ?? [] }
}

enum SwarmFixtures {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static let project = "/tmp/swarm-project"

    static func block(_ pool: PoolID = "codex-subs", model: String = "gpt-6-sol", kind: KindID = "tests",
                      pinned: Bool = false, harness: HarnessID = "codex") -> ExecutionBlock {
        ExecutionBlock(kind: kind, harness: harness, model: model, pool: pool,
                       source: AssignmentSource(by: pinned ? .manual : .rule, reason: "fixture", at: at), pinned: pinned)
    }

    static func task(_ id: String, _ block: ExecutionBlock?, title: String? = nil) -> ReadyTask {
        ReadyTask(id: id, title: title ?? "Task \(id)", priority: 2, rank: nil,
                  agentContext: block.flatMap { try? ExecutionBlockCodec.encode($0, into: nil) })
    }

    static func lease(_ pool: PoolID, _ label: String, harness: HarnessID = "codex") -> AccountLease {
        AccountLease(pool: pool, account: AccountRef(harness: harness, id: UUID(), label: label))
    }
}

/// Everything a controller needs, wired to fakes, with a settable clock.
@MainActor
final class SwarmRig {
    let log = SwarmCallLog()
    let backend: FakeSwarmBackend
    let launcher: FakeSwarmAgentLauncher
    let host: FakeSwarmHost
    let router = FakeRouter()
    let kinds = FakeKindRegistry()
    let allocator = FakePoolAllocator()
    let capacity = FakeCapacityReader()
    let store: SwarmStore
    var now = SwarmFixtures.at
    var catalogs = AdapterCatalogs([])
    /// The pools Settings defines, for the deleted-pool check; nil skips it.
    var pools: (any PoolDirectory)?
    /// Tasks a hand-off is moving right now.
    var inHandoff: Set<String> = []
    /// Runs when the controller asks for catalogs, so a test can act inside `plan`'s await.
    var onCatalogs: (() -> Void)?
    var projectURL: URL { URL(fileURLWithPath: SwarmFixtures.project, isDirectory: true) }

    init() {
        backend = FakeSwarmBackend(log: log)
        launcher = FakeSwarmAgentLauncher(log: log)
        host = FakeSwarmHost(log: log)
        store = SwarmStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("swarm-rig-\(UUID().uuidString)"))
        kinds.byProject[projectURL] = SeedKinds.all(createdAt: SwarmFixtures.at)
        launcher.onCreate = { [host] ref in host.existing.insert(ref.id) }
    }

    var deps: SwarmController.Dependencies {
        let catalogs = self.catalogs
        return .init(backend: backend, launcher: launcher, host: host, makeRouter: { [router] in router }, kinds: kinds,
                     allocator: allocator, capacity: capacity,
                     catalogs: { [weak self] in self?.onCatalogs?(); return catalogs }, pools: pools,
                     inHandoff: { [weak self] in self?.inHandoff.contains($0) ?? false })
    }

    @discardableResult
    func leases(_ pool: PoolID, _ count: Int) -> [AccountLease] {
        let made = (1...count).map { SwarmFixtures.lease(pool, "Acct \($0)") }
        allocator.leases[pool, default: []] += made
        return made
    }

    func record(cap: Int = 3, poolCaps: [String: Int] = [:], filter: SwarmFilter = .allReady,
                state: SwarmState = .running, agents: [SwarmAgentRecord] = []) -> SwarmRecord {
        SwarmRecord(id: UUID(), project: SwarmFixtures.project, cap: cap, poolCaps: poolCaps, filter: filter,
                    state: state, agents: agents, createdAt: SwarmFixtures.at)
    }

    func controller(_ record: SwarmRecord) -> SwarmController {
        SwarmController(record: record, store: store, deps: deps, now: { [unowned self] in self.now })
    }

    /// An agent already in the swarm whose tab exists.
    func agent(_ name: String, block: ExecutionBlock = SwarmFixtures.block(), lease: AccountLease? = nil,
               state: SwarmAgentState = .idle, task: String? = nil) -> SwarmAgentRecord {
        let id = UUID()
        host.existing.insert(id)
        launcher.register(SessionRef(id: id, agentName: name))
        return SwarmAgentRecord(session: id, agentName: name, block: block, lease: lease, task: task,
                                state: state, stateSince: SwarmFixtures.at)
    }

    /// One tick plus every launch it started.
    func run(_ controller: SwarmController) async {
        await controller.tick()
        await controller.settle()
    }
}
