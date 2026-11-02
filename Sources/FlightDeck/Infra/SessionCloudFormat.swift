import FleetKit
import Foundation
import HostKit

/// The decisions behind the sidebar's cloud icon and its popover, kept pure and SwiftUI-free so
/// they are unit-tested rather than eyeballed. Every figure that moves with the clock takes
/// `now`: the popover's `TimelineView` supplies it, a test supplies a constant.
enum SessionCloudFormat {
    /// How far "Extend" moves a machine's deadline.
    static let extendStep: TimeInterval = 3600

    /// Where the budget bar turns to the warning colour, matching Settings → Cloud's default
    /// "Warn at 80% of a cap".
    static let warnFraction = 0.8

    static func usd(_ x: Double) -> String { CostModel.usd(x) }

    // MARK: Budget

    enum BudgetLevel: Equatable { case ok, warning, exhausted }

    /// How much of the cap is used, clamped to 0...1 for the bar. A zero cap is all used.
    static func budgetFraction(spent: Double, cap: Double) -> Double {
        guard cap > 0 else { return 1 }
        return min(1, max(0, spent / cap))
    }

    /// Exhausted once the spend reaches the cap or the monitor's exhaustion time has passed
    /// (the machines are being destroyed then); a warning from `warnFraction` up.
    static func budgetLevel(_ cloud: WireSessionCloud, at now: Date) -> BudgetLevel? {
        guard let cap = cloud.budgetCapUsd else { return nil }
        let spent = cloud.spent(at: now)
        if spent >= cap || cloud.budgetExhaustsAt.map({ $0 <= now }) == true { return .exhausted }
        return budgetFraction(spent: spent, cap: cap) >= warnFraction ? .warning : .ok
    }

    /// "runs out in 1h 05m", "used up", or nil when there is no projected exhaustion.
    static func exhaustionText(_ cloud: WireSessionCloud, at now: Date) -> String? {
        guard let at = cloud.budgetExhaustsAt else { return nil }
        return at <= now ? "used up" : "runs out in \(span(at.timeIntervalSince(now)))"
    }

    // MARK: Machines

    /// Extend moves only the controller's deadline, and never past the machine's own timer:
    /// the same test `InfraService.extend` applies (with its one second of slack), so the
    /// button is disabled exactly when the service would refuse.
    static func canExtend(_ machine: WireCloudMachine) -> Bool {
        guard ["ready", "idle"].contains(machine.state) else { return false }
        let limit = machine.machineDeadline ?? machine.deadline
        return machine.deadline.addingTimeInterval(extendStep) <= limit.addingTimeInterval(1)
    }

    /// The tooltip on Extend: why it is off, or what it does.
    static func extendHelp(_ machine: WireCloudMachine) -> String {
        if !["ready", "idle"].contains(machine.state) {
            return "Only a running machine can be extended."
        }
        if !canExtend(machine) {
            return "The machine's own time limit ends at \((machine.machineDeadline ?? machine.deadline).formatted(date: .omitted, time: .shortened)); it cannot run past that."
        }
        return "Keep the machine for one more hour."
    }

    /// "aws · t3.large · us-east-1 · public", skipping what a user module leaves empty.
    static func detailLine(_ machine: WireCloudMachine) -> String {
        [machine.cloud, machine.instanceType, machine.region, machine.network]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "$0.0832/h" or "price unknown" for a machine that cannot be priced.
    static func rateText(_ machine: WireCloudMachine) -> String {
        machine.hourlyUsd.map { "\(usd($0))/h" } ?? "price unknown"
    }

    /// "2h 10m left", or "past its deadline" while the Reaper has yet to act.
    static func ttlText(_ machine: WireCloudMachine, at now: Date) -> String {
        machine.deadline <= now ? "past its deadline" : "\(span(machine.deadline.timeIntervalSince(now))) left"
    }

    static func upText(_ machine: WireCloudMachine, at now: Date) -> String {
        "up \(span(now.timeIntervalSince(machine.createdAt)))"
    }

    // MARK: Summary

    /// The icon's VoiceOver label: "2 cloud machines, $1.20 of $20.00 budget".
    static func accessibilitySummary(_ cloud: WireSessionCloud, at now: Date) -> String {
        let count = cloud.machines.count
        var text = "\(count) cloud machine\(count == 1 ? "" : "s"), "
        let spent = usd(cloud.spent(at: now))
        if let cap = cloud.budgetCapUsd {
            text += "\(spent) of \(usd(cap)) budget"
        } else {
            text += "\(spent) spent, no budget"
        }
        switch cloud.badge {
        case .failed: text += ", needs attention"
        case .busy: text += ", provisioning"
        case .ready: break
        }
        return text
    }

    // MARK: Time

    /// The two largest units of a duration: "3h 05m", "12m 05s", "45s". Never negative.
    static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        if s >= 60 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return "\(s)s"
    }
}
