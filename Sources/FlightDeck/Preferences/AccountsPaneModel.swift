import Foundation
import IntakeKit

/// Settings → Accounts (unify brief R7) as pure data: the rows each agent's group shows, and
/// what every drag does to the `AccountList`. A SwiftUI body cannot be unit tested, so every
/// rule worth pinning lives here and `AccountsSettingsTab` is a thin shell over it.
enum AccountsPaneModel {
    /// One row of an agent's group.
    enum Row: Identifiable, Equatable {
        case account(AgentAccount)
        case pool(AccountPool)
        /// A pool member, drawn one level in under its pool.
        case member(AgentAccount, pool: PoolID)

        var id: String {
            switch self {
            case .account(let a): "account:\(a.id)"
            case .pool(let p): "pool:\(p.id)"
            case .member(let a, _): "member:\(a.id)"
            }
        }

        /// For tests: the label, with members indented and pools marked.
        var debugName: String {
            switch self {
            case .account(let a): a.displayName
            case .pool(let p): "pool \(p.label)"
            case .member(let a, _): "  \(a.displayName)"
            }
        }
    }

    struct Group: Identifiable, Equatable {
        var agent: AgentID
        var rows: [Row]
        /// The login a project with no assignment for this agent runs as (the first live
        /// account, pool members included) — tagged "Default" in the list.
        var defaultAccountID: UUID?
        var id: AgentID { agent }
    }

    /// Every agent Flight Deck knows, in `AgentID` order, each with its rows in list order.
    ///
    /// Hidden on purpose: removed accounts (tombstones keep a live tab's identity but are not
    /// something the user can act on), and a stored `<agent>-default` pool entry — it only
    /// carries the default pool's settings, which the group header edits; drawn as a row it
    /// would be an empty pool that every unpooled account silently belongs to.
    static func groups(_ list: AccountList, collapsed: Set<PoolID> = []) -> [Group] {
        AgentID.allCases.map { agent in
            var rows: [Row] = []
            for entry in list.entries where entry.agent == agent {
                switch entry {
                case .account(let a) where !a.isRemoved:
                    rows.append(.account(a))
                case .pool(let p) where !p.isDefault:
                    rows.append(.pool(p))
                    if !collapsed.contains(p.id) {
                        rows += p.members.filter { !$0.isRemoved }.map { .member($0, pool: p.id) }
                    }
                default:
                    break
                }
            }
            let first = list.accounts.first { $0.agent == agent && !$0.isRemoved }
            return Group(agent: agent, rows: rows, defaultAccountID: first?.id)
        }
    }

    // MARK: Drag and drop

    /// Where a dragged row lands.
    enum DropTarget: Equatable {
        /// At top level, just before this top-level entry.
        case before(AccountEntry.ID)
        /// Into a pool: before `member`, or at the end when nil.
        case intoPool(PoolID, before: UUID?)
        /// At top level, after the agent's last top-level entry.
        case endOfGroup(AgentID)
    }

    /// The drag payload: a plain string, so the system pasteboard carries it.
    static func payload(_ id: AccountEntry.ID) -> String {
        switch id {
        case .account(let uuid): "fd-account:\(uuid.uuidString)"
        case .pool(let pool): "fd-pool:\(pool.rawValue)"
        }
    }

    static func entryID(fromPayload payload: String) -> AccountEntry.ID? {
        if payload.hasPrefix("fd-account:"), let uuid = UUID(uuidString: String(payload.dropFirst(11))) {
            return .account(uuid)
        }
        if payload.hasPrefix("fd-pool:") { return .pool(PoolID(String(payload.dropFirst(8)))) }
        return nil
    }

    /// Applies one drop, all or nothing: a refused drop (another agent's row, an unknown id)
    /// throws and leaves `list` untouched. Pools never nest, so a pool dropped on a pool or a
    /// member lands just before that pool instead.
    static func drop(_ dragged: AccountEntry.ID, on target: DropTarget,
                     in list: inout AccountList) throws(AccountListError) {
        var next = list
        let agent = try agentOf(dragged, in: next)
        try check(target, accepts: agent, in: next)
        switch dragged {
        case .pool(let pool):
            let anchor: AccountEntry.ID?
            switch target {
            case .before(let id): anchor = id
            case .intoPool(let p, _): anchor = .pool(p)
            case .endOfGroup: anchor = nil
            }
            guard anchor != dragged else { return }
            guard let from = next.entries.firstIndex(where: { $0.id == .pool(pool) }) else { throw .unknownPool(pool) }
            let entry = next.entries.remove(at: from)
            next.entries.insert(entry, at: insertionIndex(anchor, agent: agent, in: next))
        case .account(let id):
            if case .before(let anchor) = target, anchor == dragged { return }
            if case .intoPool(_, let before) = target, before == id { return }
            // Out to top level first: every target index below is then computed on a list that
            // no longer holds the dragged row, so it cannot shift under the insert.
            try next.move(account: id, toPool: nil)
            next.entries.removeLast()
            switch target {
            case .intoPool(let pool, let before):
                let members = next.pool(pool)?.members ?? []
                let at = before.flatMap { b in members.firstIndex { $0.id == b } }
                try next.moveDetached(account: try record(id, in: list), toPool: pool, at: at)
            case .before(let anchor):
                next.entries.insert(.account(try record(id, in: list)), at: insertionIndex(anchor, agent: agent, in: next))
            case .endOfGroup:
                next.entries.insert(.account(try record(id, in: list)), at: insertionIndex(nil, agent: agent, in: next))
            }
        }
        list = next
    }

    private static func record(_ id: UUID, in list: AccountList) throws(AccountListError) -> AgentAccount {
        guard let a = list.accounts.first(where: { $0.id == id }) else { throw .unknownAccount(id) }
        return a
    }

    private static func agentOf(_ id: AccountEntry.ID, in list: AccountList) throws(AccountListError) -> AgentID {
        switch id {
        case .account(let uuid): return try record(uuid, in: list).agent
        case .pool(let p):
            guard let pool = list.pool(p) else { throw .unknownPool(p) }
            return pool.agent
        }
    }

    /// Groups are per agent, so a drop target of another agent is a drag across groups.
    private static func check(_ target: DropTarget, accepts agent: AgentID, in list: AccountList) throws(AccountListError) {
        let targetAgent: AgentID
        switch target {
        case .before(let id): targetAgent = try agentOf(id, in: list)
        case .intoPool(let p, _): targetAgent = try agentOf(.pool(p), in: list)
        case .endOfGroup(let a): targetAgent = a
        }
        guard targetAgent == agent else { throw .agentMismatch(account: agent, pool: targetAgent) }
    }

    /// The index in `entries` for a top-level insert before `anchor`, or after the agent's last
    /// top-level entry when nil (the end of its group).
    private static func insertionIndex(_ anchor: AccountEntry.ID?, agent: AgentID, in list: AccountList) -> Int {
        if let anchor, let i = list.entries.firstIndex(where: { $0.id == anchor }) { return i }
        if let last = list.entries.lastIndex(where: { $0.agent == agent }) { return last + 1 }
        return list.entries.count
    }

    // MARK: Copy

    /// The line under a pool's name.
    static func summary(of pool: AccountPool) -> String {
        if pool.kind == .local {
            return "Local · \(pool.endpoint ?? "no endpoint") · up to \(pool.concurrencyCap) at once"
        }
        let live = pool.members.filter { !$0.isRemoved }.count
        let noun = live == 1 ? "1 account" : "\(live) accounts"
        return "\(noun) · new work stops at \(percent(pool.softThreshold)), hands off at \(percent(pool.hardThreshold))"
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// "email · organization" when both are known, whichever is known when one is, and a plain
    /// statement when neither has been read — never a blank line, which reads as loading.
    static func identityCaption(_ account: AgentAccount) -> String {
        switch (account.cachedIdentity?.email, account.cachedIdentity?.organization) {
        case (let email?, let organization?): "\(email) · \(organization)"
        case (let email?, nil): email
        case (nil, let organization?): organization
        case (nil, nil): "Not signed in"
        }
    }
}

extension AccountList {
    /// Inserts an account that is in no container (the caller detached it) into `pool`.
    fileprivate mutating func moveDetached(account: AgentAccount, toPool pool: PoolID, at index: Int?) throws(AccountListError) {
        entries.append(.account(account))
        try move(account: account.id, toPool: pool, at: index)
    }
}
