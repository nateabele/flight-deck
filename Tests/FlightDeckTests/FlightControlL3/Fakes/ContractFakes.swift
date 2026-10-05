import Foundation
import IntakeKit

/// Scriptable doubles for every Level 3 protocol. Shared by all four parallel branches, so keep
/// them dumb: each returns what it was scripted with and records what it was asked.

final class FakeKindRegistry: KindRegistry, @unchecked Sendable {
    private let lock = NSLock()
    var byProject: [URL: [TaskKind]] = [:]
    private(set) var proposals: [TaskKind] = []
    func kinds(project: URL) throws -> [TaskKind] {
        lock.lock(); defer { lock.unlock() }
        return byProject[project] ?? []
    }
    func propose(_ kind: TaskKind, project: URL) throws -> TaskKind {
        lock.lock(); defer { lock.unlock() }
        proposals.append(kind)
        if let existing = byProject[project]?.first(where: { $0.id == kind.id }) { return existing }
        byProject[project, default: []].append(kind)
        return kind
    }
}

final class FakeRouter: Router, @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by kind id. Falls back to `defaultAssignment`.
    var assignments: [KindID: Assignment] = [:]
    var defaultAssignment: Assignment?
    var spills: [KindID: Assignment] = [:]
    private(set) var assignCalls: [KindID] = []
    private(set) var spillCalls: [(KindID, Set<PoolID>)] = []
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        lock.lock(); defer { lock.unlock() }
        assignCalls.append(kind.id)
        guard let a = assignments[kind.id] ?? defaultAssignment else { fatalError("FakeRouter: no assignment scripted for \(kind.id)") }
        return a
    }
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment? {
        lock.lock(); defer { lock.unlock() }
        spillCalls.append((kind.id, exhausted)); return block.pinned ? nil : spills[kind.id]
    }
}

final class FakeCapabilityIndex: CapabilityIndex, @unchecked Sendable {
    private let lock = NSLock()
    var scores: [ModelRef: ScoredModel] = [:]
    var snapshotDate: Date?
    func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] {
        lock.lock(); defer { lock.unlock() }
        return candidates.compactMap { scores[$0] }.sorted { $0.score > $1.score }
    }
}

final class FakeCapacityReader: CapacityReader, @unchecked Sendable {
    private let lock = NSLock()
    var byPool: [PoolID: [AccountHeadroom]] = [:]
    func headroom(pool: PoolID) -> [AccountHeadroom] {
        lock.lock(); defer { lock.unlock() }
        return byPool[pool] ?? []
    }
}

final class FakePoolAllocator: PoolAllocator, @unchecked Sendable {
    private let lock = NSLock()
    /// Each scripted lease is handed out once, in order.
    var leases: [PoolID: [AccountLease]] = [:]
    private(set) var released: [AccountLease] = []
    private(set) var leaseCalls: [PoolID] = []
    func lease(pool: PoolID) -> AccountLease? {
        lock.lock(); defer { lock.unlock() }
        leaseCalls.append(pool)
        guard var queue = leases[pool], !queue.isEmpty else { return nil }
        let l = queue.removeFirst(); leases[pool] = queue; return l
    }
    func release(_ lease: AccountLease) {
        lock.lock(); defer { lock.unlock() }
        released.append(lease)
    }
}

final class FakeHandoffPlanner: HandoffPlanner, @unchecked Sendable {
    private let lock = NSLock()
    var requests: [UUID: HandoffRequest] = [:]
    func request(for agent: SwarmAgentSnapshot) -> HandoffRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests[agent.session.id]
    }
}

final class FakeUsageMeterSource: UsageMeterSource, @unchecked Sendable {
    let readings: AsyncStream<UsageReading>
    private let continuation: AsyncStream<UsageReading>.Continuation
    init() {
        var cont: AsyncStream<UsageReading>.Continuation?
        readings = AsyncStream { continuation in cont = continuation }
        continuation = cont!
    }
    func send(_ r: UsageReading) { continuation.yield(r) }
    func finish() { continuation.finish() }
}
