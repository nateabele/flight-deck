import Foundation
import IntakeKit

/// One project's overrides. Absent entirely for a project the user has never configured, which
/// is the default state — the Projects pane opens on `<Use global settings>`.
///
/// `options` is keyed by agent so switching which agent the pane edits never discards the
/// other's values, and so a per-project override stays in force whenever that agent launches
/// here regardless of what `defaultAgent` currently says.
/// What a project bills one agent's work to (unify brief R8): one account, or a pool that
/// leases one of its accounts per run.
enum AccountAssignment: Hashable, Sendable {
    case account(UUID)
    case pool(PoolID)

    /// The account id, when this names one directly.
    var accountID: UUID? { if case .account(let id) = self { id } else { nil } }
    /// The pool id, when this names a pool.
    var poolID: PoolID? { if case .pool(let id) = self { id } else { nil } }
}

struct ProjectSettings: Codable, Equatable {
    /// nil = "use global settings": inherit the global agent order untouched.
    var defaultAgent: AgentID?
    /// Per agent, because one project can run several agents. A missing key means that agent's
    /// default account — the top of its list. See `PreferencesStore.account(for:project:)` for
    /// how a pool resolves.
    var accounts: [AgentID: AccountAssignment]
    var options: [AgentID: AgentOptions]
    /// nil ⇒ not a flywheel project (the default). Optional so a settings record written
    /// before this field still decodes — synthesized `Codable` uses `decodeIfPresent` for
    /// optionals. Read as `flywheelEnabled == true`.
    var flywheelEnabled: Bool?
    /// nil ⇒ drawer open (the default). Persists the per-project collapsed state of the
    /// Observe drawer. Optional so a record written before this field still decodes.
    /// Read as `drawerCollapsed == true`.
    var drawerCollapsed: Bool?

    init(
        defaultAgent: AgentID? = nil,
        accounts: [AgentID: AccountAssignment] = [:],
        options: [AgentID: AgentOptions] = [:],
        flywheelEnabled: Bool? = nil,
        drawerCollapsed: Bool? = nil
    ) {
        self.defaultAgent = defaultAgent
        self.accounts = accounts
        self.options = options
        self.flywheelEnabled = flywheelEnabled
        self.drawerCollapsed = drawerCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case defaultAgent, accounts, accountPools, options, flywheelEnabled, drawerCollapsed
    }

    /// Two keys for one map, on purpose. `accounts` keeps exactly its pre-pool shape —
    /// `{agent: uuid}` — and holds only `.account` assignments; `.pool` assignments go under
    /// `accountPools` (`{agent: poolID}`). An older build installed over this one decodes
    /// `accounts` as `[AgentID: UUID]`, and one pool id in there would fail its whole
    /// `preferences.v1` decode and reset every preference; split, it ignores the key it does not
    /// know and falls back to the agent's default account for that project.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultAgent = try c.decodeIfPresent(AgentID.self, forKey: .defaultAgent)
        var assignments = (try c.decode([AgentID: UUID].self, forKey: .accounts)).mapValues(AccountAssignment.account)
        for (agent, pool) in try c.decodeIfPresent([AgentID: PoolID].self, forKey: .accountPools) ?? [:] {
            assignments[agent] = .pool(pool)
        }
        accounts = assignments
        options = try c.decode([AgentID: AgentOptions].self, forKey: .options)
        flywheelEnabled = try c.decodeIfPresent(Bool.self, forKey: .flywheelEnabled)
        drawerCollapsed = try c.decodeIfPresent(Bool.self, forKey: .drawerCollapsed)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(defaultAgent, forKey: .defaultAgent)
        try c.encode(accounts.compactMapValues(\.accountID), forKey: .accounts)
        let pools = accounts.compactMapValues(\.poolID)
        if !pools.isEmpty { try c.encode(pools, forKey: .accountPools) }
        try c.encode(options, forKey: .options)
        try c.encodeIfPresent(flywheelEnabled, forKey: .flywheelEnabled)
        try c.encodeIfPresent(drawerCollapsed, forKey: .drawerCollapsed)
    }

    /// A record that says nothing is deleted rather than stored, matching how an emptied flag
    /// override already drops a project from the Projects list. A *present but empty* options
    /// payload says nothing, so it does not keep the record alive.
    var isEmpty: Bool {
        defaultAgent == nil && accounts.isEmpty && options.values.allSatisfy(\.isEmpty)
            && flywheelEnabled != true && drawerCollapsed != true
    }
}

extension AgentOptions {
    /// Whether this payload overrides anything. Per-agent, because "empty" is agent-shaped:
    /// claude's is an empty `FlagSet`, codex's is every field unset.
    var isEmpty: Bool {
        switch self {
        case .claude(let flags): return flags.isEmpty
        case .codex(let options):
            return options.model == nil && options.sandbox == nil
                && options.approvalPolicy == nil && options.addDirs.isEmpty
        // No fields yet, so nothing to override; `==` keeps this right once fields arrive.
        case .grok(let options): return options == GrokOptions()
        case .gemini(let options): return options == GeminiOptions()
        }
    }
}
