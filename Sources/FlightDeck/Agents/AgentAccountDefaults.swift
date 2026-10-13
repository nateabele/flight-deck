import Foundation
import IntakeKit

/// The login (an account or a pool) each agent's projects run as when they have chosen none —
/// Settings → Accounts' "Make Default". Absent means the agent's topmost live account, which is
/// what every build before this one did, so a user who never chooses sees no change.
///
/// Stored as `Preferences.storedAgentAccountDefaults`, a key an older build does not know and
/// so ignores (synthesized `Codable` skips unknown keys); that build simply runs unassigned
/// projects as the topmost account again. Spelled `{accounts: {agent: uuid}, pools: {agent:
/// poolID}}` — the same two-map split `ProjectSettings` uses — and decoded entry by entry, so
/// an agent this build does not know (a later build's) costs that entry, never the file.
struct AgentAccountDefaults: Codable, Equatable {
    var assignments: [AgentID: AccountAssignment] = [:]

    init(_ assignments: [AgentID: AccountAssignment] = [:]) { self.assignments = assignments }

    var isEmpty: Bool { assignments.isEmpty }

    private enum CodingKeys: String, CodingKey { case accounts, pools }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let accounts = (try? c.decodeIfPresent([String: UUID].self, forKey: .accounts)) ?? [:]
        let pools = (try? c.decodeIfPresent([String: PoolID].self, forKey: .pools)) ?? [:]
        for (key, id) in accounts { if let agent = AgentID(rawValue: key) { assignments[agent] = .account(id) } }
        for (key, id) in pools { if let agent = AgentID(rawValue: key) { assignments[agent] = .pool(id) } }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let accounts = Dictionary(uniqueKeysWithValues: assignments.compactMap { agent, a in a.accountID.map { (agent.rawValue, $0) } })
        let pools = Dictionary(uniqueKeysWithValues: assignments.compactMap { agent, a in a.poolID.map { (agent.rawValue, $0) } })
        if !accounts.isEmpty { try c.encode(accounts, forKey: .accounts) }
        if !pools.isEmpty { try c.encode(pools, forKey: .pools) }
    }
}

extension AccountList {
    /// `stored` if it still points at something that can run: a live account of `agent`, or a
    /// hosted user pool of `agent` with a live member. Anything else reads as unset (the
    /// topmost account): the user never chose it for a project, so refusing every launch over a
    /// stale default would be worse than ignoring it. The synthesized `<agent>-default` pool of
    /// unpooled accounts is never a default — it is what "no choice" already means.
    func effectiveDefault(_ stored: AccountAssignment?, for agent: AgentID) -> AccountAssignment? {
        switch stored {
        case .account(let id)?:
            guard let account = accounts.first(where: { $0.id == id }), !account.isRemoved, account.agent == agent
            else { return nil }
            return .account(id)
        case .pool(let id)?:
            guard let pool = pool(id), !pool.isDefault, pool.agent == agent, pool.kind == .hosted,
                  pool.members.contains(where: { !$0.isRemoved })
            else { return nil }
            return .pool(id)
        case nil:
            return nil
        }
    }
}
