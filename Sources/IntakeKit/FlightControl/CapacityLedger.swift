import Foundation

/// The single owner of capacity state: pools, the newest meter reading and any standing
/// rejection per account, source errors, and active leases. It is the real `CapacityReader`
/// and `PoolAllocator` (L3-0); the app feeds it, L3-S and the hand-off driver read it.
///
/// A class behind a lock rather than a `@MainActor` app object because the contract protocols
/// are `Sendable` and non-isolated: a main-actor conformer would only satisfy them by
/// pretending. Every public method takes the lock once and does no I/O under it.
public final class CapacityLedger: CapacityReader, PoolAllocator, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var pools: [CapacityPool] = []
    private var refs: [UUID: AccountRef] = [:]
    private var meters: [UUID: UsageReading] = [:]
    private var rejections: [UUID: Rejection] = [:]
    private var errors: [UUID: String] = [:]
    private var active: [UUID: AccountLease] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// `accounts` includes tombstoned ones on purpose: a running tab on a removed account still
    /// reports, and its reading must land under the id it always had. Pools are what decide
    /// which accounts can be leased.
    public func configure(pools: [CapacityPool], accounts: [AccountRef]) {
        lock.withLock {
            self.pools = pools
            refs = Dictionary(accounts.compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        }
    }

    public var allPools: [CapacityPool] { lock.withLock { pools } }
    public func pool(_ id: PoolID) -> CapacityPool? { lock.withLock { pools.first { $0.id == id } } }

    public func ingest(_ reading: UsageReading) {
        guard let id = reading.account.id else { return }
        lock.withLock {
            if reading.hardRejection {
                rejections[id] = Rejection(at: reading.readAt, until: reading.worstWindow?.resetsAt, source: reading.source)
                return
            }
            if let current = meters[id], current.readAt > reading.readAt { return }
            meters[id] = reading
            errors[id] = nil
            // "The state clears … with the next reading that is below hard" (L3-U §3). Below the
            // strictest hard threshold of any pool holding the account, so lifting it in a lax
            // pool can never re-open it in a strict one. A reading with no windows is no
            // evidence that anything lifted.
            if let rejection = rejections[id], reading.readAt > rejection.at, !reading.windows.isEmpty {
                let t = now()
                let worst = reading.windows.map { HeadroomPolicy.effectiveUtilization(of: $0, readAt: reading.readAt, now: t) }.max() ?? 0
                if worst < strictestHard(for: id) { rejections[id] = nil }
            }
        }
    }

    public func setSourceError(_ message: String?, account: UUID) { lock.withLock { errors[account] = message } }
    public func sourceError(account: UUID) -> String? { lock.withLock { errors[account] } }
    public func latestReading(account: UUID) -> UsageReading? { lock.withLock { meters[account] } }
    public func rejection(account: UUID) -> Rejection? { lock.withLock { rejections[account] } }

    public func headroom(pool id: PoolID) -> [AccountHeadroom] {
        lock.withLock { pools.first { $0.id == id }.map(unlockedHeadroom) ?? [] }
    }

    public func lease(pool id: PoolID) -> AccountLease? {
        lock.withLock {
            guard let pool = pools.first(where: { $0.id == id }) else { return nil }
            let account: AccountRef?
            switch pool.kind {
            case .local:
                account = activeCount(id) < pool.concurrencyCap ? slot(pool) : nil
            case .hosted:
                account = LeasePolicy.pick(unlockedHeadroom(pool))
            }
            guard let account else { return nil }
            let lease = AccountLease(pool: id, account: account)
            active[lease.id] = lease
            return lease
        }
    }

    public func release(_ lease: AccountLease) { lock.withLock { _ = active.removeValue(forKey: lease.id) } }

    /// Re-registers a lease taken by an earlier launch of the app, whose holder outlived it — a
    /// planning runner under fd-abduco keeps billing across an app quit, but this ledger is
    /// in-memory and starts empty. Without it a local pool would hand that runner's slot to a
    /// second holder. Taken as-is, with no headroom check: the holder is already running on it.
    /// Idempotent by lease id.
    public func adopt(_ lease: AccountLease) { lock.withLock { active[lease.id] = lease } }

    public func activeLeases(pool id: PoolID) -> [AccountLease] {
        lock.withLock { active.values.filter { $0.pool == id }.sorted { $0.id.uuidString < $1.id.uuidString } }
    }

    // MARK: - Under the lock

    private func unlockedHeadroom(_ pool: CapacityPool) -> [AccountHeadroom] {
        switch pool.kind {
        case .local:
            // A local pool's limit is concurrency, not quota: "full" is reported as over hard so
            // the popover and L3-S read it like any exhausted pool, but nothing is ever handed
            // off for it (`LedgerHandoffPlanner` skips slot leases).
            let used = activeCount(pool.id)
            return [AccountHeadroom(account: slot(pool), worstUtilization: Double(used) / Double(max(pool.concurrencyCap, 1)),
                                    state: used < pool.concurrencyCap ? .underSoft : .overHard, resetsAt: nil)]
        case .hosted:
            let t = now()
            return pool.accounts.compactMap { id in
                guard let ref = refs[id] else { return nil }
                return HeadroomPolicy.evaluate(account: ref, reading: meters[id], rejection: rejections[id],
                                               soft: pool.softThreshold, hard: pool.hardThreshold, now: t)
            }
        }
    }

    private func activeCount(_ pool: PoolID) -> Int { active.values.filter { $0.pool == pool }.count }
    private func slot(_ pool: CapacityPool) -> AccountRef { AccountRef(agent: pool.agent, id: nil, label: pool.label) }

    private func strictestHard(for account: UUID) -> Double {
        pools.filter { $0.kind == .hosted && $0.accounts.contains(account) }.map(\.hardThreshold).min()
            ?? CapacityPool.defaultHardThreshold
    }
}
