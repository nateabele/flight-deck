import Foundation
import IntakeKit

// Planning bills the project's accounts (unify brief R9). Every planning seat — triage, and
// every seat of every round — runs as the account or pool the project assigns its agent, the
// same answer a new tab in that project gets; no assignment is the agent's first live account,
// and an agent with no account record at all runs in its CLI's built-in home.
//
// `AccountResolving` is the seam planning needs from account resolution, kept to exactly what
// planning calls so a test can stub it. The live conformer is the shared `AccountResolver`
// tabs use (extension at the bottom of this file): one set of rules and one ledger, so a pool
// spreads tabs and planning seats over the same picture of headroom. Planning keeps its own
// lease book (`IntakeRunnerController.heldAccounts` plus `accounts.json`, which survives a
// relaunch) rather than `AccountResolver.hold(for:)`, so one lease is never in two books.

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
    /// Set when every member of the assigned pool is over its hard limit (`PoolFallback
    /// .allOverHard`): the seat still runs, on the member with the most headroom, and the user
    /// is told — as a tab in the same project would tell them — rather than finding out from a
    /// stalled round.
    var notice: AccountNotice? = nil

    /// The runner's view (`RunnerAccounts.Entry`). A built-in account keeps `home` nil, so its
    /// CLI runs exactly as an unbound seat always did — see `RunnerAccounts.Entry.home` for why
    /// claude must not be handed `~/.claude` explicitly — while still being credited by id.
    var entry: RunnerAccounts.Entry {
        RunnerAccounts.Entry(accountID: account?.id,
                             home: account.flatMap { $0.isBuiltIn ? nil : $0.home },
                             label: label, lease: lease.map(StoredLease.init))
    }
}

/// A BROKEN assignment (`AccountResolutionError`, shared with tabs): planning refuses to start
/// rather than run on another login, because a seat silently billed to the wrong account is the
/// failure assignment exists to stop. This is the reason the intake fails with.
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
    /// released, so a refused start never strands one. `notice` hears each over-limit notice
    /// only once every agent resolved — a refused start must not also say it started.
    func acquire(_ agents: Set<AgentID>, project: String,
                 notice: (AccountNotice) -> Void = { _ in }) -> Result<RunnerAccounts, AccountResolutionError> {
        var resolved = RunnerAccounts()
        var notices: [AccountNotice] = []
        // A fixed order, so which pool is leased first never depends on Set iteration.
        for agent in AgentID.allCases where agents.contains(agent) {
            switch acquire(agent, project: project) {
            case .success(let account):
                resolved.agents[agent] = account.entry
                if let n = account.notice { notices.append(n) }
            case .failure(let error):
                release(resolved)
                return .failure(error)
            }
        }
        notices.forEach(notice)
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

/// The live resolver is the one tabs use, so "which login does this project bill" has one
/// answer for a tab and a planning seat (unify brief R8/R9). Its rules: no assignment → the
/// agent's first live account; a pool → a `CapacityLedger` lease, else a member inside the pool
/// (never a login outside it), with a notice when every member is over its hard limit.
extension AccountResolver: AccountResolving {
    func billing(_ agent: AgentID, project: String) -> AccountBilling {
        switch resolve(agent: agent, project: project, leasing: false) {
        case .success(let resolution):
            if case .pool(let id) = resolution.source {
                return AccountBilling(text: AccountBilling.poolName(poolLabel(id)))
            }
            return AccountBilling(text: Self.name(resolution.account, agent: agent))
        case .failure(.accountMissing): return AccountBilling(text: "a removed account", problem: true)
        case .failure(.poolUnavailable): return AccountBilling(text: "an unusable pool", problem: true)
        }
    }

    func acquire(_ agent: AgentID, project: String) -> Result<ResolvedAccount, AccountResolutionError> {
        resolve(agent: agent, project: project).map { resolution in
            let label: String
            if case .pool(let id) = resolution.source {
                let pool = AccountBilling.poolName(poolLabel(id))
                label = resolution.account.map { "\(pool) · \($0.displayName)" } ?? pool
            } else {
                label = Self.name(resolution.account, agent: agent)
            }
            return ResolvedAccount(agent: agent, account: resolution.account, lease: resolution.lease,
                                   label: label, notice: resolution.notice)
        }
    }

    func release(_ lease: AccountLease) { ledger.release(lease) }
    func adopt(_ lease: AccountLease) { ledger.adopt(lease) }

    private func poolLabel(_ id: PoolID) -> String {
        preferences.effectivePools.first { $0.id == id }?.label ?? id.rawValue
    }

    private static func name(_ account: AgentAccount?, agent: AgentID) -> String {
        account?.displayName ?? "\(agent.displayName) built-in"
    }
}
