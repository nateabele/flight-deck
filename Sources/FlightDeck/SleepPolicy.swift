import Foundation

struct SleepCandidate {
    var id: UUID
    var activity: SessionActivity
    var isSelected: Bool
    var reportsBackgroundWork: Bool
    var hasLiveDescendants: Bool
    var idleSince: Date?
    var isDaemonized: Bool
    var isAsleep: Bool
}

enum SleepDecision: Equatable { case sleep; case ineligible(String) }

/// Pure eligibility. Check order is stable so the `ineligible` reason is deterministic
/// (useful in logs/tests). All predicates must pass for `.sleep`.
struct SleepPolicy {
    let idleThreshold: TimeInterval

    func evaluate(_ c: SleepCandidate, now: Date) -> SleepDecision {
        if c.isAsleep { return .ineligible("already-asleep") }
        if !c.isDaemonized { return .ineligible("no-daemon") }
        if c.isSelected { return .ineligible("selected") }
        if c.activity == .busy { return .ineligible("busy") }
        if c.reportsBackgroundWork || c.hasLiveDescendants { return .ineligible("background-work") }
        guard let since = c.idleSince, now.timeIntervalSince(since) >= idleThreshold else {
            return .ineligible("not-idle-long-enough")
        }
        return .sleep
    }
}
