import Foundation

/// A named group of capacity for one adapter (L3-U §2). Hosted pools are an ordered list of that
/// adapter's accounts; local pools are an endpoint with a concurrency cap and no account at all.
///
/// One flat struct rather than an enum with payloads, so a stored pool keeps decoding when a
/// later field is added and so the Settings editor can flip a draft between kinds without
/// losing what was typed.
public struct CapacityPool: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case hosted, local }

    public static let defaultSoftThreshold = 0.80
    public static let defaultHardThreshold = 0.95
    public static let defaultConcurrencyCap = 2

    /// Stable for the pool's life; renaming changes only `label`. Execution blocks store this.
    public var id: PoolID
    public var label: String
    public var agent: AgentID
    public var kind: Kind
    /// Hosted: account ids, in lease order. Empty for a local pool.
    public var accounts: [UUID]
    public var softThreshold: Double
    public var hardThreshold: Double
    /// Local: where the provider listens (an Ollama URL, say). Display only — Flight Deck does
    /// not probe it.
    public var endpoint: String?
    public var concurrencyCap: Int

    public init(id: PoolID, label: String, agent: AgentID, kind: Kind, accounts: [UUID],
                softThreshold: Double, hardThreshold: Double, endpoint: String?, concurrencyCap: Int) {
        self.id = id; self.label = label; self.agent = agent; self.kind = kind; self.accounts = accounts
        self.softThreshold = softThreshold; self.hardThreshold = hardThreshold
        self.endpoint = endpoint; self.concurrencyCap = concurrencyCap
    }

    public static func hosted(id: PoolID, label: String, agent: AgentID, accounts: [UUID],
                              soft: Double = defaultSoftThreshold, hard: Double = defaultHardThreshold) -> CapacityPool {
        CapacityPool(id: id, label: label, agent: agent, kind: .hosted, accounts: accounts,
                     softThreshold: soft, hardThreshold: hard, endpoint: nil, concurrencyCap: defaultConcurrencyCap)
    }

    public static func local(id: PoolID, label: String, agent: AgentID, endpoint: String,
                             cap: Int = defaultConcurrencyCap) -> CapacityPool {
        CapacityPool(id: id, label: label, agent: agent, kind: .local, accounts: [],
                     softThreshold: defaultSoftThreshold, hardThreshold: defaultHardThreshold,
                     endpoint: endpoint, concurrencyCap: cap)
    }

    /// `<adapter>-default`: the pool every adapter gets without asking (L3-U §2).
    public static func defaultID(for agent: AgentID) -> PoolID { PoolID("\(agent.rawValue)-default") }

    public var isDefault: Bool { id == Self.defaultID(for: agent) }

    /// `agent` keeps its pre-unification JSON key, `harness` (unify brief R1): pools are stored
    /// in `preferences.v1` (`capacity.pools`, kept as the downgrade mirror of the Accounts list).
    private enum CodingKeys: String, CodingKey {
        case agent = "harness"
        case id, label, kind, accounts, softThreshold, hardThreshold, endpoint, concurrencyCap
    }
}

public enum PoolValidationError: Error, Equatable, Sendable {
    case emptyLabel
    case thresholdOutOfRange(Double)
    case thresholdsOutOfOrder(soft: Double, hard: Double)
    case capBelowOne(Int)
}

extension CapacityPool {
    public func validate() throws {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PoolValidationError.emptyLabel }
        switch kind {
        case .hosted:
            for t in [softThreshold, hardThreshold] where !(t > 0 && t <= 1) { throw PoolValidationError.thresholdOutOfRange(t) }
            if softThreshold >= hardThreshold { throw PoolValidationError.thresholdsOutOfOrder(soft: softThreshold, hard: hardThreshold) }
        case .local:
            if concurrencyCap < 1 { throw PoolValidationError.capBelowOne(concurrencyCap) }
        }
    }
}

/// A real refusal from the vendor: a 429, codex `rate_limit_exceeded`, a non-allowed
/// `rate_limit_event`, the fleet's rate-limit `apiError`. It overrides any meter (L3-U §3).
public struct Rejection: Equatable, Sendable {
    public var at: Date
    /// When the vendor said it lifts, if it said.
    public var until: Date?
    public var source: String
    public init(at: Date, until: Date?, source: String) { self.at = at; self.until = until; self.source = source }

    /// `until`, or the 15-minute backoff when the refusal named no time.
    public var expiry: Date { until ?? at.addingTimeInterval(HeadroomPolicy.rejectionBackoff) }
}

/// Reading + rejection + thresholds + clock → the account's state. Pure, so the ledger, the
/// popover and the tests all agree by construction.
public enum HeadroomPolicy {
    public static let freshness: TimeInterval = 30 * 60
    public static let rejectionBackoff: TimeInterval = 15 * 60

    /// What a window reads now. A fresh reading stands as measured, except that a window whose
    /// reset time has passed since it was read is empty: the vendor rolled it over and the idle
    /// tab that reported it will not say so. A stale reading holds each window's last value until
    /// that window resets, then reads 0 (decision 2026-10-25, the maintainer) — usage never falls inside a
    /// window, and a meter that blanks to "unknown" after thirty idle minutes tells the user
    /// nothing. A stale window with no reset time has no end to hold until, so it is dropped (nil).
    /// A reset time at or before the reading's own `readAt` is a disagreement between the vendor's
    /// clock and ours — or a status line replaying old limits under a new `readAt`
    /// (`CapacityLedger.merged`) — so a fresh number stands and a stale one is past its reset.
    public static func effectiveUtilization(of window: UsageWindow, readAt: Date, now: Date) -> Double? {
        let fresh = isFresh(readAt: readAt, now: now)
        guard let resets = window.resetsAt else { return fresh ? window.utilization : nil }
        if resets > now { return window.utilization }
        return resets > readAt || !fresh ? 0 : window.utilization
    }

    public static func isFresh(_ reading: UsageReading, now: Date) -> Bool {
        isFresh(readAt: reading.readAt, now: now)
    }

    /// Age is clamped at zero: a reading stamped slightly in the future is simply new.
    public static func isFresh(readAt: Date, now: Date) -> Bool {
        max(0, now.timeIntervalSince(readAt)) <= freshness
    }

    public static func evaluate(account: AccountRef, reading: UsageReading?, rejection: Rejection?,
                                soft: Double, hard: Double, now: Date) -> AccountHeadroom {
        if let rejection, now < rejection.expiry {
            return AccountHeadroom(account: account, worstUtilization: 1, state: .overHard, resetsAt: rejection.expiry)
        }
        let unknown = AccountHeadroom(account: account, worstUtilization: nil, state: .unknown, resetsAt: nil)
        guard let reading else { return unknown }
        // Every window that still projects counts, fresh or stale (see `effectiveUtilization`).
        // Radify, 2026-10-15: weekly maxed in two days, nothing ran on it since, and its reading
        // aged into `unknown`, which `LeasePolicy` leases right after any under-soft member. A
        // stale reading now holds until its window resets, so that account stays over until then.
        let scored = reading.windows.compactMap { window in
            effectiveUtilization(of: window, readAt: reading.readAt, now: now).map { (window, $0) }
        }
        guard let worst = scored.max(by: { $0.1 < $1.1 }) else { return unknown }
        let state: HeadroomState = worst.1 >= hard ? .overHard : worst.1 >= soft ? .overSoft : .underSoft
        return AccountHeadroom(account: account, worstUtilization: worst.1, state: state,
                               resetsAt: worst.0.resetsAt.flatMap { $0 > now ? $0 : nil })
    }
}
