import Foundation

/// The spend limits a cloud machine must fit inside. `nil` caps mean "no cap"; the guardrails
/// (concurrency, TTL, idle, instance-type allowlist) always apply.
public struct BudgetSettings: Codable, Sendable, Equatable {
    public var monthlyCapUSD: Double?
    public var perMachineCapUSD: Double?
    public var warnFraction: Double
    public var maxConcurrent: Int
    public var maxTTL: Duration
    public var maxIdle: Duration
    /// Cloud ("aws"/"gcp") -> glob patterns an instance type must match.
    public var allowedTypes: [String: [String]]

    public static let `default` = BudgetSettings(
        monthlyCapUSD: 50, perMachineCapUSD: 10, warnFraction: 0.8, maxConcurrent: 2,
        maxTTL: Duration(seconds: 12 * 3600), maxIdle: Duration(seconds: 2 * 3600),
        allowedTypes: [
            "aws": ["t3.*", "t4g.*", "m6i.*large", "m7g.*large", "c7g.*large", "m6i.2xlarge", "m6i.4xlarge",
                    "m7g.2xlarge", "m7g.4xlarge", "g6.xlarge", "g6.2xlarge", "g5.xlarge"],
            "gcp": ["e2-*", "n2-standard-2", "n2-standard-4", "n2-standard-8", "n2-standard-16",
                    "t2a-standard-*", "g2-standard-4", "g2-standard-8"],
        ])

    public var hasDollarCap: Bool { monthlyCapUSD != nil || perMachineCapUSD != nil }
}

public enum BudgetVerdict: Equatable, Sendable {
    case allowed
    /// A human sentence naming the numbers and the setting to change.
    case refused(String)
}

/// Pure cost arithmetic and cap decisions. Worst case is rate x TTL: the TTL is the longest the
/// machine can run, so it is the most the launch can ever cost.
public enum CostModel {
    public static func worstCase(hourly: Double, ttl: Duration) -> Double {
        hourly * Double(ttl.seconds) / 3600
    }

    private static func usd(_ x: Double) -> String { String(format: "$%.2f", x) }

    public static func checkLaunch(hourly: Double?, ttl: Duration, idle: Duration, instanceType: String,
                                   cloud: String, running: Int, monthToDate: Double,
                                   settings: BudgetSettings) -> BudgetVerdict {
        let allowed = settings.allowedTypes[cloud] ?? []
        guard allowed.contains(where: { globMatches($0, instanceType) }) else {
            return .refused("\(instanceType) is not an allowed \(cloud) instance type; add a pattern in Settings → Cloud → Budget → Allowed types.")
        }
        guard running < settings.maxConcurrent else {
            return .refused("\(running) machines are already running, the limit is \(settings.maxConcurrent); raise Max concurrent in Settings → Cloud → Budget.")
        }
        guard ttl <= settings.maxTTL else {
            return .refused("A TTL of \(ttl.formatted) is over the \(settings.maxTTL.formatted) maximum; raise Max TTL in Settings → Cloud → Budget.")
        }
        guard idle <= settings.maxIdle else {
            return .refused("An idle limit of \(idle.formatted) is over the \(settings.maxIdle.formatted) maximum; raise Max idle in Settings → Cloud → Budget.")
        }
        guard let hourly else {
            return settings.hasDollarCap
                ? .refused("Can't price this machine, so a dollar cap can't be enforced; set max_hourly or clear the caps in Settings → Cloud → Budget.")
                : .allowed
        }
        let worst = worstCase(hourly: hourly, ttl: ttl)
        if let cap = settings.perMachineCapUSD, worst > cap + 1e-9 {
            return .refused("Worst case \(usd(worst)) (\(usd(hourly))/h for \(ttl.formatted)) is over the \(usd(cap)) per-machine cap; shorten the TTL or raise Per-machine cap in Settings → Cloud → Budget.")
        }
        if let cap = settings.monthlyCapUSD, monthToDate + worst > cap + 1e-9 {
            return .refused("\(usd(monthToDate)) spent this month plus a \(usd(worst)) worst case is over the \(usd(cap)) monthly cap; raise Monthly cap in Settings → Cloud → Budget.")
        }
        return .allowed
    }

    public enum RunningState: Equatable, Sendable { case ok; case warn(String); case destroy(String) }

    public static func checkRunning(spent: Double, monthToDate: Double, settings: BudgetSettings) -> RunningState {
        if let cap = settings.perMachineCapUSD, spent >= cap {
            return .destroy("This machine has spent \(usd(spent)), reaching the \(usd(cap)) per-machine cap.")
        }
        if let cap = settings.monthlyCapUSD, monthToDate >= cap {
            return .destroy("This month's spend of \(usd(monthToDate)) has reached the \(usd(cap)) monthly cap.")
        }
        if let cap = settings.perMachineCapUSD, spent >= settings.warnFraction * cap {
            return .warn("This machine has spent \(usd(spent)) of its \(usd(cap)) per-machine cap.")
        }
        if let cap = settings.monthlyCapUSD, monthToDate >= settings.warnFraction * cap {
            return .warn("This month's spend of \(usd(monthToDate)) is near the \(usd(cap)) monthly cap.")
        }
        return .ok
    }

    /// `*` matches any run of characters (including none); everything else is literal.
    public static func globMatches(_ pattern: String, _ value: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        guard parts.count > 1 else { return pattern == value }
        var rest = Substring(value)
        guard let first = parts.first, rest.hasPrefix(first) else { return false }
        rest = rest.dropFirst(first.count)
        for mid in parts.dropFirst().dropLast() {
            guard let r = rest.range(of: mid) else { return false }
            rest = rest[r.upperBound...]
        }
        let last = parts.last!
        return rest.hasSuffix(last)
    }
}
