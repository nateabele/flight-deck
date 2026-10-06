import Foundation
import IntakeKit

/// Readings from headless `claude -p` intake seats, whose stream carries a `rate_limit_event`
/// per API call (folded into `SeatActivity` by Task 4's parser change).
///
/// A seat's activity is re-read on every tick with the same numbers, so a reading is produced
/// once per seat event (`startedAt` + `lastEventAt`), not once per tick — otherwise every tick
/// would look like a fresh reading and an idle seat would keep its account "fresh" forever.
@MainActor
final class HeadlessClaudeUsageSource {
    private var seen: Set<String> = []

    func readings(from activities: [SeatActivity], account: AccountRef) -> [UsageReading] {
        var out: [UsageReading] = []
        for a in activities where a.harness == .claude && (a.rateLimitWindows != nil || a.rateLimitedAt != nil) {
            let at = a.lastEventAt ?? a.startedAt
            let key = "\(a.startedAt.timeIntervalSince1970)|\(at.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { continue }
            // rateLimitedAt, not rateLimitStatus: the status string stays "rejected" after the seat
            // recovers and would keep reporting a working account as over the limit.
            if a.rateLimitedAt != nil {
                // A reset at or before the event is already over: kept, the refusal would expire
                // the moment it is recorded and the account would look usable. Dropping it
                // gives the rejection its default backoff instead.
                let until = a.rateLimitResetsAt.flatMap { $0 > at ? $0 : nil }.map { [UsageWindow(name: "rejected", utilization: 1, resetsAt: $0)] } ?? []
                out.append(UsageReading(account: account, windows: until, readAt: at, source: "claude headless", hardRejection: true))
            } else if let windows = a.rateLimitWindows {
                out.append(UsageReading(account: account, windows: windows, readAt: at, source: "claude headless", hardRejection: false))
            }
        }
        // Bounded: keys are only needed for seats still being re-read.
        if seen.count > 4_096 { seen.removeAll() }
        return out
    }
}
