import Foundation
import IntakeKit

/// What the hand-off driver reads on every tick, so a Settings change applies to the next
/// boundary without a restart.
struct HandoffSettings: Equatable {
    var confirm: Bool
    var deadline: TimeInterval
}

/// Settings → Capacity (L3-U §2, §6). Every field optional for the reason every later field of
/// `Preferences` is: a stored blob from before this existed must decode, and nil reads as the
/// default.
struct CapacityPreferences: Codable, Equatable {
    /// Only pools the user created or edited. The default pools are derived, so a user who never
    /// opens Settings has nothing stored and still gets one pool per agent that tracks the
    /// account list.
    var pools: [CapacityPool]?
    var confirmHandoffs: Bool?
    var handoffDeadlineSeconds: Int?

    static let defaultDeadlineSeconds = 600

    init(pools: [CapacityPool]? = nil, confirmHandoffs: Bool? = nil, handoffDeadlineSeconds: Int? = nil) {
        self.pools = pools
        self.confirmHandoffs = confirmHandoffs
        self.handoffDeadlineSeconds = handoffDeadlineSeconds
    }

    var handoffSettings: HandoffSettings {
        HandoffSettings(confirm: confirmHandoffs ?? false,
                        deadline: TimeInterval(handoffDeadlineSeconds ?? Self.defaultDeadlineSeconds))
    }

    static func accountRef(_ account: AgentAccount) -> AccountRef {
        AccountRef(harness: account.agent.harnessID, id: account.id, label: account.displayName)
    }

    /// The pools in force: one `<agent>-default` per agent with a live account, then the user's
    /// own pools in stored order.
    ///
    /// A stored default keeps the order the user gave it, but an account added since joins at
    /// the end — otherwise a new login would be invisible to Flight Control until someone
    /// remembered to edit a pool. Every hosted pool drops ids that are not live accounts: a
    /// tombstoned account's running tab still reports (see `CapacityLedger.configure`), but it
    /// must never be leased again.
    func effectivePools(accounts: [AgentAccount]) -> [CapacityPool] {
        let stored = pools ?? []
        let live = accounts.filter { !$0.isRemoved }
        let liveIDs = Set(live.map(\.id))
        var out: [CapacityPool] = []
        for agent in AgentID.allCases {
            let mine = live.filter { $0.agent == agent }.map(\.id)
            let id = CapacityPool.defaultID(for: agent.harnessID)
            if var pool = stored.first(where: { $0.id == id }) {
                pool.accounts = pool.accounts.filter { mine.contains($0) } + mine.filter { !pool.accounts.contains($0) }
                out.append(pool)
            } else if !mine.isEmpty {
                out.append(.hosted(id: id, label: "\(agent.displayName) default", harness: agent.harnessID, accounts: mine))
            }
        }
        for var pool in stored where !out.contains(where: { $0.id == pool.id }) {
            // A member of another agent's harness is dropped too: leasing a codex account for a
            // claude spawn would launch it under the wrong login.
            if pool.kind == .hosted {
                let sameHarness = Set(live.filter { $0.agent.harnessID == pool.harness }.map(\.id))
                pool.accounts = pool.accounts.filter { liveIDs.contains($0) && sameHarness.contains($0) }
            }
            out.append(pool)
        }
        return out
    }
}
