import Foundation

/// One session's allowance for the cloud machines it provisions: `capUSD`, counted over the
/// spend of that session's own machines since `since`. Setting a cap keeps `since`; renewing
/// moves it to the renewal, so what was spent before stops counting.
public struct SessionBudget: Codable, Equatable, Sendable {
    public let session: UUID
    public var capUSD: Double
    public var since: Date

    public init(session: UUID, capUSD: Double, since: Date) {
        self.session = session
        self.capUSD = capUSD
        self.since = since
    }
}

/// Pure arithmetic for session budgets. Every input is the ledger's record of the session's
/// own machines, so the same ledger always gives the same answer: nothing here asks a cloud's
/// billing, which lags by hours.
public enum SessionBudgetModel {
    /// A machine of the session that bills `hourlyUSD` from now until `until`, its deadline.
    public struct Burn: Equatable, Sendable {
        public let hourlyUSD: Double
        public let until: Date

        public init(hourlyUSD: Double, until: Date) {
            self.hourlyUSD = hourlyUSD
            self.until = until
        }
    }

    /// A launch gets at least this long, or it is refused: a machine takes minutes to enroll,
    /// so one the budget would end sooner than this only spends money.
    public static let minimumLife: TimeInterval = 900

    /// The instant the session's spend reaches its cap, if `burns` keep running to their
    /// deadlines at their rates. `now` when nothing is left; nil when every burn ends first.
    /// The rate is piecewise constant, falling as each machine reaches its deadline, so the
    /// instant is exact rather than sampled.
    public static func exhaustion(remaining: Double, burns: [Burn], now: Date) -> Date? {
        guard remaining > 1e-9 else { return now }
        let live = burns.filter { $0.until > now && $0.hourlyUSD > 0 }.sorted { $0.until < $1.until }
        var rate = live.reduce(0) { $0 + $1.hourlyUSD }
        var left = remaining, t = now
        for burn in live {
            let cost = rate * burn.until.timeIntervalSince(t) / 3600
            if cost >= left { return t.addingTimeInterval(left / rate * 3600) }
            left -= cost
            t = burn.until
            rate -= burn.hourlyUSD
        }
        return nil
    }

    public enum Launch: Equatable, Sendable {
        /// Launch with this deadline: the TTL's, or earlier when the budget runs out first.
        case allowed(deadline: Date)
        /// A human sentence naming the numbers and what to do.
        case refused(String)
    }

    /// Whether a machine at `hourly` may start now with a TTL ending at `ttlDeadline`, given
    /// what the session has `remaining` and its other machines' `burns`. The deadline it gets
    /// is when the session's budget runs out with it running, if that comes first: so the
    /// machine's own timer, fixed at creation, ends it there even with this Mac asleep.
    public static func checkLaunch(name: String, hourly: Double?, ttlDeadline: Date, remaining: Double,
                                   capUSD: Double, burns: [Burn], now: Date) -> Launch {
        guard remaining > 1e-9 else {
            return .refused("This session's \(usd(capUSD)) cloud budget is used up; `/budget renew` starts a fresh one.")
        }
        guard let hourly, hourly >= 0 else {
            return .refused("Can't price \(name), so this session's budget can't be enforced; set max_hourly in its recipe.")
        }
        let mine = Burn(hourlyUSD: hourly, until: ttlDeadline)
        guard let end = exhaustion(remaining: remaining, burns: burns + [mine], now: now), end < ttlDeadline else {
            return .allowed(deadline: ttlDeadline)
        }
        let life = end.timeIntervalSince(now)
        guard life >= minimumLife else {
            return .refused("This session's budget has \(usd(remaining)) of \(usd(capUSD)) left, which runs \(name) at \(usd(hourly))/h for only \(minutes(life)) alongside the session's other machines; `/budget <usd>` raises it.")
        }
        return .allowed(deadline: end)
    }

    static func usd(_ x: Double) -> String { CostModel.usd(x) }

    private static func minutes(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60))
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}
