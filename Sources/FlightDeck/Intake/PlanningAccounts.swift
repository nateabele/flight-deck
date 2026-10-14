import Foundation
import IntakeKit

// Planning bills the project's accounts (unify brief R9). Every planning seat — triage, and
// every seat of every round — runs as the account or pool the project assigns its agent, the
// same answer a new tab in that project gets; no assignment is the agent's default (an account or a pool), else its first live account,
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
    /// The account or pool behind `text`, when there is one (nil: the agent's built-in home, or a
    /// broken assignment) — what the editor reads the project default's model list under.
    var choice: AccountChoice? = nil
}

/// What the Rounds editor offers for one agent's account: the project's assignment (the default),
/// then each account and pool the agent has. `offersChoice` is false with one account and no pool
/// of the user's own, where the editor shows the resolved account as text instead of a picker.
struct AccountMenu: Equatable {
    struct Option: Equatable {
        var choice: AccountChoice
        var title: String
        var isPool: Bool
    }
    /// What the project's assignment bills ("Work pool", "Personal"): the default's name.
    var projectDefault: String
    /// The project's assignment cannot be honoured (planning will refuse to start).
    var problem: Bool = false
    var options: [Option] = []
    var offersChoice = false

    /// The default row's title, "Project default — Work pool".
    var defaultTitle: String { "Project default — \(projectDefault)" }

    func title(for choice: AccountChoice) -> String? { options.first { $0.choice == choice }?.title }
}

extension AccountChoice {
    init(_ assignment: AccountAssignment) {
        switch assignment {
        case .account(let id): self = .account(id)
        case .pool(let id): self = .pool(id)
        }
    }
    var assignment: AccountAssignment {
        switch self {
        case .account(let id): .account(id)
        case .pool(let id): .pool(id)
        }
    }
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
            "the \(agent.displayName) account chosen for this project no longer exists — choose another in Settings → Projects, or on the role in the Rounds editor"
        case .poolUnavailable(let pool, let agent):
            "the \(agent.displayName) pool chosen for this project (\(pool)) has no account to use — choose another in Settings → Projects, or on the role in the Rounds editor"
        }
    }
}

/// The account resolution planning needs. `@MainActor` because preferences are.
@MainActor
protocol AccountResolving: AnyObject {
    /// What `agent` would bill in `project`, without leasing — the Rounds editor's line.
    func billing(_ agent: AgentID, project: String) -> AccountBilling
    /// The Rounds editor's account picker for `agent` in `project`.
    func accountMenu(_ agent: AgentID, project: String) -> AccountMenu
    /// Resolves `agent` in `project`, taking a lease when the project assigns a pool. The caller
    /// owns the lease and must `release` it when its run ends.
    func acquire(_ agent: AgentID, project: String) -> Result<ResolvedAccount, AccountResolutionError>
    /// Resolves a role's own account or pool for `agent`, leasing when it is a pool — the same rules
    /// as the project's assignment, with the role's choice in its place.
    func acquire(_ choice: AccountChoice, agent: AgentID) -> Result<ResolvedAccount, AccountResolutionError>
    func release(_ lease: AccountLease)
    /// Re-registers a lease a previous launch took for a holder that is still running.
    func adopt(_ lease: AccountLease)
}

extension AccountResolving {
    /// A resolver that knows no list of accounts offers no choice: the editor shows the line only.
    func accountMenu(_ agent: AgentID, project: String) -> AccountMenu {
        let billing = billing(agent, project: project)
        return AccountMenu(projectDefault: billing.text, problem: billing.problem)
    }

    /// Every account `config` bills, all-or-nothing: the project's assignment for each agent some
    /// seat runs on it, and each role's own account or pool. On any failure the leases already taken
    /// are released, so a refused start never strands one. `notice` hears each over-limit notice
    /// only once everything resolved — a refused start must not also say it started.
    func acquire(_ config: RoundConfig, project: String,
                 notice: (AccountNotice) -> Void = { _ in }) -> Result<RunnerAccounts, AccountResolutionError> {
        acquire(config.projectAssignedAgents, overrides: config.accountOverrides, project: project, notice: notice)
    }

    func acquire(_ agents: Set<AgentID>, overrides: [(agent: AgentID, choice: AccountChoice)] = [], project: String,
                 notice: (AccountNotice) -> Void = { _ in }) -> Result<RunnerAccounts, AccountResolutionError> {
        var resolved = RunnerAccounts()
        var notices: [AccountNotice] = []
        var failure: AccountResolutionError?
        func run(_ result: Result<ResolvedAccount, AccountResolutionError>, _ store: (RunnerAccounts.Entry) -> Void) {
            guard failure == nil else { return }
            switch result {
            case .success(let account):
                store(account.entry)
                if let n = account.notice { notices.append(n) }
            case .failure(let error):
                failure = error
            }
        }
        // A fixed order, so which pool is leased first never depends on Set iteration.
        for agent in AgentID.allCases where agents.contains(agent) {
            run(acquire(agent, project: project)) { resolved.agents[agent] = $0 }
        }
        for (agent, choice) in overrides {
            run(acquire(choice, agent: agent)) { resolved.overrides = (resolved.overrides ?? [:]).merging([choice.key: $0]) { $1 } }
        }
        if let failure {
            release(resolved)
            return .failure(failure)
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
/// answer for a tab and a planning seat (unify brief R8/R9). Its rules: no assignment → the agent's default, else the
/// agent's first live account; a pool → a `CapacityLedger` lease, else a member inside the pool
/// (never a login outside it), with a notice when every member is over its hard limit.
extension AccountResolver: AccountResolving {
    func billing(_ agent: AgentID, project: String) -> AccountBilling {
        switch resolve(agent: agent, project: project, leasing: false) {
        case .success(let resolution):
            if case .pool(let id) = resolution.source {
                return AccountBilling(text: AccountBilling.poolName(poolLabel(id)), choice: .pool(id))
            }
            return AccountBilling(text: Self.name(resolution.account, agent: agent), choice: resolution.account.map { .account($0.id) })
        case .failure(.accountMissing): return AccountBilling(text: "a removed account", problem: true)
        case .failure(.poolUnavailable): return AccountBilling(text: "an unusable pool", problem: true)
        }
    }

    func acquire(_ agent: AgentID, project: String) -> Result<ResolvedAccount, AccountResolutionError> {
        resolve(agent: agent, project: project).map(resolved)
    }

    func accountMenu(_ agent: AgentID, project: String) -> AccountMenu {
        let billing = billing(agent, project: project)
        let list = preferences.preferences.accountList
        // Projects' own choices and order; its first row is the unset one, which is the default here.
        let options = ProjectsSettingsTab.accountOptions(for: agent, in: list, agentDefault: preferences.accountDefault(for: agent))
            .dropFirst().compactMap { option in
                option.value.map { AccountMenu.Option(choice: AccountChoice($0), title: option.title, isPool: option.isPool) }
            }
        return AccountMenu(projectDefault: billing.text, problem: billing.problem, options: Array(options),
                           offersChoice: ProjectsSettingsTab.showsAccountPicker(for: agent, in: list, assigned: nil))
    }

    func acquire(_ choice: AccountChoice, agent: AgentID) -> Result<ResolvedAccount, AccountResolutionError> {
        resolve(agent: agent, assignment: choice.assignment).map(resolved)
    }

    fileprivate func resolved(_ resolution: AccountResolution) -> ResolvedAccount {
        let agent = resolution.agent
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

    func release(_ lease: AccountLease) { ledger.release(lease) }
    func adopt(_ lease: AccountLease) { ledger.adopt(lease) }

    fileprivate func poolLabel(_ id: PoolID) -> String {
        preferences.effectivePools.first { $0.id == id }?.label ?? id.rawValue
    }

    fileprivate static func name(_ account: AgentAccount?, agent: AgentID) -> String {
        account?.displayName ?? "\(agent.displayName) built-in"
    }
}

/// The capability index's account seam (round 2, index-refresh-pool). The index is app-wide —
/// no project — so it has its own assignment (`PreferencesStore.indexAccount`, Default: claude's
/// pool), resolved by the same `AccountResolver` rules as a project's. Its own protocol rather
/// than two more `AccountResolving` requirements, which every planning stub would then carry.
@MainActor
protocol IndexAccountResolving: AnyObject {
    /// Resolves the index's assignment for `agent`, leasing when it names a pool. The caller owns
    /// the lease and must `release` it when the refresh ends, however it ends.
    func acquireIndexAccount(_ agent: AgentID) -> Result<ResolvedAccount, AccountResolutionError>
    func release(_ lease: AccountLease)
}

extension AccountResolver: IndexAccountResolving {
    func acquireIndexAccount(_ agent: AgentID) -> Result<ResolvedAccount, AccountResolutionError> {
        resolveIndex(agent: agent).map(resolved)
    }
}
