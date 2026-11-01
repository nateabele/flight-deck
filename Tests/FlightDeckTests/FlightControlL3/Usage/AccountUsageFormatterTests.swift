import XCTest
import IntakeKit
@testable import FlightDeck

/// The Accounts row's two-line usage cluster is decided here, not in SwiftUI: which windows it
/// shows, what each says, and what the tooltip holds for the ones it leaves out.
final class AccountUsageFormatterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// A Sunday, so "Thu 9 AM" below is four days out.
    private let now = usageISO("2026-10-04T12:00:00Z")

    private func ledger(pools: [CapacityPool]? = nil, reading: UsageReading? = nil) -> CapacityLedger {
        let l = CapacityLedger(now: { self.now })
        l.configure(pools: pools ?? [CapacityPool.hosted(id: "claude-default", label: "Claude default", agent: .claude, accounts: [UsageRefs.workID])],
                    accounts: [UsageRefs.work])
        if let reading { l.ingest(reading) }
        return l
    }

    private func reading(_ windows: [UsageWindow], at: Date? = nil, rejection: Bool = false) -> UsageReading {
        UsageReading(account: UsageRefs.work, windows: windows, readAt: at ?? now.addingTimeInterval(-60),
                     source: "claude status line", hardRejection: rejection)
    }

    private func model(_ l: CapacityLedger) -> AccountUsageRowModel {
        MeterFormatter.accountUsage(account: UsageRefs.workID, ledger: l, now: now, timeZone: utc, locale: posix)
    }

    private func lines(_ m: AccountUsageRowModel, file: StaticString = #filePath, line: UInt = #line) -> [AccountUsageLine] {
        guard case .lines(let lines) = m.body else { XCTFail("expected lines, got \(m.body)", file: file, line: line); return [] }
        return lines
    }

    func testWindowLabels() {
        XCTAssertEqual(MeterFormatter.windowLabel("five_hour"), "5h")
        XCTAssertEqual(MeterFormatter.windowLabel("seven_day"), "wk")
        XCTAssertEqual(MeterFormatter.windowLabel("seven_day_opus"), "Opus wk")
        XCTAssertEqual(MeterFormatter.windowLabel("seven_day_sonnet"), "Sonnet wk")
        XCTAssertEqual(MeterFormatter.windowLabel("60m"), "1h")
        XCTAssertEqual(MeterFormatter.windowLabel("90m"), "90m")
        XCTAssertEqual(MeterFormatter.windowLabel("codex_other:five_hour"), "5h")
        XCTAssertEqual(MeterFormatter.windowLabel("credits_balance"), "credit")
        XCTAssertEqual(MeterFormatter.windowLabel("gemini-5h"), "5h")
        XCTAssertEqual(MeterFormatter.windowLabel("gemini-weekly"), "wk")
        XCTAssertEqual(MeterFormatter.windowLabel("rejected"), "Refused")
        XCTAssertEqual(MeterFormatter.windowLabel("retry-after"), "Retry")
    }

    func testFreshTwoWindows() {
        let l = ledger(reading: reading([
            UsageWindow(name: "five_hour", utilization: 0.62, resetsAt: usageISO("2026-10-04T15:40:00Z")),
            UsageWindow(name: "seven_day", utilization: 0.18, resetsAt: usageISO("2026-10-08T09:00:00Z")),
        ]))
        let rows = lines(model(l))
        XCTAssertEqual(rows.map(\.label), ["5h", "wk"])
        XCTAssertEqual(rows.map(\.percentText), ["62%", "18%"])
        XCTAssertEqual(rows.map(\.resetText), ["3:40 PM", "Thu 9 AM"])
    }

    func testIdleWindowPastResetReadsZeroAndSaysReset() {
        let l = ledger(reading: reading([
            UsageWindow(name: "five_hour", utilization: 0.9, resetsAt: usageISO("2026-10-01T15:00:00Z")),
            UsageWindow(name: "seven_day", utilization: 0.4, resetsAt: usageISO("2026-10-08T09:00:00Z")),
        ], at: usageISO("2026-10-01T12:00:00Z")))
        let m = model(l)
        let rows = lines(m)
        XCTAssertEqual(rows[0].label, "5h")
        XCTAssertEqual(rows[0].percentText, "0%")
        XCTAssertEqual(rows[0].resetText, "reset")
        XCTAssertEqual(rows[1].label, "wk")
        XCTAssertEqual(rows[1].percentText, "40%")
        XCTAssertTrue(m.tooltip.contains("held from last reading"), m.tooltip)
    }

    func testFreshWindowResetBeforeReadAtKeepsItsNumberNotReset() {
        let readAt = now.addingTimeInterval(-60)
        let l = ledger(reading: reading([UsageWindow(name: "five_hour", utilization: 0.62, resetsAt: readAt.addingTimeInterval(-30))], at: readAt))
        let m = model(l)
        let row = lines(m)[0]
        XCTAssertEqual(row.percentText, "62%")
        XCTAssertNotEqual(row.resetText, "reset")
        XCTAssertFalse(m.tooltip.contains("0% · reset"), m.tooltip)
    }

    func testNoReadingSaysNoUsageYet() {
        let m = model(ledger())
        XCTAssertEqual(m.body, .message("No usage yet"))
        XCTAssertEqual(m.tooltip, "No usage yet")
    }

    func testStaleNoResetWindowsGoToTheTooltipOnly() {
        let l = ledger(reading: reading([
            UsageWindow(name: "five_hour", utilization: 0.5, resetsAt: usageISO("2026-10-04T15:00:00Z")),
            UsageWindow(name: "credits", utilization: 0.99, resetsAt: nil),
        ], at: usageISO("2026-10-04T08:00:00Z")))
        let m = model(l)
        XCTAssertEqual(lines(m).map(\.label), ["5h"])
        XCTAssertTrue(m.tooltip.contains("credit"), m.tooltip)
        XCTAssertTrue(m.tooltip.contains("no reset time"), m.tooltip)
    }

    func testOnlyNoResetWindowsStaleSaysNoCurrentReading() {
        let l = ledger(reading: reading([UsageWindow(name: "credits", utilization: 0.99, resetsAt: nil)],
                                        at: usageISO("2026-10-04T08:00:00Z")))
        XCTAssertEqual(model(l).body, .message("No current reading"))
    }

    /// Claude off a subscription reports a reading with no windows: it is current, it just has no
    /// limits to show, so "No current reading" would be untrue.
    func testFreshReadingWithNoWindowsSaysNoLimitsReported() {
        XCTAssertEqual(model(ledger(reading: reading([]))).body, .message("No limits reported"))
    }

    /// A headless seat reports its refusal as a reading with a `rejected` window. The ledger files
    /// that reading as the rejection, never as the account's reading, so the row's label stays the
    /// limit that was hit and the percent column alone says Refused — not "Refused Refused".
    func testTheRefusalWindowIsNotTheRowsLabel() {
        let reset = usageISO("2026-10-04T15:40:00Z")
        let l = ledger(reading: reading([UsageWindow(name: "five_hour", utilization: 0.5, resetsAt: reset)]))
        l.ingest(reading([UsageWindow(name: "rejected", utilization: 1, resetsAt: reset)], rejection: true))
        let m = model(l)
        XCTAssertEqual(lines(m).map(\.label), ["5h"])
        XCTAssertEqual(lines(m)[0].percentText, "Refused")
        XCTAssertFalse(m.tooltip.contains("Refused 100%"), m.tooltip)
    }

    func testNoFiveHourFallsBackToFirstByName() {
        let reset = usageISO("2026-10-08T09:00:00Z")
        let l = ledger(reading: reading([
            UsageWindow(name: "gemini-weekly", utilization: 0.3, resetsAt: reset),
            UsageWindow(name: "gemini-5h", utilization: 0.1, resetsAt: reset),
        ]))
        let rows = lines(model(l))
        XCTAssertEqual(rows.map(\.label), ["5h", "wk"])
        XCTAssertEqual(rows.map(\.percentText), ["10%", "30%"])
    }

    func testRejectionWithNoReadingSaysRefusedInTheTooltip() {
        let l = ledger(reading: reading([], rejection: true))
        let m = model(l)
        XCTAssertEqual(lines(m)[0].percentText, "Refused")
        XCTAssertTrue(m.tooltip.hasPrefix("Refused by the provider · claude status line · until "), m.tooltip)
    }

    func testActiveRejectionShowsRefused() {
        let l = ledger(reading: reading([UsageWindow(name: "five_hour", utilization: 0.5, resetsAt: usageISO("2026-10-04T15:40:00Z"))]))
        l.ingest(reading([UsageWindow(name: "five_hour", utilization: 1, resetsAt: usageISO("2026-10-04T15:40:00Z"))], rejection: true))
        let m = model(l)
        XCTAssertTrue(m.tooltip.hasPrefix("Refused by the provider · claude status line · until Sun Oct 4, 3:40 PM"), m.tooltip)
        XCTAssertTrue(m.tooltip.contains("5h 50%"), m.tooltip)
        let rows = lines(m)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].percentText, "Refused")
        XCTAssertEqual(rows[0].state, .overHard)
        XCTAssertEqual(rows[0].resetText, "3:40 PM")
    }

    func testStrictestPoolThresholdsColourTheRow() {
        let a = CapacityPool.hosted(id: "a", label: "A", agent: .claude, accounts: [UsageRefs.workID], soft: 0.8, hard: 0.95)
        let b = CapacityPool.hosted(id: "b", label: "B", agent: .claude, accounts: [UsageRefs.workID], soft: 0.5, hard: 0.9)
        let l = ledger(pools: [a, b], reading: reading([UsageWindow(name: "five_hour", utilization: 0.6, resetsAt: usageISO("2026-10-04T15:40:00Z"))]))
        let m = model(l)
        XCTAssertEqual(m.soft, 0.5)
        XCTAssertEqual(m.hard, 0.9)
        XCTAssertEqual(lines(m).first?.state, .overSoft)
    }

    func testThreeWindowsShowFiveHourAndWorstOfTheRest() {
        let reset = usageISO("2026-10-08T09:00:00Z")
        let l = ledger(reading: reading([
            UsageWindow(name: "five_hour", utilization: 0.1, resetsAt: reset),
            UsageWindow(name: "seven_day", utilization: 0.3, resetsAt: reset),
            UsageWindow(name: "seven_day_opus", utilization: 0.9, resetsAt: reset),
        ]))
        let m = model(l)
        XCTAssertEqual(lines(m).map(\.label), ["5h", "Opus wk"])
        XCTAssertTrue(m.tooltip.contains("wk 30%"), m.tooltip)
    }
}
