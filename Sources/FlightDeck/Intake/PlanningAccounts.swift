import Foundation
import IntakeKit

// Planning bills the project's accounts (unify brief R9). Every planning seat — triage, and
// every seat of every round — runs as the account or pool the project assigns its agent, the
// same answer a new tab in that project gets; no assignment is the agent's first live account,
// and an agent with no account record at all runs in its CLI's built-in home.
//
// `AccountResolving` is the seam planning needs from account resolution. Track A built the
// shared `AccountResolver` tabs use in parallel, on another branch; this protocol is kept to
// exactly what planning calls, `AccountResolutionError` mirrors Track A's cases, and
// `LedgerAccountResolver` follows its rules, so integration replaces `LedgerAccountResolver`
// with a short `extension AccountResolver: AccountResolving` (see the Track P report).

/// What an agent bills for a project right now, as the Rounds editor shows it — read-only, and
/// never a lease.
struct AccountBilling: Equatable, Sendable {
    /// "Work pool", "Personal", "Grok built-in".
    var text: String
    /// Set when the assignment cannot be honoured (an account or pool that no longer exists):
    /// planning will refuse to start, and the editor says so instead of naming a login.
    var problem: Bool = false
}

/// One agent's resolved billing: the account it runs as, and the pool lease that put it there.
struct ResolvedAccount: Equatable {
    var agent: AgentID
    /// nil: no account record for the agent (grok/gemini on an install that never seeded one, or
    /// a local pool's slot) — the CLI's built-in home.
    var account: AgentAccount?
    var lease: AccountLease?
    var label: String

    /// The runner's view (`RunnerAccounts.Entry`). A built-in account keeps `home` nil, so its
    /// CLI runs exactly as an unbound seat always did — see `RunnerAccounts.Entry.home` for why
    /// claude must not be handed `~/.claude` explicitly — while still being credited by id.
    var entry: RunnerAccounts.Entry {
        RunnerAccounts.Entry(accountID: account?.id,
                             home: account.flatMap { $0.isBuiltIn ? nil : $0.home },
                             label: label, lease: lease.map(StoredLease.init))
    }
}

/// A BROKEN assignment: planning refuses to start rather than run on another login — the rule
/// tabs follow (`SessionStore.launchAccount`'s `.accountMissing`), because a seat silently billed
/// to the wrong account is the failure assignment exists to stop. Cases match Track A's
/// `AccountResolutionError`; at integration this declaration goes and `message` stays.
enum AccountResolutionError: Error, Equatable, Sendable {
    /// The assigned account is gone or tombstoned.
    case accountMissing(AgentID)
    /// The assigned pool is gone, is another agent's, or has no live member.
    case poolUnavailable(PoolID, AgentID)
}

extension AccountResolutionError {
    var message: String {
        switch self {
        case .accountMissing(let agent):
            "the \(agent.displayName) account assigned to this project no longer exists — choose another in Settings → Projects"
        case .poolUnavailable(let pool, let agent):
            "the \(agent.displayName) pool assigned to this project (\(pool)) has no account to use — choose another in Settings → Projects"
        }
    }
}

/// The account resolution planning needs. `@MainActor` because preferences are.
@MainActor
protocol AccountResolving: AnyObject {
    /// What `agent` would bill in `project`, without leasing — the Rounds editor's line.
    func billing(_ agent: AgentID, project: String) -> AccountBilling
    /// Resolves `agent` in `project`, taking a lease when the project assigns a pool. The caller
    /// owns the lease and must `release` it when its run ends.
    func acquire(_ agent: AgentID, project: String) -> Result<ResolvedAccount, AccountResolutionError>
    func release(_ lease: AccountLease)
    /// Re-registers a lease a previous launch took for a holder that is still running.
    func adopt(_ lease: AccountLease)
}

extension AccountResolving {
    /// Every agent in `agents`, all-or-nothing: on any failure the leases already taken are
    /// released, so a refused start never strands one.
    func acquire(_ agents: Set<AgentID>, project: String) -> Result<RunnerAccounts, AccountResolutionError> {
        var resolved = RunnerAccounts()
        // A fixed order, so which pool is leased first never depends on Set iteration.
        for agent in AgentID.allCases where agents.contains(agent) {
            switch acquire(agent, project: project) {
            case .success(let account): resolved.agents[agent] = account.entry
            case .failure(let error):
                release(resolved)
                return .failure(error)
            }
        }
        return .success(resolved)
    }

    func release(_ accounts: RunnerAccounts) { accounts.leases.forEach(release) }
    func adopt(_ accounts: RunnerAccounts) { accounts.leases.forEach(adopt) }
}

extension AccountBilling {
    /// "Work pool" — a label that already says pool is not told twice.
    static func poolName(_ label: String) -> String {
        label.lowercased().hasSuffix("pool") ? label : "\(label) pool"
    }
}

/// The live resolver: the project's assignment from preferences, pool leases from the
/// `CapacityLedger` every other Level 3 lease comes from — so a planning seat and a swarm agent
/// draw on one picture of a pool's headroom.
@MainActor
final class LedgerAccountResolver: AccountResolving {
    private let preferences: PreferencesStore
    private let ledger: CapacityLedger

    init(preferences: PreferencesStore, ledger: CapacityLedger) {
        self.preferences = preferences
        self.ledger = ledger
    }

    private enum Plan {
        case account(AgentAccount?)
        case pool(CapacityPool)
    }

    /// The assignment, looked up but not leased. nil `.account` is the built-in home.
    private func plan(_ agent: AgentID, project: String) -> Result<Plan, AccountResolutionError> {
        switch preferences.projectSettings(project).accounts[agent] {
        case .account(let id)?:
            // A tombstone is missing too: `markAccountRemoved` clears assignments, so this is
            // defence in depth, as in `PreferencesStore.account(for:project:)`.
            guard let account = preferences.account(id: id), !account.isRemoved else { return .failure(.accountMissing(agent)) }
            return .success(.account(account))
        case .pool(let id)?:
            guard let pool = preferences.effectivePools.first(where: { $0.id == id && $0.agent == agent }),
                  pool.kind == .local || !pool.accounts.isEmpty else {
                return .failure(.poolUnavailable(id, agent))
            }
            return .success(.pool(pool))
        case nil:
            // As tabs do: the agent's first live account, in the Accounts list's order.
            return .success(.account(preferences.preferences.accounts(for: agent).first))
        }
    }

    func billing(_ agent: AgentID, project: String) -> AccountBilling {
        switch plan(agent, project: project) {
        case .success(.account(let account)): AccountBilling(text: Self.name(account, agent: agent))
        case .success(.pool(let pool)): AccountBilling(text: AccountBilling.poolName(pool.label))
        case .failure(.accountMissing): AccountBilling(text: "a removed account", problem: true)
        case .failure(.poolUnavailable): AccountBilling(text: "an unusable pool", problem: true)
        }
    }

    func acquire(_ agent: AgentID, project: String) -> Result<ResolvedAccount, AccountResolutionError> {
        switch plan(agent, project: project) {
        case .failure(let error): return .failure(error)
        case .success(.account(let account)):
            return .success(ResolvedAccount(agent: agent, account: account, lease: nil, label: Self.name(account, agent: agent)))
        case .success(.pool(let pool)):
            let name = AccountBilling.poolName(pool.label)
            func resolved(_ account: AgentAccount?, _ lease: AccountLease?) -> ResolvedAccount {
                ResolvedAccount(agent: agent, account: account, lease: lease,
                                label: account.map { "\(name) · \($0.displayName)" } ?? name)
            }
            if let lease = ledger.lease(pool: pool.id) {
                // A local pool's slot has no account id: its agent runs in the built-in home.
                return .success(resolved(lease.account.id.flatMap { preferences.account(id: $0) }, lease))
            }
            // Nothing leasable — every member past soft, or a ledger that has not yet been told
            // about this pool (it reconfigures a hop after a preferences change). The work still
            // runs inside the pool, unleased, never on a login outside it: the least-utilized
            // member, else the first (Track A's rule for tabs).
            let headroom = ledger.headroom(pool: pool.id).filter { $0.account.id != nil }
            let pick = headroom.min { ($0.worstUtilization ?? 0) < ($1.worstUtilization ?? 0) }?.account.id ?? pool.accounts.first
            return .success(resolved(pick.flatMap { preferences.account(id: $0) }, nil))
        }
    }

    func release(_ lease: AccountLease) { ledger.release(lease) }
    func adopt(_ lease: AccountLease) { ledger.adopt(lease) }

    private static func name(_ account: AgentAccount?, agent: AgentID) -> String {
        account?.displayName ?? "\(agent.displayName) built-in"
    }
}
