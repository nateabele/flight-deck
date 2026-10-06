import Foundation
import IntakeKit

/// Routing's view of the pools Settings → Flight Control → Capacity defines. Read through a
/// closure on every call, so a pool added in Settings is routable without rebuilding the router.
struct CapacityPoolDirectory: PoolDirectory {
    let source: @Sendable () -> [CapacityPool]
    init(pools: @escaping @Sendable () -> [CapacityPool]) { source = pools }

    func pools() -> [PoolSummary] {
        source().map { PoolSummary(id: $0.id, harness: $0.harness, label: $0.label) }
    }

    /// `<harness>-default` when it exists — the pools in force hold one per agent that has a
    /// live account — else nil, so the validator says "no pool for claude" instead of
    /// inventing one.
    func defaultPool(for harness: HarnessID) -> PoolID? {
        let wanted = CapacityPool.defaultID(for: harness)
        return source().first { $0.id == wanted }?.id
    }
}
