import XCTest
import IntakeKit
@testable import FlightDeck

/// The whole of "may this account take work" reduces to one pure function of a reading, a
/// rejection, two thresholds and the clock. These table-test it over the shared L3-0 timeline
/// and pin the time-based edges a live system hits and a fixture rarely does: staleness, a
/// window resetting under an idle tab, and two clocks that disagree.
final class HeadroomPolicyTests: XCTestCase {
    private let soft = 0.80, hard = 0.95

    private func evaluate(_ r: UsageReading?, rejection: Rejection? = nil, at now: Date) -> AccountHeadroom {
        HeadroomPolicy.evaluate(account: UsageRefs.work, reading: r, rejection: rejection, soft: soft, hard: hard, now: now)
    }

    func testTimelineReadingsCrossSoftThenHard() throws {
        let t = try L3Fixtures.usageTimeline()
        let states = t[0...2].map { evaluate($0, at: $0.readAt.addingTimeInterval(60)).state }
        XCTAssertEqual(states, [.underSoft, .overSoft, .overHard])
        XCTAssertEqual(evaluate(t[1], at: t[1].readAt).worstUtilization ?? 0, 0.82, accuracy: 1e-9)
        XCTAssertEqual(evaluate(t[2], at: t[2].readAt).resetsAt, usageISO("2026-10-04T23:00:00Z"))
        XCTAssertEqual(evaluate(t[4], at: t[4].readAt).state, .underSoft, "after the reset the account is open again")
    }

    func testNoReadingIsUnknownNotEmpty() {
        let h = evaluate(nil, at: Date())
        XCTAssertEqual(h.state, .unknown)
        XCTAssertNil(h.worstUtilization)
    }

    func testAReadingOlderThanThirtyMinutesIsUnknown() {
        let at = usageISO("2026-10-04T18:00:00Z")
        let r = UsageRefs.reading(UsageRefs.work, 0.5, at: at)
        XCTAssertEqual(evaluate(r, at: at.addingTimeInterval(30 * 60)).state, .underSoft, "exactly 30 minutes is still fresh")
        XCTAssertEqual(evaluate(r, at: at.addingTimeInterval(30 * 60 + 1)).state, .unknown)
    }

    func testAReadingWithNoWindowsIsUnknown() {
        let r = UsageReading(account: UsageRefs.work, windows: [], readAt: Date(), source: "t", hardRejection: false)
        XCTAssertEqual(evaluate(r, at: r.readAt).state, .unknown, "off a subscription claude reports no windows")
    }

    func testThresholdsAreInclusive() {
        let at = Date()
        XCTAssertEqual(evaluate(UsageRefs.reading(UsageRefs.work, 0.80, at: at), at: at).state, .overSoft)
        XCTAssertEqual(evaluate(UsageRefs.reading(UsageRefs.work, 0.95, at: at), at: at).state, .overHard)
        XCTAssertEqual(evaluate(UsageRefs.reading(UsageRefs.work, 0.7999, at: at), at: at).state, .underSoft)
    }

    func testAnActiveRejectionOverridesALowMeter() {
        let at = usageISO("2026-10-04T18:00:00Z")
        let h = evaluate(UsageRefs.reading(UsageRefs.work, 0.10, at: at),
                         rejection: Rejection(at: at, until: at.addingTimeInterval(600), source: "429"),
                         at: at.addingTimeInterval(60))
        XCTAssertEqual(h.state, .overHard)
        XCTAssertEqual(h.resetsAt, at.addingTimeInterval(600))
    }

    func testARejectionWithoutAnEndLastsFifteenMinutes() {
        let at = usageISO("2026-10-04T18:00:00Z")
        let rej = Rejection(at: at, until: nil, source: "apiError")
        XCTAssertEqual(rej.expiry, at.addingTimeInterval(15 * 60))
        XCTAssertEqual(evaluate(nil, rejection: rej, at: at.addingTimeInterval(14 * 60)).state, .overHard)
        XCTAssertEqual(evaluate(nil, rejection: rej, at: at.addingTimeInterval(15 * 60)).state, .unknown)
    }

    /// Review focus: a tab that went idle at 97 % writes no new reading. Without this the
    /// account would stay over hard until the reading went stale — or forever, for a reading
    /// refreshed by an idle tab's turn-end measure.
    func testWindowPastItsResetCountsAsEmptyWithoutANewReading() {
        let readAt = usageISO("2026-10-04T22:50:00Z")
        let r = UsageReading(account: UsageRefs.work,
                             windows: [UsageWindow(name: "five_hour", utilization: 0.97, resetsAt: usageISO("2026-10-04T23:00:00Z")),
                                       UsageWindow(name: "seven_day", utilization: 0.40, resetsAt: usageISO("2026-10-09T00:00:00Z"))],
                             readAt: readAt, source: "t", hardRejection: false)
        XCTAssertEqual(evaluate(r, at: usageISO("2026-10-04T22:59:00Z")).state, .overHard)
        let after = evaluate(r, at: usageISO("2026-10-04T23:05:00Z"))
        XCTAssertEqual(after.state, .underSoft)
        XCTAssertEqual(after.worstUtilization ?? 0, 0.40, accuracy: 1e-9, "the seven-day window is now the worst")
    }

    /// Review focus: the vendor's clock and the Mac's disagree. A reset time that had already
    /// passed when the reading was taken says nothing about a reset since — keep the number.
    func testResetAtOrBeforeReadAtIsClockSkewNotAReset() {
        let readAt = usageISO("2026-10-04T23:00:30Z")
        let r = UsageRefs.reading(UsageRefs.work, 0.97, at: readAt, resetsAt: usageISO("2026-10-04T23:00:00Z"))
        XCTAssertEqual(evaluate(r, at: readAt.addingTimeInterval(60)).state, .overHard)
        XCTAssertEqual(HeadroomPolicy.effectiveUtilization(of: r.windows[0], readAt: readAt, now: readAt.addingTimeInterval(60)), 0.97)
    }

    /// Review focus: a reading stamped a little ahead of this Mac's clock is fresh, and is not
    /// treated as a reset either.
    func testReadingStampedInTheFutureIsFresh() {
        let now = usageISO("2026-10-04T18:00:00Z")
        let r = UsageRefs.reading(UsageRefs.work, 0.85, at: now.addingTimeInterval(90), resetsAt: now.addingTimeInterval(30))
        XCTAssertTrue(HeadroomPolicy.isFresh(r, now: now))
        XCTAssertEqual(evaluate(r, at: now).state, .overSoft)
    }

    func testPoolConstructorsAndDefaults() throws {
        let p = CapacityPool.hosted(id: CapacityPool.defaultID(for: .claude), label: "Claude default", agent: .claude, accounts: [UsageRefs.workID])
        XCTAssertEqual(p.id, "claude-default")
        XCTAssertTrue(p.isDefault)
        XCTAssertEqual(p.softThreshold, 0.80); XCTAssertEqual(p.hardThreshold, 0.95)
        let l = CapacityPool.local(id: "pool-local1", label: "Ollama", agent: .gemini, endpoint: "http://localhost:11434")
        XCTAssertEqual(l.concurrencyCap, 2); XCTAssertEqual(l.kind, .local); XCTAssertFalse(l.isDefault)
        XCTAssertNoThrow(try p.validate()); XCTAssertNoThrow(try l.validate())
        let data = try JSONEncoder().encode([p, l])
        XCTAssertEqual(try JSONDecoder().decode([CapacityPool].self, from: data), [p, l])
    }

    func testValidateNamesTheBadField() {
        var p = CapacityPool.hosted(id: "pool-a", label: "A", agent: .claude, accounts: [])
        p.softThreshold = 0.96
        XCTAssertThrowsError(try p.validate()) { XCTAssertEqual($0 as? PoolValidationError, .thresholdsOutOfOrder(soft: 0.96, hard: 0.95)) }
        p.softThreshold = 0.8; p.hardThreshold = 1.2
        XCTAssertThrowsError(try p.validate()) { XCTAssertEqual($0 as? PoolValidationError, .thresholdOutOfRange(1.2)) }
        var l = CapacityPool.local(id: "pool-b", label: "B", agent: .gemini, endpoint: "x")
        l.concurrencyCap = 0
        XCTAssertThrowsError(try l.validate()) { XCTAssertEqual($0 as? PoolValidationError, .capBelowOne(0)) }
        l.concurrencyCap = 1; l.label = " "
        XCTAssertThrowsError(try l.validate()) { XCTAssertEqual($0 as? PoolValidationError, .emptyLabel) }
    }
}
