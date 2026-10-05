import XCTest
import IntakeKit
@testable import FlightDeck

/// What a meter says is decided here, not in SwiftUI, so it can be pinned: the percentages, the
/// reset time in the viewer's clock, the source and its age, "no reading" versus "stale", and
/// when the sidebar row shows a meter at all (only past soft).
final class MeterFormatterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    private let pool = CapacityPool.hosted(id: "claude-default", label: "Claude default", harness: "claude", accounts: [UsageRefs.workID, UsageRefs.spareID])

    func testAgeWording() {
        XCTAssertEqual(MeterFormatter.age(5), "just now")
        XCTAssertEqual(MeterFormatter.age(-30), "just now", "a reading from slightly ahead of this clock is new")
        XCTAssertEqual(MeterFormatter.age(180), "3 min ago")
        XCTAssertEqual(MeterFormatter.age(2 * 3600 + 5), "2 h ago")
        XCTAssertEqual(MeterFormatter.age(3 * 86_400), "3 d ago")
    }

    func testResetTextUsesTheViewersClock() {
        let now = usageISO("2026-10-04T19:00:00Z")
        XCTAssertEqual(MeterFormatter.resetText(usageISO("2026-10-04T23:00:00Z"), now: now, timeZone: utc, locale: posix), "resets 11:00 PM")
        XCTAssertEqual(MeterFormatter.resetText(usageISO("2026-10-09T00:00:00Z"), now: now, timeZone: utc, locale: posix), "resets Fri 12:00 AM")
        XCTAssertNil(MeterFormatter.resetText(usageISO("2026-10-04T18:00:00Z"), now: now, timeZone: utc, locale: posix), "a past reset says nothing useful")
        XCTAssertNil(MeterFormatter.resetText(nil, now: now, timeZone: utc, locale: posix))
    }

    func testAFreshAccount() {
        let now = usageISO("2026-10-04T19:00:00Z")
        let reading = UsageReading(account: UsageRefs.work, windows: [UsageWindow(name: "five_hour", utilization: 0.824, resetsAt: usageISO("2026-10-04T23:00:00Z"))],
                                   readAt: now.addingTimeInterval(-180), source: "claude mod", hardRejection: false)
        let h = AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.824, state: .overSoft, resetsAt: usageISO("2026-10-04T23:00:00Z"))
        let m = MeterFormatter.account(h, pool: pool, reading: reading, error: nil, now: now, timeZone: utc, locale: posix)
        XCTAssertEqual(m.percentText, "82%")
        XCTAssertEqual(m.soft, 0.80); XCTAssertEqual(m.hard, 0.95)
        XCTAssertEqual(m.resetText, "resets 11:00 PM")
        XCTAssertEqual(m.sourceText, "claude mod · 3 min ago")
        XCTAssertNil(m.detail)
        XCTAssertEqual(m.accessibilityValue, "82 percent used, past its soft limit, resets 11:00 PM")
    }

    func testUnknownSaysWhy() {
        let now = Date()
        let h = AccountHeadroom(account: UsageRefs.spare, worstUtilization: nil, state: .unknown, resetsAt: nil)
        XCTAssertEqual(MeterFormatter.account(h, pool: pool, reading: nil, error: nil, now: now).detail, "no reading")
        let stale = UsageRefs.reading(UsageRefs.spare, 0.5, at: now.addingTimeInterval(-3600))
        XCTAssertEqual(MeterFormatter.account(h, pool: pool, reading: stale, error: nil, now: now).detail, "reading is stale")
        XCTAssertEqual(MeterFormatter.account(h, pool: pool, reading: nil, error: "Codex app-server: transportClosed", now: now).detail,
                       "Codex app-server: transportClosed", "a source error is the more useful sentence")
        let m = MeterFormatter.account(h, pool: pool, reading: nil, error: nil, now: now)
        XCTAssertNil(m.fraction); XCTAssertEqual(m.percentText, "—"); XCTAssertEqual(m.accessibilityValue, "no reading")
    }

    func testPoolsAndTheLocalNote() {
        let ledger = CapacityLedger()
        let local = CapacityPool.local(id: "ollama", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        ledger.configure(pools: [pool, local], accounts: [UsageRefs.work, UsageRefs.spare])
        _ = ledger.lease(pool: "ollama")
        let models = MeterFormatter.pools(ledger, now: Date())
        XCTAssertEqual(models.map(\.id), ["claude-default", "ollama"])
        XCTAssertEqual(models[0].accounts.map(\.label), ["Work", "Spare"])
        XCTAssertEqual(models[1].note, "1 of 2 agents running on http://localhost:11434. Load from outside Flight Deck is not visible.")
        XCTAssertTrue(models[1].isLocal)
    }

    func testTheRowMeterAppearsOnlyPastSoftAndPicksTheWorstPool() {
        let ledger = CapacityLedger()
        let strict = CapacityPool.hosted(id: "strict", label: "Strict", harness: "claude", accounts: [UsageRefs.workID], soft: 0.5, hard: 0.6)
        ledger.configure(pools: [pool, strict], accounts: [UsageRefs.work, UsageRefs.spare])
        let now = Date()
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.40, at: now))
        XCTAssertNil(MeterFormatter.rowMeter(account: UsageRefs.workID, ledger: ledger, now: now))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.62, at: now.addingTimeInterval(1)))
        let m = MeterFormatter.rowMeter(account: UsageRefs.workID, ledger: ledger, now: now.addingTimeInterval(1))
        XCTAssertEqual(m?.state, .overHard, "the strict pool rates it worst")
        XCTAssertEqual(m?.hard, 0.6)
        XCTAssertNil(MeterFormatter.rowMeter(account: UsageRefs.spareID, ledger: ledger, now: now), "unknown draws nothing")
    }
}
