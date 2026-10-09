import Foundation
import IntakeKit

// Settings → Accounts as data (unify brief R6): ONE ordered list whose entries are accounts or
// pools, with pools holding accounts one level deep. It replaced two sources of truth that each
// held half the picture — `Preferences.storedAccounts` (who you can sign in as, in tab-default
// order) and `CapacityPreferences.pools` (how Flight Control leases them) — and let an account
// sit in any number of pools at once, so "which pool bills this" had no single answer.

/// One pool in the Accounts list: a named, ordered group of ONE agent's accounts that a lease
/// draws from, carrying everything `CapacityPool` carries.
///
/// Single-agent by construction (`AccountList` refuses a member of another agent): a lease
/// starts the pool's agent's CLI with the leased account's home, so a codex login in a claude
/// pool would launch claude bound to a codex home.
struct AccountPool: Codable, Equatable, Identifiable, Sendable {
    /// Stable for the pool's life; renaming changes only `label`. Execution blocks, routing rules
    /// and project assignments store this.
    var id: PoolID
    var label: String
    var agent: AgentID
    var kind: CapacityPool.Kind
    /// Lease order: `LeasePolicy` takes the first member under the soft threshold. The full
    /// records live here — an account in a pool is not also at top level.
    var members: [AgentAccount]
    var softThreshold: Double
    var hardThreshold: Double
    /// A local pool's endpoint (display only); nil for hosted.
    var endpoint: String?
    /// A local pool's concurrency limit.
    var concurrencyCap: Int

    init(id: PoolID, label: String, agent: AgentID, kind: CapacityPool.Kind = .hosted,
         members: [AgentAccount] = [], softThreshold: Double = CapacityPool.defaultSoftThreshold,
         hardThreshold: Double = CapacityPool.defaultHardThreshold, endpoint: String? = nil,
         concurrencyCap: Int = CapacityPool.defaultConcurrencyCap) {
        self.id = id; self.label = label; self.agent = agent; self.kind = kind; self.members = members
        self.softThreshold = softThreshold; self.hardThreshold = hardThreshold
        self.endpoint = endpoint; self.concurrencyCap = concurrencyCap
    }

    /// A stored `CapacityPool`'s settings, with its members resolved to records by the caller.
    init(_ pool: CapacityPool, members: [AgentAccount]) {
        self.init(id: pool.id, label: pool.label, agent: pool.agent, kind: pool.kind, members: members,
                  softThreshold: pool.softThreshold, hardThreshold: pool.hardThreshold,
                  endpoint: pool.endpoint, concurrencyCap: pool.concurrencyCap)
    }

    /// `<agent>-default`. An entry with this id holds the default pool's SETTINGS (label,
    /// thresholds); its lease list also takes in every unpooled account of its agent — see
    /// `AccountList.effectivePools`.
    var isDefault: Bool { id == CapacityPool.defaultID(for: agent) }

    /// What Level 3 leases from: live members of the pool's own agent, in order. A tombstoned
    /// member stays in the list (its running tab still reports under its id, which the ledger
    /// records from the full account list) but is never leased again.
    var capacityPool: CapacityPool {
        CapacityPool(id: id, label: label, agent: agent, kind: kind,
                     accounts: kind == .local ? [] : members.filter { !$0.isRemoved && $0.agent == agent }.map(\.id),
                     softThreshold: softThreshold, hardThreshold: hardThreshold,
                     endpoint: endpoint, concurrencyCap: concurrencyCap)
    }
}

/// One row of the Accounts list: an account at top level, or a pool with its accounts nested.
enum AccountEntry: Equatable, Identifiable, Sendable {
    case account(AgentAccount)
    case pool(AccountPool)

    enum ID: Hashable, Sendable {
        case account(UUID)
        case pool(PoolID)
    }

    var id: ID {
        switch self {
        case .account(let a): .account(a.id)
        case .pool(let p): .pool(p.id)
        }
    }

    /// The agent the row belongs to — what the Accounts UI groups by.
    var agent: AgentID {
        switch self {
        case .account(let a): a.agent
        case .pool(let p): p.agent
        }
    }
}

extension AccountEntry: Codable {
    private enum CodingKeys: String, CodingKey { case account, pool }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let account = try c.decodeIfPresent(AgentAccount.self, forKey: .account) {
            self = .account(account)
        } else {
            self = .pool(try c.decode(AccountPool.self, forKey: .pool))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .account(let a): try c.encode(a, forKey: .account)
        case .pool(let p): try c.encode(p, forKey: .pool)
        }
    }
}

/// Why an Accounts-list edit was refused. Every case is a rule of the model, so the UI can say
/// it instead of silently doing something else.
enum AccountListError: Error, Equatable {
    case unknownAccount(UUID)
    case unknownPool(PoolID)
    case duplicatePool(PoolID)
    /// A pool holds one agent's accounts only (see `AccountPool`).
    case agentMismatch(account: AgentID, pool: AgentID)
    /// Adding this account is refused for its agent; `reason` is the sentence to show.
    case addRefused(reason: String)
}

/// Settings → Accounts: the ordered list of accounts and pools (unify brief R6), stored in
/// `preferences.v1` as `Preferences.storedAccountList`.
///
/// Invariants every mutation here keeps: an account appears exactly once (top level or in one
/// pool); a pool's members are all of its agent; pools do not nest (the type cannot express it).
struct AccountList: Equatable, Sendable {
    var entries: [AccountEntry]

    init(entries: [AccountEntry] = []) { self.entries = entries }

    // MARK: Reading

    /// Every account, flat, in list order — a pool's members where the pool sits, in lease
    /// order. Tombstones included (see `AgentAccount.removedAt`). This order is what "the
    /// agent's first account" means for a new tab with no project assignment.
    var accounts: [AgentAccount] {
        get {
            entries.flatMap { entry -> [AgentAccount] in
                switch entry {
                case .account(let a): [a]
                case .pool(let p): p.members
                }
            }
        }
        set { reconcile(with: newValue) }
    }

    var pools: [AccountPool] {
        entries.compactMap { if case .pool(let p) = $0 { p } else { nil } }
    }

    func pool(_ id: PoolID) -> AccountPool? { pools.first { $0.id == id } }

    /// The pool an account belongs to, or nil for a top-level account.
    func pool(containing account: UUID) -> AccountPool? {
        pools.first { $0.members.contains { $0.id == account } }
    }

    /// The pools Level 3 leases from (`CapacityLedger`, `PoolDirectory`, `UsageService`).
    ///
    /// First one `<agent>-default` per agent, in `AgentID` order, holding that agent's LIVE
    /// top-level accounts in list order — the accounts no pool claims. It is synthesized, never
    /// stored, so a user who never makes a pool gets one per agent that tracks the list, and an
    /// account added later joins it with no edit. When the list holds an entry with the default
    /// id (the user changed the default pool's label or thresholds), that entry's settings and
    /// members come first and the unpooled accounts follow. An agent with no live account in a
    /// default has no default pool, exactly as before the list existed.
    ///
    /// Then every other pool entry, in list order.
    ///
    /// Deliberately NOT "a default only for an agent with no pool of its own": routing rules and
    /// execution blocks name `claude-default`, and making the user's first claude pool delete it
    /// would strand every one of them. An unpooled account is in the default pool, which is
    /// still "at most one pool".
    func effectivePools() -> [CapacityPool] {
        var out: [CapacityPool] = []
        let stored = pools
        for agent in AgentID.allCases {
            let unpooled = entries.compactMap { entry -> UUID? in
                guard case .account(let a) = entry, a.agent == agent, !a.isRemoved else { return nil }
                return a.id
            }
            let id = CapacityPool.defaultID(for: agent)
            if let entry = stored.first(where: { $0.id == id && $0.agent == agent }) {
                var pool = entry.capacityPool
                pool.accounts += unpooled.filter { !pool.accounts.contains($0) }
                if !pool.accounts.isEmpty || pool.kind == .local { out.append(pool) }
            } else if !unpooled.isEmpty {
                out.append(.hosted(id: id, label: "\(agent.displayName) default", agent: agent, accounts: unpooled))
            }
        }
        for entry in stored where !(entry.isDefault) { out.append(entry.capacityPool) }
        return out
    }

    // MARK: Editing

    /// Why `account` cannot be added, or nil when it can (unify brief R5). Gemini signs in
    /// through the system keychain with no home variable, so there is no directory a second
    /// login could live in: only its built-in account, once.
    func addRefusal(for account: AgentAccount) -> String? {
        guard account.agent == .gemini else { return nil }
        let hasOne = accounts.contains { $0.agent == .gemini && !$0.isRemoved }
        guard hasOne || !account.isBuiltIn else { return nil }
        return Self.geminiRefusal
    }

    static let geminiRefusal = "Gemini signs in through the system keychain, so Flight Deck can use only its one built-in account."

    /// Appends an account at top level, after the refusal check.
    mutating func add(_ account: AgentAccount) throws(AccountListError) {
        if let reason = addRefusal(for: account) { throw .addRefused(reason: reason) }
        entries.append(.account(account))
    }

    /// Adds a pool at the end. Its members are moved out of wherever they were.
    mutating func addPool(_ pool: AccountPool) throws(AccountListError) {
        guard self.pool(pool.id) == nil else { throw .duplicatePool(pool.id) }
        for member in pool.members where member.agent != pool.agent {
            throw .agentMismatch(account: member.agent, pool: pool.agent)
        }
        let ids = Set(pool.members.map(\.id))
        detach(ids)
        entries.append(.pool(pool))
    }

    /// Removes a pool. Its members return to top level where the pool was, in pool order, so
    /// deleting a pool never deletes a login.
    mutating func removePool(_ id: PoolID) throws(AccountListError) {
        guard let index = entries.firstIndex(where: { $0.id == .pool(id) }), case .pool(let pool) = entries[index] else {
            throw .unknownPool(id)
        }
        entries.replaceSubrange(index...index, with: pool.members.map(AccountEntry.account))
    }

    /// Changes a pool's settings. `id` and `agent` are the pool's identity and stay; members may
    /// be reordered here but not added (use `move`).
    mutating func updatePool(_ id: PoolID, _ change: (inout AccountPool) -> Void) throws(AccountListError) {
        guard let index = entries.firstIndex(where: { $0.id == .pool(id) }), case .pool(var pool) = entries[index] else {
            throw .unknownPool(id)
        }
        let before = pool
        change(&pool)
        pool.id = before.id
        pool.agent = before.agent
        // Reorder only: anything else would bypass the one-pool and one-agent rules.
        if Set(pool.members.map(\.id)) != Set(before.members.map(\.id)) { pool.members = before.members }
        entries[index] = .pool(pool)
    }

    /// Moves an account into `pool` (nil: to top level). `index` is the position within the
    /// pool, or within `entries` at top level; nil appends.
    mutating func move(account id: UUID, toPool target: PoolID?, at index: Int? = nil) throws(AccountListError) {
        guard let account = accounts.first(where: { $0.id == id }) else { throw .unknownAccount(id) }
        if let target {
            guard let pool = pool(target) else { throw .unknownPool(target) }
            guard pool.agent == account.agent else { throw .agentMismatch(account: account.agent, pool: pool.agent) }
        }
        detach([id])
        guard let target else {
            entries.insert(.account(account), at: min(index ?? entries.count, entries.count))
            return
        }
        guard let p = entries.firstIndex(where: { $0.id == .pool(target) }), case .pool(var pool) = entries[p] else { return }
        pool.members.insert(account, at: min(index ?? pool.members.count, pool.members.count))
        entries[p] = .pool(pool)
    }

    /// Reorders top-level rows (accounts and pools alike).
    mutating func moveEntries(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Removes `ids` from wherever they are, top level or pool.
    private mutating func detach(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries = entries.compactMap { entry in
            switch entry {
            case .account(let a): return ids.contains(a.id) ? nil : entry
            case .pool(var p):
                p.members.removeAll { ids.contains($0.id) }
                return .pool(p)
            }
        }
    }

    /// The `accounts` setter: applies a flat array the way every pre-list caller wrote one.
    ///
    /// A record whose id is already in the list is replaced where it sits (a rename, relocate or
    /// tombstone keeps its pool); an id that is gone is removed; a new id is appended at top
    /// level. ORDER is applied per container: each container's slots are refilled in the order
    /// the array gives its accounts, so `Preferences.moveAccounts(forAgent:)` — which reorders
    /// one agent's entries in the flat array — reorders them within their pool or at top level
    /// and never moves an account across a pool boundary.
    private mutating func reconcile(with flat: [AgentAccount]) {
        let byID = Dictionary(flat.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rank = Dictionary(flat.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func reordered(_ members: [AgentAccount]) -> [AgentAccount] {
            members.compactMap { byID[$0.id] }.sorted { rank[$0.id]! < rank[$1.id]! }
        }
        // Top-level slots, refilled in flat order.
        let topLevel = reordered(entries.compactMap { if case .account(let a) = $0 { a } else { nil } })
        var nextTop = topLevel.makeIterator()
        var known = Set<UUID>()
        var rebuilt: [AccountEntry] = []
        for entry in entries {
            switch entry {
            case .account(let a):
                known.insert(a.id)
                guard byID[a.id] != nil, let next = nextTop.next() else { continue }
                rebuilt.append(.account(next))
            case .pool(var p):
                p.members.forEach { known.insert($0.id) }
                p.members = reordered(p.members)
                rebuilt.append(.pool(p))
            }
        }
        rebuilt += flat.filter { !known.contains($0.id) }.map(AccountEntry.account)
        entries = rebuilt
    }

    // MARK: Migration and the legacy mirror

    /// The list a pre-list `preferences.v1` describes: `storedAccounts` in their order, and
    /// `capacity.pools`.
    ///
    /// - A user pool (not `<agent>-default`) becomes a pool entry at the position of its first
    ///   member. An account claimed by an earlier pool is not claimed again (pools used to
    ///   overlap; now an account is in at most one), and a member of another agent is dropped,
    ///   as `effectivePools` already dropped it from every lease. A pool with no member left (and
    ///   every local pool) goes at the end.
    /// - A stored default pool is kept only if its label or thresholds differ from the
    ///   synthesized default's, and then as a MEMBERLESS default entry: it carries the settings,
    ///   and `effectivePools` fills it with the unpooled accounts. Its stored member ORDER is
    ///   not carried over — lease order follows the list, which is the tab-default order the
    ///   user already curates. (Keeping it would have meant nesting every account of the agent
    ///   in that pool and reordering which login a new tab opens on.)
    static func migrating(accounts: [AgentAccount], pools: [CapacityPool]) -> AccountList {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed: [UUID: PoolID] = [:]
        var built: [AccountPool] = []
        for stored in pools where !stored.isDefault {
            var members: [AgentAccount] = []
            if stored.kind == .hosted {
                for id in stored.accounts where claimed[id] == nil {
                    guard let account = byID[id], account.agent == stored.agent else { continue }
                    claimed[id] = stored.id
                    members.append(account)
                }
            }
            built.append(AccountPool(stored, members: members))
        }
        for stored in pools where stored.isDefault && !built.contains(where: { $0.id == stored.id }) {
            let customized = stored.label != "\(stored.agent.displayName) default"
                || stored.softThreshold != CapacityPool.defaultSoftThreshold
                || stored.hardThreshold != CapacityPool.defaultHardThreshold
            if customized { built.append(AccountPool(stored, members: [])) }
        }
        var entries: [AccountEntry] = []
        var placed = Set<PoolID>()
        for account in accounts {
            guard let owner = claimed[account.id] else {
                entries.append(.account(account))
                continue
            }
            guard !placed.contains(owner), let pool = built.first(where: { $0.id == owner }) else { continue }
            placed.insert(owner)
            entries.append(.pool(pool))
        }
        for pool in built where !placed.contains(pool.id) { entries.append(.pool(pool)) }
        return AccountList(entries: entries)
    }

    /// What `Preferences.storedAccounts` still holds, for a Flight Deck build from before the
    /// list. Written on every change (`Preferences.accountList`'s setter) so installing an older
    /// build — which several sessions on this machine do — keeps the same account ids rather than
    /// re-seeding new ones that orphan every tab and project assignment. claude and codex only:
    /// an older build cannot decode any other agent, and one undecodable account fails the whole
    /// `preferences.v1` decode, which resets every preference.
    var legacyAccounts: [AgentAccount] { accounts.filter(\.agent.isReadableByEveryBuild) }

    /// The `capacity.pools` mirror, for the same older builds and with the same filter.
    var legacyPools: [CapacityPool] {
        pools.filter(\.agent.isReadableByEveryBuild).map { pool in
            var legacy = pool.capacityPool
            legacy.accounts = pool.members.map(\.id)
            return legacy
        }
    }

    // The filter is `AgentID.readableByEveryBuild` — the one answer to "can every build read
    // this agent", shared with the side fields of `AgentForwardCompatibility`.
}

extension AccountList: Codable {
    private enum CodingKeys: String, CodingKey { case entries }

    /// Element by element: an entry naming an agent this build has no case for (a newer build's)
    /// costs that entry, not the whole list — and through it the whole `preferences.v1`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([LossyEntry].self, forKey: .entries).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
    }

    private struct LossyEntry: Decodable {
        let value: AccountEntry?
        init(from decoder: Decoder) throws { value = try? AccountEntry(from: decoder) }
    }
}
