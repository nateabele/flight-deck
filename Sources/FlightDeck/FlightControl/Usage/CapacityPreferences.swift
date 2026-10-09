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
    /// The pre-list pool store, now only the downgrade MIRROR of the Accounts list's claude and
    /// codex pools (`AccountList.legacyPools`, written by `Preferences.accountList`). This build
    /// reads it once, to migrate a blob from before the list; the pools in force are
    /// `AccountList.effectivePools()`.
    var pools: [CapacityPool]?
    var confirmHandoffs: Bool?
    var handoffDeadlineSeconds: Int?
    /// What the capability index's refresh bills (Settings → Flight Control → Capability Index):
    /// one account, or a pool it leases from for the length of a refresh. nil is "Default" —
    /// claude's pool, see `AccountResolver.indexAssignment`. Stored as two keys, `indexAccountID`
    /// and `indexPool`, for the reason `ProjectSettings` splits its map: each stays a plain
    /// scalar an older build ignores rather than an enum it cannot decode.
    var indexAccount: AccountAssignment?

    static let defaultDeadlineSeconds = 600

    private enum CodingKeys: String, CodingKey {
        case pools, confirmHandoffs, handoffDeadlineSeconds, indexAccountID, indexPool
    }

    /// `pools` element by element: a pool naming an agent this build has no `AgentID` case for
    /// (`HarnessID` was a free string, and local pools named adapters like "opencode") costs that
    /// pool — not the whole `capacity` record and, through it, every preference.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pools = try c.decodeIfPresent([LossyPool].self, forKey: .pools).map { $0.compactMap(\.value) }
        confirmHandoffs = try c.decodeIfPresent(Bool.self, forKey: .confirmHandoffs)
        handoffDeadlineSeconds = try c.decodeIfPresent(Int.self, forKey: .handoffDeadlineSeconds)
        // `try?`: a malformed index assignment costs only that assignment (back to Default), not
        // the `capacity` record and, through it, every preference.
        if let pool = try? c.decodeIfPresent(PoolID.self, forKey: .indexPool) {
            indexAccount = .pool(pool)
        } else if let id = try? c.decodeIfPresent(UUID.self, forKey: .indexAccountID) {
            indexAccount = .account(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pools, forKey: .pools)
        try c.encodeIfPresent(confirmHandoffs, forKey: .confirmHandoffs)
        try c.encodeIfPresent(handoffDeadlineSeconds, forKey: .handoffDeadlineSeconds)
        try c.encodeIfPresent(indexAccount?.accountID, forKey: .indexAccountID)
        try c.encodeIfPresent(indexAccount?.poolID, forKey: .indexPool)
    }

    private struct LossyPool: Decodable {
        let value: CapacityPool?
        init(from decoder: Decoder) throws { value = try? CapacityPool(from: decoder) }
    }

    init(pools: [CapacityPool]? = nil, confirmHandoffs: Bool? = nil, handoffDeadlineSeconds: Int? = nil,
         indexAccount: AccountAssignment? = nil) {
        self.pools = pools
        self.confirmHandoffs = confirmHandoffs
        self.handoffDeadlineSeconds = handoffDeadlineSeconds
        self.indexAccount = indexAccount
    }

    /// Whether anything can answer a hand-off confirmation. Nothing can yet: the phone has no
    /// Confirm/Decline on the swarm agent row (`FleetModel.decideHandoff` has no caller) and the
    /// Mac has no notification action. With confirm honored, every agent that crossed hard was
    /// parked in `.awaitingConfirmation` on its exhausted account, burning it, waiting for an
    /// answer nobody could give. Flip this when a confirm surface ships; Settings greys the
    /// toggle out until then.
    static let confirmSurfaceExists = false

    var handoffSettings: HandoffSettings { handoffSettings(confirmSurfaceExists: Self.confirmSurfaceExists) }

    /// The stored flag is kept (and still decoded) so it applies the day a confirm surface exists;
    /// until then confirm reads false whatever was stored.
    func handoffSettings(confirmSurfaceExists: Bool) -> HandoffSettings {
        HandoffSettings(confirm: confirmSurfaceExists && (confirmHandoffs ?? false),
                        deadline: TimeInterval(handoffDeadlineSeconds ?? Self.defaultDeadlineSeconds))
    }

    static func accountRef(_ account: AgentAccount) -> AccountRef {
        AccountRef(agent: account.agent, id: account.id, label: account.displayName)
    }
}
