import FleetKit
import Foundation

/// The pure decisions behind the cloud icon and `SessionCloudScreen`: what a figure reads as,
/// when a bar turns amber or red, whether a machine can be extended. Pulled out of the views so
/// `CloudStyleTests` can assert them without rendering anything, as `SessionInfoStyle` does.
///
/// Everything that moves with the clock takes `now` and extrapolates from the cloud's baseline
/// (`WireSessionCloud.spent(at:)`), because the Mac only re-sends on a structural change.
enum CloudStyle {
    /// How long one `Extend` moves a machine's deadline.
    static let extendSeconds = 3600

    // MARK: Figures

    /// `$4.20`; a sub-ten-cent rate or total keeps a third decimal so a cheap machine does not
    /// read as free.
    static func money(_ usd: Double) -> String {
        usd > 0 && usd < 0.1 ? String(format: "$%.3f", usd) : String(format: "$%.2f", usd)
    }

    static func rate(_ usd: Double?) -> String {
        usd.map { money($0) + "/h" } ?? "unpriced"
    }

    /// `2h 14m`, `14m 05s`, `42s`. Never negative.
    static func duration(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval.rounded(.down)))
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m \(String(format: "%02d", s))s" }
        return "\(s)s"
    }

    /// The time left on a deadline, or `expired`.
    static func countdown(to deadline: Date, now: Date) -> String {
        deadline > now ? duration(deadline.timeIntervalSince(now)) : "expired"
    }

    // MARK: Budget

    enum Level: Equatable { case ok, warning, exhausted }

    /// Where a bar of `fraction` (spent over cap) stands: amber from 80%, red at the cap.
    static func level(fraction: Double) -> Level {
        fraction >= 1 ? .exhausted : fraction >= 0.8 ? .warning : .ok
    }

    /// The session budget's spent-over-cap, uncapped (a machine can overshoot before the
    /// Reaper lands); nil with no budget or a zero cap.
    static func budgetFraction(_ cloud: WireSessionCloud, now: Date) -> Double? {
        guard let cap = cloud.budgetCapUsd, cap > 0 else { return nil }
        return cloud.spent(at: now) / cap
    }

    static func budgetLevel(_ cloud: WireSessionCloud, now: Date) -> Level? {
        guard let fraction = budgetFraction(cloud, now: now) else { return nil }
        if let exhausts = cloud.budgetExhaustsAt, exhausts <= now { return .exhausted }
        return level(fraction: fraction)
    }

    /// `runs out in 2h 14m`; `budget used up` once gone; nil when no budget, or when every
    /// machine's deadline comes first (the Mac sends no exhaustion date then).
    static func runsOut(_ cloud: WireSessionCloud, now: Date) -> String? {
        guard cloud.budgetCapUsd != nil else { return nil }
        if budgetLevel(cloud, now: now) == .exhausted { return "budget used up" }
        return cloud.budgetExhaustsAt.map { "runs out in \(duration($0.timeIntervalSince(now)))" }
    }

    static func monthFraction(_ cloud: WireSessionCloud) -> Double? {
        guard let cap = cloud.monthCapUsd, cap > 0 else { return nil }
        return cloud.monthUsd / cap
    }

    // MARK: Machines

    /// `aws · g5.xlarge · us-east-1 · tailnet`; a user module names no instance type.
    static func detail(_ machine: WireCloudMachine) -> String {
        [machine.cloud, machine.instanceType, machine.region, machine.network]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func stateLabel(_ machine: WireCloudMachine) -> String {
        machine.state.prefix(1).uppercased() + machine.state.dropFirst()
    }

    static func isFailed(_ machine: WireCloudMachine) -> Bool {
        machine.state == "failed" || machine.state == "orphaned"
    }

    /// Whether one more hour still fits under the machine's own timer. Mirrors the Mac's rule
    /// (`infra_refused`: extend past the machine's own TTL), so the button is off rather than
    /// sending a request that is certain to be refused.
    static func canExtend(_ machine: WireCloudMachine) -> Bool {
        machine.deadline.addingTimeInterval(TimeInterval(extendSeconds)) <= (machine.machineDeadline ?? machine.deadline)
    }

    static func extendFootnote(_ machine: WireCloudMachine, now: Date) -> String? {
        guard !canExtend(machine) else { return nil }
        let limit = machine.machineDeadline ?? machine.deadline
        return "Can't extend: this machine's own timer ends in \(countdown(to: limit, now: now)), less than an hour past its deadline."
    }

    static func destroyMessage(_ machine: WireCloudMachine) -> String {
        "The cloud machine and everything on it is deleted. Runs on \(machine.name) stop."
    }

    // MARK: Requests

    static let updateMac = "Update Flight Deck on your Mac to control cloud machines from the phone."

    /// What to tell the person when an `infra.*` request did not end well.
    static func failureText(_ error: InfraRequestError) -> String {
        if error.isMacTooOld { return updateMac }
        switch error {
        case .disconnected:
            return "Lost the connection to your Mac. If a destroy was running it carries on there."
        case .server(let code, let message):
            if let message, !message.isEmpty { return message }
            return "Your Mac refused (\(code))."
        }
    }

    // MARK: Icon

    static func iconName(_ cloud: WireSessionCloud) -> String {
        cloud.badge == .failed ? "exclamationmark.icloud.fill" : "cloud.fill"
    }

    static func iconLabel(_ cloud: WireSessionCloud) -> String {
        let count = cloud.machines.count
        let machines = count == 1 ? "1 cloud machine" : "\(count) cloud machines"
        return cloud.badge == .failed ? "\(machines), needs attention" : machines
    }
}
