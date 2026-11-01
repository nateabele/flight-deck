import FleetKit
import Foundation
import IntakeKit

// `/switch-account`: the user names where a live conversation should go. This file is only the
// NAMING half — which account a typed target means, and what the picker offers. Moving the
// conversation is `SessionStore.rollOver`, the same move a smart-sleep thaw makes.

/// What a typed target means for a tab currently on `current`.
enum AccountSwitchDecision: Equatable {
    /// Move to `account`. `note` is something the user should hear about the move (it is over
    /// its hard limit, and they asked for it anyway).
    case move(to: AgentAccount, note: String?)
    /// `account` is where the tab already is.
    case stay(AgentAccount)
    /// Nothing is done; the sentence says why and what would have worked.
    case refuse(String)
}

extension AccountResolver {
    /// "Below its limit", the one definition `/switch-account` uses for a pool: the ledger reads
    /// the account as `.underSoft`, or `.unknown` (an idle account has no reading, which is
    /// normal, and `LeasePolicy` leases it for the same reason). `.overSoft` is NOT below its
    /// limit: soft means "prefer another", and a pool pick has another to prefer.
    ///
    /// Not `resolvePool(leasing: true)`: that takes the pool's lease on a `LeasePolicy.pick`
    /// over every member, current one included, and prefers an under-soft member over an
    /// earlier unknown one. A manual move wants strict pool order with the tab's own account
    /// skipped, and the lease is taken afterwards by the same `reacquire` a thaw ends with.
    nonisolated static func isBelowLimit(_ state: HeadroomState) -> Bool { state == .underSoft || state == .unknown }

    /// The account's headroom in the pool that bills it: the pool listing it, else the
    /// synthesized `<agent>-default` that holds every unpooled account.
    func headroomState(of account: AgentAccount) -> HeadroomState {
        let pool = preferences.preferences.accountList.pool(containing: account.id)?.id
            ?? CapacityPool.defaultID(for: account.agent)
        return ledger.headroom(pool: pool).first { $0.account.id == account.id }?.state ?? .unknown
    }

    /// The hosted pool `project` assigns `agent` (its own setting, an ancestor folder's, or the
    /// agent's default), or nil when it assigns an account, nothing, or a pool that is gone.
    /// A pooled project moves only within that pool: the pool is what the project bills, and a
    /// move out of it would run the conversation on an account nobody assigned to it.
    func assignedPool(agent: AgentID, project: String) -> CapacityPool? {
        guard case .pool(let id)? = preferences.effectiveAssignment(for: agent, project: project) else { return nil }
        return preferences.effectivePools.first { $0.id == id && $0.agent == agent && $0.kind == .hosted }
    }

    /// Resolves `raw` against the accounts and pools of `agent` only — and, when `project`
    /// assigns a pool, against that pool and its members only. Case-insensitive and exact: an
    /// email, an account's name (Settings → Accounts) or id, or a pool's label or id. A name two
    /// things share is refused with both listed, never guessed.
    func switchDecision(agent: AgentID, project: String, current: AgentAccount?, target raw: String) -> AccountSwitchDecision {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let restriction = assignedPool(agent: agent, project: project)
        var accounts = preferences.preferences.accounts.filter { $0.agent == agent && !$0.isRemoved }
        var pools = preferences.effectivePools.filter { $0.agent == agent && $0.kind == .hosted }
        if let restriction {
            accounts = accounts.filter { restriction.accounts.contains($0.id) }
            pools = [restriction]
        }
        func describe(_ a: AgentAccount) -> String {
            a.cachedIdentity?.email.map { "“\(a.displayName)” (\($0))" } ?? "“\(a.displayName)”"
        }
        let valid = (pools.map { "pool “\($0.label)”" } + accounts.map(describe)).joined(separator: ", ")
        guard !key.isEmpty else { return .refuse("Say which account or pool to move to. Choices: \(valid).") }

        let accountHits = accounts.filter { account in
            [account.displayName, account.cachedIdentity?.email, account.id.uuidString]
                .contains { $0?.lowercased() == key }
        }
        let poolHits = pools.filter { $0.label.lowercased() == key || $0.id.rawValue.lowercased() == key }
        let hits = poolHits.map { "pool “\($0.label)”" } + accountHits.map(describe)
        switch hits.count {
        case 0:
            if let restriction, outsideMatch(agent: agent, key: key) {
                return .refuse("This project uses pool “\(restriction.label)”, so its conversations move only within it. Choices: \(valid).")
            }
            return .refuse(valid.isEmpty ? "There is no \(agent.displayName) account to move to."
                                         : "No \(agent.displayName) account or pool matches “\(raw)”. Choices: \(valid).")
        case 1: break
        default:
            return .refuse("“\(raw)” matches more than one: \(hits.joined(separator: ", ")). Say which one by its email or id.")
        }

        if let account = accountHits.first {
            if account.id == current?.id { return .stay(account) }
            let note = headroomState(of: account) == .overHard
                ? "“\(account.displayName)” is over its hard limit; moving there anyway because you asked." : nil
            return .move(to: account, note: note)
        }

        let pool = poolHits[0]
        let state = Dictionary(ledger.headroom(pool: pool.id).compactMap { h in h.account.id.map { ($0, h.state) } },
                               uniquingKeysWith: { a, _ in a })
        let members = pool.accounts.compactMap { preferences.account(id: $0) }.filter { !$0.isRemoved }
        if let pick = members.first(where: { $0.id != current?.id && Self.isBelowLimit(state[$0.id] ?? .unknown) }) {
            return .move(to: pick, note: nil)
        }
        return .refuse("No other account in pool “\(pool.label)” is below its limit, so nothing was moved.")
    }

    /// `key` names one of `agent`'s live accounts or pools, ignoring any project's pool.
    private func outsideMatch(agent: AgentID, key: String) -> Bool {
        preferences.preferences.accounts.contains { a in
            a.agent == agent && !a.isRemoved
                && [a.displayName, a.cachedIdentity?.email, a.id.uuidString].contains { $0?.lowercased() == key }
        } || preferences.effectivePools.contains { p in
            p.agent == agent && p.kind == .hosted && (p.label.lowercased() == key || p.id.rawValue.lowercased() == key)
        }
    }

    /// One account as `account.list` shows it, with its newest usage windows. Each window's
    /// utilization is the effective one (`HeadroomPolicy.effectiveUtilization`), the number
    /// Settings and routing use, so a window past its reset never shows its stale number.
    func choice(_ a: AgentAccount, current: AgentAccount?, now: Date = Date()) -> WireAccountChoice {
        let reading = ledger.latestReading(account: a.id)
        let windows = reading.map { reading in
            reading.windows.compactMap { window -> WireUsageWindow? in
                // Typed optional: a window the policy no longer counts is dropped.
                let effective: Double? = HeadroomPolicy.effectiveUtilization(of: window, readAt: reading.readAt, now: now)
                return effective.map { WireUsageWindow(name: window.name, utilization: $0, resetsAt: window.resetsAt) }
            }
        }
        return WireAccountChoice(
            id: a.id.uuidString, displayName: a.displayName, email: a.cachedIdentity?.email,
            state: headroomState(of: a).rawValue, isCurrent: a.id == current?.id,
            windows: windows, readAt: reading?.readAt)
    }

    /// What `account.list` answers: pools in Settings order with their members nested, then the
    /// accounts in no pool. A project that assigns a pool is offered that pool alone, the same
    /// restriction `switchDecision` applies to a typed target.
    func choices(agent: AgentID, project: String, current: AgentAccount?) -> WireAccountChoices {
        let list = preferences.preferences.accountList
        let assigned = preferences.effectiveAssignment(for: agent, project: project)?.poolID
        func poolChoice(id: PoolID, label: String, members: [AgentAccount]) -> WireAccountPoolChoice? {
            let members = members.filter { !$0.isRemoved && $0.agent == agent }
            guard !members.isEmpty else { return nil }
            return WireAccountPoolChoice(id: id.rawValue, label: label, isAssigned: id == assigned,
                                         members: members.map { choice($0, current: current) })
        }
        let pools: [WireAccountPoolChoice]
        let unpooled: [AgentAccount]
        if let restriction = assignedPool(agent: agent, project: project) {
            // From the effective pool, not the list: `<agent>-default` exists only there.
            pools = [poolChoice(id: restriction.id, label: restriction.label,
                                members: restriction.accounts.compactMap { preferences.account(id: $0) })].compactMap { $0 }
            unpooled = []
        } else {
            pools = list.pools.filter { $0.agent == agent && $0.kind == .hosted }
                .compactMap { poolChoice(id: $0.id, label: $0.label, members: $0.members) }
            unpooled = list.entries.compactMap { entry -> AgentAccount? in
                guard case .account(let a) = entry, a.agent == agent, !a.isRemoved else { return nil }
                return a
            }
        }
        return WireAccountChoices(agent: agent.rawValue, current: current?.id.uuidString,
                                  assignedPool: assigned?.rawValue, pools: pools,
                                  accounts: unpooled.map { choice($0, current: current) },
                                  currentAccount: current.map { choice($0, current: current) })
    }
}
