import SwiftUI
import IntakeKit

/// The Capacity pane's edits as pure functions, so the pane is a thin binding and the rules are
/// testable: default pools cannot be removed, ids are minted once, thresholds never cross.
///
/// Every edit first materializes the pools in force: the default pools are derived until the
/// user touches one, and the first touch must store them whole rather than store an empty list.
enum CapacityEditing {
    static func newPoolID(existing: [PoolID], random: () -> UUID = UUID.init) -> PoolID {
        while true {
            let id = PoolID("pool-\(random().uuidString.prefix(8).lowercased())")
            if !existing.contains(id) { return id }
        }
    }

    static func materialize(_ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        prefs.pools = prefs.effectivePools(accounts: accounts)
    }

    private static func edit(_ id: PoolID, _ prefs: inout CapacityPreferences, accounts: [AgentAccount],
                             _ change: (inout CapacityPool) -> Void) {
        materialize(&prefs, accounts: accounts)
        guard let i = prefs.pools?.firstIndex(where: { $0.id == id }) else { return }
        change(&prefs.pools![i])
    }

    @discardableResult
    static func addHostedPool(_ prefs: inout CapacityPreferences, agent: AgentID, accounts: [AgentAccount],
                              random: () -> UUID = UUID.init) -> PoolID {
        materialize(&prefs, accounts: accounts)
        let id = newPoolID(existing: prefs.pools?.map(\.id) ?? [], random: random)
        prefs.pools?.append(.hosted(id: id, label: "New \(agent.displayName) pool", harness: agent.harnessID, accounts: []))
        return id
    }

    @discardableResult
    static func addLocalPool(_ prefs: inout CapacityPreferences, harness: HarnessID, accounts: [AgentAccount],
                             random: () -> UUID = UUID.init) -> PoolID {
        materialize(&prefs, accounts: accounts)
        let id = newPoolID(existing: prefs.pools?.map(\.id) ?? [], random: random)
        prefs.pools?.append(.local(id: id, label: "New local pool", harness: harness, endpoint: "http://localhost:11434"))
        return id
    }

    /// A default pool is every account's home; removing it would leave an agent's tasks with no
    /// pool to name.
    @discardableResult
    static func removePool(_ id: PoolID, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) -> Bool {
        materialize(&prefs, accounts: accounts)
        guard let i = prefs.pools?.firstIndex(where: { $0.id == id }), prefs.pools?[i].isDefault == false else { return false }
        prefs.pools?.remove(at: i)
        return true
    }

    static func rename(_ id: PoolID, to label: String, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(id, &prefs, accounts: accounts) { $0.label = trimmed }
    }

    /// Hard in 0.10…1.0; soft in 0.05…hard−0.05. Clamped rather than refused, so a stepper can
    /// never leave the pool in a state `CapacityPool.validate` rejects.
    static func setThresholds(_ id: PoolID, soft: Double, hard: Double, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        let h = min(max(hard, 0.10), 1.0)
        let s = min(max(soft, 0.05), h - 0.05)
        edit(id, &prefs, accounts: accounts) { $0.hardThreshold = h; $0.softThreshold = s }
    }

    static func toggle(_ account: UUID, in id: PoolID, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        // A default pool is every live account of its agent, by definition (`effectivePools`
        // re-appends any the stored list lacks). Removing one used to just shove it to the end of
        // the list while the user believed it was excluded, so a default pool refuses both
        // directions; adding is moot, every live account is already in it.
        // Otherwise removing a member is allowed; adding one only if it is a live account of the
        // pool's own harness, so a codex login can never be leased for a claude spawn.
        let eligible = accounts.contains { $0.id == account && !$0.isRemoved }
        edit(id, &prefs, accounts: accounts) { pool in
            if pool.isDefault { return }
            if let i = pool.accounts.firstIndex(of: account) { pool.accounts.remove(at: i); return }
            guard eligible, accounts.first(where: { $0.id == account })?.agent.harnessID == pool.harness else { return }
            pool.accounts.append(account)
        }
    }

    static func move(in id: PoolID, from: IndexSet, to: Int, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { $0.accounts.move(fromOffsets: from, toOffset: to) }
    }

    static func setCap(_ id: PoolID, _ cap: Int, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { $0.concurrencyCap = min(max(cap, 1), 64) }
    }

    static func setEndpoint(_ id: PoolID, _ endpoint: String, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { $0.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
