import Foundation

/// The five Level 3 specs meet only here. Each branch implements its own protocols and tests
/// against fakes of the others; integration swaps the fakes for real conformers.

/// Owned by L3-R. Backed by `.flightdeck/kinds.json`.
public protocol KindRegistry: Sendable {
    func kinds(project: URL) throws -> [TaskKind]
    /// Adds a proposal, or returns the existing kind whose id the name normalizes to.
    func propose(_ kind: TaskKind, project: URL) throws -> TaskKind
}

/// Owned by L3-R. Pure: no I/O, no clock beyond `now`.
public protocol Router: Sendable {
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment
    /// Re-routes with `exhausted` pools removed, for one spawn. Nil when the block is pinned or
    /// nothing else fits. Never rewrites the stored block.
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment?
}

/// Owned by L3-U (its pool store conforms; `DefaultPoolDirectory` stands in until then).
public protocol PoolDirectory: Sendable {
    func pools() -> [PoolSummary]
    func defaultPool(for harness: HarnessID) -> PoolID?
}

/// One `<harness>-default` pool per agent — L3-U §2's default pools, which exist before anyone
/// configures capacity. Enough for routing to run end to end before L3-U's pool store conforms.
public struct DefaultPoolDirectory: PoolDirectory {
    public let harnesses: [HarnessID]
    public init(harnesses: [HarnessID]) { self.harnesses = harnesses }
    public func pools() -> [PoolSummary] {
        harnesses.map { PoolSummary(id: PoolID("\($0.rawValue)-default"), harness: $0, label: "\($0.rawValue) — all accounts") }
    }
    public func defaultPool(for harness: HarnessID) -> PoolID? {
        harnesses.contains(harness) ? PoolID("\(harness.rawValue)-default") : nil
    }
}

/// Owned by L3-I.
public protocol CapabilityIndex: Sendable {
    /// Best first. Unknown models are omitted, never scored zero.
    func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel]
    var snapshotDate: Date? { get }
}

/// Owned by L3-U.
public protocol CapacityReader: Sendable {
    /// In pool order.
    func headroom(pool: PoolID) -> [AccountHeadroom]
}

/// Owned by L3-U. First account in order under soft, then the first unknown, else nil.
public protocol PoolAllocator: Sendable {
    func lease(pool: PoolID) -> AccountLease?
    func release(_ lease: AccountLease)
}

/// Owned by L3-U. Nil when the agent's account is not over hard.
public protocol HandoffPlanner: Sendable {
    func request(for agent: SwarmAgentSnapshot) -> HandoffRequest?
}

/// Owned by L3-U; one per (adapter, account) or per session, as the adapter provides.
public protocol UsageMeterSource: Sendable {
    var readings: AsyncStream<UsageReading> { get }
}
