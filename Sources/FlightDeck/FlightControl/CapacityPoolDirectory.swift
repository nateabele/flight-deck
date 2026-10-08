import Foundation
import IntakeKit

/// Routing's view of the pools the Accounts list defines (`AccountList.effectivePools`): one
/// `<agent>-default` per agent with an unpooled live account, then the user's own pools. Read
/// through a closure on every call, so a pool added in Settings is routable without rebuilding
/// the router.
struct CapacityPoolDirectory: PoolDirectory {
    let source: @Sendable () -> [CapacityPool]
    init(pools: @escaping @Sendable () -> [CapacityPool]) { source = pools }

    func pools() -> [PoolSummary] {
        source().map { PoolSummary(id: $0.id, agent: $0.agent, label: $0.label) }
    }

    /// `<agent>-default` when it exists; else the agent's first pool in list order — an agent
    /// whose every account sits in pools has no default, and a rule that names no pool must
    /// still land in one of that agent's; else nil, so the validator says "no pool for claude"
    /// instead of inventing one.
    func defaultPool(for agent: AgentID) -> PoolID? {
        let pools = source()
        let wanted = CapacityPool.defaultID(for: agent)
        return pools.first { $0.id == wanted }?.id ?? pools.first { $0.agent == agent }?.id
    }
}
