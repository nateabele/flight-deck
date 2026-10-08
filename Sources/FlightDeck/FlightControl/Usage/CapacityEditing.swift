import SwiftUI
import IntakeKit

/// The Capacity pane's pool edits as pure functions over the Accounts list (unify brief R6), so
/// the pane is a thin binding and the rules are testable: synthesized default pools cannot be
/// removed, ids are minted once, thresholds never cross, a pool holds one agent's accounts and
/// an account is in at most one pool.
///
/// Track A moves pool editing into Settings → Accounts; these stay the model-level edits it
/// builds on.
enum CapacityEditing {
    static func newPoolID(existing: [PoolID], random: () -> UUID = UUID.init) -> PoolID {
        while true {
            let id = PoolID("pool-\(random().uuidString.prefix(8).lowercased())")
            if !existing.contains(id) { return id }
        }
    }

    /// Every id in use, synthesized defaults included, so a minted id never shadows one.
    private static func ids(_ list: AccountList) -> [PoolID] {
        list.effectivePools().map(\.id) + list.pools.map(\.id)
    }

    /// The entry behind `id`, materializing a synthesized default as a MEMBERLESS entry first:
    /// it then carries the edited settings while `effectivePools` keeps filling it with the
    /// agent's unpooled accounts, so editing a default never nests anyone's accounts.
    private static func edit(_ id: PoolID, _ list: inout AccountList, _ change: (inout AccountPool) -> Void) {
        if list.pool(id) == nil, let synthesized = list.effectivePools().first(where: { $0.id == id && $0.isDefault }) {
            try? list.addPool(AccountPool(synthesized, members: []))
        }
        try? list.updatePool(id, change)
    }

    @discardableResult
    static func addHostedPool(_ list: inout AccountList, agent: AgentID, random: () -> UUID = UUID.init) -> PoolID {
        let id = newPoolID(existing: ids(list), random: random)
        try? list.addPool(AccountPool(id: id, label: "New \(agent.displayName) pool", agent: agent))
        return id
    }

    @discardableResult
    static func addLocalPool(_ list: inout AccountList, agent: AgentID, random: () -> UUID = UUID.init) -> PoolID {
        let id = newPoolID(existing: ids(list), random: random)
        try? list.addPool(AccountPool(id: id, label: "New local pool", agent: agent, kind: .local,
                                      endpoint: "http://localhost:11434"))
        return id
    }

    /// A synthesized default pool is every unpooled account's home; there is no entry to remove.
    /// A stored default entry (edited settings) can be removed — the default then reverts to its
    /// synthesized settings. Removing a pool returns its accounts to top level.
    @discardableResult
    static func removePool(_ id: PoolID, _ list: inout AccountList) -> Bool {
        guard list.pool(id) != nil else { return false }
        return (try? list.removePool(id)) != nil
    }

    static func rename(_ id: PoolID, to label: String, _ list: inout AccountList) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(id, &list) { $0.label = trimmed }
    }

    /// Hard in 0.10…1.0; soft in 0.05…hard−0.05. Clamped rather than refused, so a stepper can
    /// never leave the pool in a state `CapacityPool.validate` rejects.
    static func setThresholds(_ id: PoolID, soft: Double, hard: Double, _ list: inout AccountList) {
        let h = min(max(hard, 0.10), 1.0)
        let s = min(max(soft, 0.05), h - 0.05)
        edit(id, &list) { $0.hardThreshold = h; $0.softThreshold = s }
    }

    /// Takes `account` out of pool `id` (back to top level), or puts it in — moving it out of any
    /// other pool, since an account is in at most one. A default pool refuses both directions: it
    /// is every unpooled account of its agent by definition, so "removing" one would only move it
    /// to the end while the user believed it excluded. Adding is refused for a removed account or
    /// another agent's, so a codex login can never be leased for a claude spawn.
    static func toggle(_ account: UUID, in id: PoolID, _ list: inout AccountList) {
        guard let pool = list.pool(id), !pool.isDefault else { return }
        if pool.members.contains(where: { $0.id == account }) {
            try? list.move(account: account, toPool: nil)
            return
        }
        guard let record = list.accounts.first(where: { $0.id == account }), !record.isRemoved else { return }
        try? list.move(account: account, toPool: id)
    }

    /// Reorders a pool's lease order. A default pool's order is the Accounts list's own order
    /// for that agent (its members are the unpooled accounts), so it is reordered there instead.
    static func move(in id: PoolID, from: IndexSet, to: Int, _ list: inout AccountList) {
        guard let pool = list.pool(id), !pool.isDefault else { return }
        try? list.updatePool(id) { $0.members.move(fromOffsets: from, toOffset: to) }
    }

    static func setCap(_ id: PoolID, _ cap: Int, _ list: inout AccountList) {
        edit(id, &list) { $0.concurrencyCap = min(max(cap, 1), 64) }
    }

    static func setEndpoint(_ id: PoolID, _ endpoint: String, _ list: inout AccountList) {
        edit(id, &list) { $0.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
