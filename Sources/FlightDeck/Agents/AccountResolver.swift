import Foundation
import IntakeKit

// The ONE place a project's account assignment (unify brief R8) turns into a login to run as,
// and where a pool assignment takes and gives back its `CapacityLedger` lease. Tabs
// (`SessionStore.launchAccount`) and planning runs (Track P, R9) both resolve here, so "which
// login does this project bill" has one answer and one lease lifecycle. Before this, a pool
// resolved to "its first live account" in `PreferencesStore.account(for:project:)` — every tab
// on the pool landed on one login however far over its limit it was.

/// Where a resolution's account came from.
enum AccountSource: Equatable, Sendable {
    /// The project names nothing for this agent: the agent's first live account in list order.
    case unassigned
    /// The project names this account directly.
    case assigned
    /// The project names this pool; the account was chosen from it.
    case pool(PoolID)
}

/// Why a pool resolution did not come from a ledger lease. Recorded on the resolution so the
/// caller can say so — the brief's rule is "fall back and tell the user, never block silently".
enum PoolFallback: Equatable, Sendable {
    /// The ledger does not know the pool yet (it is reconfigured one hop after a preferences
    /// change, so a pool made seconds ago can be missing) or has no reading for any member.
    /// The pool's first member runs, unleased. Nothing to tell: no limit is known to be near.
    case untracked
    /// Every member is over the soft threshold, none over hard. `LeasePolicy` leases nothing
    /// over soft, but soft means "prefer another", not "stop", so the first such member runs,
    /// unleased and without a notice.
    case overSoft
    /// Every member is over its hard threshold (or refused by the provider). The member with
    /// the most headroom runs — never a login outside the pool, which would bill an account
    /// the project was not assigned — and `notice` says so.
    case allOverHard
}

/// What to tell the user about a resolution, or nil when there is nothing to say.
struct AccountNotice: Equatable, Sendable {
    var title: String
    var body: String
}

/// The answer: which login to run as, and the lease (if any) the caller must hand back.
struct AccountResolution: Equatable, Sendable {
    var agent: AgentID
    /// nil: no account is configured for the agent at all. Run in the agent's built-in home
    /// with no variable set — what Flight Deck did before accounts existed.
    var account: AgentAccount?
    var source: AccountSource
    /// Non-nil only for a pool that leased. The caller owns it: `AccountResolver.hold` it for
    /// the life of the work, or `release` it if the work never starts.
    var lease: AccountLease?
    var fallback: PoolFallback?
    var notice: AccountNotice?

    init(agent: AgentID, account: AgentAccount?, source: AccountSource, lease: AccountLease? = nil,
         fallback: PoolFallback? = nil, notice: AccountNotice? = nil) {
        self.agent = agent; self.account = account; self.source = source; self.lease = lease
        self.fallback = fallback; self.notice = notice
    }

    /// The directory the agent's home variable names (`AgentID.homeEnvironmentKey`). For a
    /// nil account this is the built-in home, which needs no variable at all.
    var home: URL { account?.home ?? agent.builtInHome }
}

/// Why nothing can run. Both are BROKEN assignments, refused rather than replaced with another
/// login: a tab started as the wrong account finds none of its conversations and silently
/// starts fresh, and a seat bills an account the project was never given.
enum AccountResolutionError: Error, Equatable, Sendable {
    /// The project names an account that no longer exists, or was removed.
    case accountMissing(AgentID)
    /// The project names a pool that no longer exists, belongs to another agent, or has no
    /// live hosted member.
    case poolUnavailable(PoolID, AgentID)

    /// The tab-launch alert. Both say "choose another in Projects", which is the fix.
    var launchError: AgentLaunchError {
        switch self {
        case .accountMissing(let agent), .poolUnavailable(_, let agent): .accountMissing(agent.displayName)
        }
    }
}

/// Why a frozen tab whose account is spent stays on it at thaw instead of rolling over.
enum ThawBlocker: Equatable, Sendable {
    /// Frozen with a dialog open (smart sleep freezes `.waiting` agents as well as idle ones): a
    /// tool call is in flight, and killing the process would abandon it.
    case midTurn
    /// The composer could not be read at the freeze, so a draft might be there that a restart
    /// would lose.
    case unreadableDraft
    /// The agent has no way to carry a conversation to another home (`conversationTransfer`).
    case cannotTransfer
    /// Hand-offs need confirmation (`HandoffSettings.confirm`) and a thaw has nobody to ask.
    case needsConfirmation
}

/// What a smart-sleep thaw does with a frozen tab's agent (`AccountResolver.thawPlan`).
enum ThawPlan: Equatable {
    /// Wake the frozen agent where it is and re-lease the account it runs as. The notice is
    /// non-nil when that account is spent and the user must be told why it stayed.
    case inPlace(ThawNotice?)
    /// The account is spent and `to` has headroom: carry the conversation there and resume it.
    /// `resolution` holds the lease the store must hold for the tab, or release if the move fails.
    case rollOver(to: AgentAccount, resolution: AccountResolution)
}

enum ThawNotice: Equatable {
    /// No other member of the pool has headroom.
    case noHeadroom(pool: String, account: String)
    /// Another member had headroom, but this tab could not move.
    case stayed(ThawBlocker, account: String)
}

/// Resolves a project's assignment for one agent and owns the leases it hands out.
///
/// Lease lifecycle, for every caller:
/// 1. `resolve(agent:project:)` — leases when the assignment is a pool and the ledger has an
///    account under soft (`LeasePolicy`).
/// 2. `hold(_:for:)` once the work exists (the tab is filed, the runner started), keyed by the
///    holder's id. A failed start calls `release(_:)` instead.
/// 3. `release(holder:)` when the work ends — every lease that holder took.
///
/// Main-actor because its inputs (`PreferencesStore`) are; the ledger itself is lock-guarded.
@MainActor
final class AccountResolver {
    /// Internal, not private: planning's `AccountResolving` conformance (PlanningAccounts.swift)
    /// reads a pool's label from it for the Rounds editor's billing line.
    let preferences: PreferencesStore
    let ledger: CapacityLedger
    private var holds: [UUID: [AccountLease]] = [:]

    init(preferences: PreferencesStore, ledger: CapacityLedger) {
        self.preferences = preferences
        self.ledger = ledger
    }

    /// The login `project`'s work for `agent` runs as. `leasing: false` answers the same
    /// question with no side effect (a menu checkmark, a preview), and never returns a lease.
    func resolve(agent: AgentID, project: String,
                 leasing: Bool = true) -> Result<AccountResolution, AccountResolutionError> {
        resolve(agent: agent, assignment: preferences.projectSettings(project).accounts[agent], leasing: leasing)
    }

    /// One assignment, whoever holds it — a project's (above) or the capability index's
    /// (`resolveIndex`). One set of rules, so an index on a pool leases exactly as a tab would.
    func resolve(agent: AgentID, assignment: AccountAssignment?,
                 leasing: Bool = true) -> Result<AccountResolution, AccountResolutionError> {
        switch assignment {
        case nil:
            let first = preferences.preferences.accounts.first { $0.agent == agent && !$0.isRemoved }
            return .success(AccountResolution(agent: agent, account: first, source: .unassigned))
        case .account(let id)?:
            // A tombstone is missing, not "fall through to the top account": see
            // `SessionStore.launchAccount` for the wrong-login bug that fallback was.
            guard let account = preferences.account(id: id), !account.isRemoved, account.agent == agent else {
                return .failure(.accountMissing(agent))
            }
            return .success(AccountResolution(agent: agent, account: account, source: .assigned))
        case .pool(let id)?:
            return resolvePool(id, agent: agent, leasing: leasing)
        }
    }

    private func resolvePool(_ id: PoolID, agent: AgentID,
                             leasing: Bool) -> Result<AccountResolution, AccountResolutionError> {
        // The pool as the Accounts list says it is NOW (the ledger may be a hop behind).
        // `effectivePools` already drops tombstoned members and leaves a local pool memberless.
        guard let pool = preferences.effectivePools.first(where: { $0.id == id && $0.agent == agent }) else {
            return .failure(.poolUnavailable(id, agent))
        }
        let live = pool.accounts.compactMap { preferences.account(id: $0) }.filter { !$0.isRemoved }
        guard let first = live.first else { return .failure(.poolUnavailable(id, agent)) }
        func member(_ ref: AccountRef?) -> AgentAccount? { ref?.id.flatMap { rid in live.first { $0.id == rid } } }
        func made(_ account: AgentAccount, lease: AccountLease? = nil, fallback: PoolFallback? = nil,
                  notice: AccountNotice? = nil) -> AccountResolution {
            AccountResolution(agent: agent, account: account, source: .pool(id), lease: lease,
                              fallback: fallback, notice: notice)
        }

        // Ordered by the pool's CURRENT member order and limited to its current members.
        let byID = Dictionary(ledger.headroom(pool: id).compactMap { h in h.account.id.map { ($0, h) } },
                              uniquingKeysWith: { a, _ in a })
        let headroom = live.compactMap { byID[$0.id] }

        if leasing {
            if let lease = ledger.lease(pool: id) {
                if let account = member(lease.account) { return .success(made(account, lease: lease)) }
                // A slot lease (local pool) or an account the list no longer holds: not a login
                // this tab can bind to. Give it back and fall through.
                ledger.release(lease)
            }
        } else if let account = member(LeasePolicy.pick(headroom)) {
            return .success(made(account))
        }

        guard !headroom.isEmpty else { return .success(made(first, fallback: .untracked)) }
        if let soft = headroom.first(where: { $0.state == .overSoft }), let account = member(soft.account) {
            return .success(made(account, fallback: .overSoft))
        }
        // Everything is over hard (or refused). Most headroom wins; ties keep lease order.
        let best = headroom.enumerated().min { l, r in
            let lu = l.element.worstUtilization ?? 1, ru = r.element.worstUtilization ?? 1
            return lu != ru ? lu < ru : l.offset < r.offset
        }?.element
        let account = member(best?.account) ?? first
        let notice = AccountNotice(
            title: "Every account in “\(pool.label)” is over its limit",
            body: "Started on “\(account.displayName)”, the one with the most headroom left. It may stop until a limit resets.")
        return .success(made(account, fallback: .allOverHard, notice: notice))
    }

    // MARK: The capability index

    /// The pool an UNSET index assignment uses for `agent`: the agent's one user pool when it has
    /// exactly one (hosted — a local pool leases an endpoint slot, not a login), else its
    /// synthesized `<agent>-default` pool, else nil (the agent has no account at all). Two user
    /// pools are not guessed between: the default pool holds the unpooled accounts, which no
    /// project has claimed for itself.
    nonisolated static func defaultIndexPool(for agent: AgentID, in pools: [CapacityPool]) -> PoolID? {
        let mine = pools.filter { $0.agent == agent && $0.kind == .hosted }
        let user = mine.filter { !$0.isDefault }
        if user.count == 1 { return user[0].id }
        return mine.first(where: \.isDefault)?.id
    }

    /// What the index's refresh bills for `agent`: the stored choice, else the default pool.
    /// Only claude is ever asked — every source runs `claude -p` (`IndexExtraction.command`) —
    /// but the rule is per agent so a second extraction agent needs no new one.
    func indexAssignment(_ agent: AgentID) -> AccountAssignment? {
        if agent == .claude, let stored = preferences.indexAccount { return stored }
        return Self.defaultIndexPool(for: agent, in: preferences.effectivePools).map(AccountAssignment.pool)
    }

    /// Resolves the index's assignment, leasing when it is a pool. A STORED choice that no longer
    /// resolves is refused like a project's; the derived default never is — a default pool the
    /// ledger cannot use (no live member) falls back to the unassigned rule, so an install with
    /// no claude account still refreshes in the built-in home, as it always did.
    func resolveIndex(agent: AgentID, leasing: Bool = true) -> Result<AccountResolution, AccountResolutionError> {
        let stored = agent == .claude ? preferences.indexAccount : nil
        let result = resolve(agent: agent, assignment: indexAssignment(agent), leasing: leasing)
        if stored == nil, case .failure = result { return resolve(agent: agent, assignment: nil, leasing: leasing) }
        return result
    }

    /// Records `resolution`'s lease (if any) as held by `holder` — a tab's id, a runner's id —
    /// until `release(holder:)`. A holder may hold several (a runner leases per agent).
    func hold(_ resolution: AccountResolution, for holder: UUID) {
        guard let lease = resolution.lease else { return }
        holds[holder, default: []].append(lease)
    }

    /// Gives back every lease `holder` holds. Idempotent: a second call finds nothing.
    func release(holder: UUID) {
        for lease in holds.removeValue(forKey: holder) ?? [] { ledger.release(lease) }
    }

    /// Gives back a resolution's lease that was never held — the work failed to start.
    func release(_ resolution: AccountResolution) {
        if let lease = resolution.lease { ledger.release(lease) }
    }

    func leases(heldBy holder: UUID) -> [AccountLease] { holds[holder] ?? [] }

    /// Decides a smart-sleep thaw (round 2, sleep-lease-rollover). A frozen agent holds no
    /// lease (`SessionStore.agentFroze` released it); this answers what its tab does on waking:
    /// - its project gives the agent no hosted pool that lists `account`, or `account` is not
    ///   spent → `.inPlace(nil)`: wake it, re-lease the same account (`reacquire`, even over
    ///   soft or the pool's concurrency cap — the conversation lives in that home);
    /// - `account` is spent (over its pool's hard threshold, or refused by its provider) and
    ///   `blocked` says the tab cannot move → `.inPlace(.stayed)`;
    /// - spent, and the pool leases another member (`LeasePolicy`) or has one merely over soft
    ///   → `.rollOver` to it, with the lease (if any) on the resolution;
    /// - spent, and every other member is spent too → `.inPlace(.noHeadroom)`, never a dead tab.
    func thawPlan(agent: AgentID, project: String, account: AgentAccount, blocked: ThawBlocker?) -> ThawPlan {
        guard case .pool(let id)? = preferences.projectSettings(project).accounts[agent],
              let pool = preferences.effectivePools.first(where: { $0.id == id && $0.agent == agent }),
              pool.kind == .hosted, pool.accounts.contains(account.id)
        else { return .inPlace(nil) }
        let state = ledger.headroom(pool: id).first { $0.account.id == account.id }?.state
        guard state == .overHard else { return .inPlace(nil) }
        if let blocked { return .inPlace(.stayed(blocked, account: account.displayName)) }
        let noHeadroom = ThawPlan.inPlace(.noHeadroom(pool: pool.label, account: account.displayName))
        guard case .success(let resolution) = resolvePool(id, agent: agent, leasing: true) else { return noHeadroom }
        guard let next = resolution.account, next.id != account.id, resolution.fallback != .allOverHard else {
            release(resolution)
            return noHeadroom
        }
        return .rollOver(to: next, resolution: resolution)
    }

    /// Re-takes the lease for work that is ALREADY running as `account` — a tab restored after
    /// a relaunch, or one whose agent came back after it exited — and holds it for `holder`.
    /// True when a lease is now held.
    ///
    /// Never `resolve`: that picks the member with the most headroom, and a running agent cannot
    /// be moved to another login — its conversation lives in this account's home. So the lease
    /// names `account` as-is, taken through `CapacityLedger.adopt` with no headroom check, the
    /// way planning re-adopts a relaunched runner's leases. Only when `project` assigns `agent`
    /// a hosted pool that still lists `account`: an account outside the pool runs on no pool,
    /// and leasing it there would count it against capacity it does not use.
    @discardableResult
    func reacquire(agent: AgentID, project: String, account: AgentAccount, for holder: UUID) -> Bool {
        guard leases(heldBy: holder).isEmpty else { return true }
        guard case .pool(let id)? = preferences.projectSettings(project).accounts[agent],
              let pool = preferences.effectivePools.first(where: { $0.id == id && $0.agent == agent }),
              pool.kind == .hosted, pool.accounts.contains(account.id), !account.isRemoved
        else { return false }
        let lease = AccountLease(pool: id, account: CapacityPreferences.accountRef(account))
        ledger.adopt(lease)
        holds[holder, default: []].append(lease)
        return true
    }
}
