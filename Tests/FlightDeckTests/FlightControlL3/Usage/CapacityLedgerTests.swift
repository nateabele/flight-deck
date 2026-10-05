import XCTest
import IntakeKit
@testable import FlightDeck

/// The ledger is the real `CapacityReader` and `PoolAllocator`: everything L3-S asks about
/// capacity, and everything the hand-off driver leases, goes through it. These pin lease order,
/// the unknown fallback, rejections winning over meters and clearing again, local caps, and the
/// two review-focus cases a single-pool fixture never shows.
final class CapacityLedgerTests: XCTestCase {
    private var clock: UsageTestClock!
    private var ledger: CapacityLedger!
    private let pool = CapacityPool.hosted(id: "claude-default", label: "Claude default", harness: "claude",
                                           accounts: [UsageRefs.workID, UsageRefs.spareID])

    override func setUp() {
        clock = UsageTestClock()
        let c = clock!
        ledger = CapacityLedger(now: { c.now })
        ledger.configure(pools: [pool], accounts: [UsageRefs.work, UsageRefs.spare])
    }

    func testPickPrefersUnderSoftInOrderThenUnknown() {
        let a = AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.9, state: .overSoft, resetsAt: nil)
        let b = AccountHeadroom(account: UsageRefs.spare, worstUtilization: nil, state: .unknown, resetsAt: nil)
        let c = AccountHeadroom(account: UsageRefs.codex, worstUtilization: 0.1, state: .underSoft, resetsAt: nil)
        XCTAssertEqual(LeasePolicy.pick([a, b, c]), UsageRefs.codex)
        XCTAssertEqual(LeasePolicy.pick([a, b]), UsageRefs.spare)
        XCTAssertNil(LeasePolicy.pick([a]))
    }

    func testUnknownAccountsLeaseInPoolOrder() {
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account, UsageRefs.work, "no readings yet: first unknown")
    }

    func testFirstUnderSoftAccountWinsOverAnEarlierUnknownOne() {
        ledger.ingest(UsageRefs.reading(UsageRefs.spare, 0.2, at: clock.now))
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account, UsageRefs.spare)
    }

    func testOverSoftTakesNoNewLease() {
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.85, at: clock.now))
        ledger.ingest(UsageRefs.reading(UsageRefs.spare, 0.90, at: clock.now))
        XCTAssertNil(ledger.lease(pool: "claude-default"))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").map(\.state), [.overSoft, .overSoft])
    }

    func testAHardRejectionBeatsAFreshLowMeterAndClearsWithALaterBelowHardReading() {
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: clock.now))
        clock.advance(60)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [], readAt: clock.now, source: "apiError", hardRejection: true))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .overHard)
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.10,
                       "a rejection does not overwrite the meter the popover draws")

        clock.advance(60)
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.99, at: clock.now))
        XCTAssertNotNil(ledger.rejection(account: UsageRefs.workID), "a reading at or over hard does not lift a refusal")
        clock.advance(60)
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.30, at: clock.now))
        XCTAssertNil(ledger.rejection(account: UsageRefs.workID))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .underSoft)
    }

    func testAReadingOlderThanTheRejectionDoesNotLiftIt() {
        let before = clock.now
        clock.advance(120)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [], readAt: clock.now, source: "429", hardRejection: true))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: before))
        XCTAssertNotNil(ledger.rejection(account: UsageRefs.workID))
    }

    func testARejectionCarryingAResetTimeEndsThen() {
        let until = clock.now.addingTimeInterval(300)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [UsageWindow(name: "retry-after", utilization: 1, resetsAt: until)],
                                   readAt: clock.now, source: "429", hardRejection: true))
        XCTAssertEqual(ledger.rejection(account: UsageRefs.workID)?.until, until)
        clock.advance(299)
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .overHard)
        clock.advance(2)
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .unknown)
    }

    func testAnOutOfOrderReadingIsIgnored() {
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.5, at: clock.now))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.99, at: clock.now.addingTimeInterval(-10)))
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.5)
    }

    func testTimelineFixtureDrivesLeasesThroughSoftHardAndReset() throws {
        let t = try L3Fixtures.usageTimeline()
        ledger.configure(pools: [CapacityPool.hosted(id: "solo", label: "Solo", harness: "claude", accounts: [UsageRefs.workID])],
                         accounts: [UsageRefs.work])
        var leased: [Bool] = []
        for r in t {
            clock.now = r.readAt.addingTimeInterval(30)
            ledger.ingest(r)
            if let l = ledger.lease(pool: "solo") { leased.append(true); ledger.release(l) } else { leased.append(false) }
        }
        XCTAssertEqual(leased, [true, false, false, false, true])
    }

    func testLocalPoolLeasesUpToItsCap() {
        let local = CapacityPool.local(id: "ollama", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        ledger.configure(pools: [local], accounts: [])
        let a = ledger.lease(pool: "ollama"), b = ledger.lease(pool: "ollama")
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNil(a?.account.id, "a local slot has no account")
        XCTAssertNil(ledger.lease(pool: "ollama"), "cap 2")
        XCTAssertEqual(ledger.headroom(pool: "ollama").first?.state, .overHard)
        ledger.release(a!)
        XCTAssertNotNil(ledger.lease(pool: "ollama"))
        XCTAssertEqual(ledger.activeLeases(pool: "ollama").count, 2)
    }

    func testUnknownPoolHasNoHeadroomAndNoLease() {
        XCTAssertEqual(ledger.headroom(pool: "nope"), [])
        XCTAssertNil(ledger.lease(pool: "nope"))
    }

    func testOpenCodeRateLimitBackoffEqualsHeadroomPolicyRejectionBackoff() {
        XCTAssertEqual(OpenCodeRateLimit.backoff, HeadroomPolicy.rejectionBackoff)
    }

    func testSourceErrorIsClearedByTheNextReading() {
        ledger.setSourceError("Codex app-server: transportClosed", account: UsageRefs.workID)
        XCTAssertEqual(ledger.sourceError(account: UsageRefs.workID), "Codex app-server: transportClosed")
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.2, at: clock.now))
        XCTAssertNil(ledger.sourceError(account: UsageRefs.workID))
    }

    func testAWindowedRejectionIsStoredAsTheMeterForThePopover() {
        let until = clock.now.addingTimeInterval(300)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [UsageWindow(name: "retry-after", utilization: 1, resetsAt: until)],
                                   readAt: clock.now, source: "429", hardRejection: true))
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 1,
                       "a windowed rejection is stored as the meter so the popover shows it")
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .overHard)
    }

    /// Review focus: the meter is per account, so two pools listing one account must agree on
    /// its reading; leases, though, are per pool, and releasing one must not free the other.
    func testTwoPoolsSharingAnAccountSeeOneReadingAndLeaseIndependently() {
        let strict = CapacityPool.hosted(id: "strict", label: "Strict", harness: "claude", accounts: [UsageRefs.workID], soft: 0.5, hard: 0.6)
        ledger.configure(pools: [pool, strict], accounts: [UsageRefs.work, UsageRefs.spare])
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.55, at: clock.now))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.worstUtilization, 0.55)
        XCTAssertEqual(ledger.headroom(pool: "strict").first?.worstUtilization, 0.55)
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .underSoft)
        XCTAssertEqual(ledger.headroom(pool: "strict").first?.state, .overSoft, "each pool applies its own thresholds")

        let a = ledger.lease(pool: "claude-default")
        XCTAssertEqual(a?.account, UsageRefs.work)
        XCTAssertNil(ledger.lease(pool: "strict"))
        ledger.release(a!)
        XCTAssertEqual(ledger.activeLeases(pool: "claude-default"), [])
        XCTAssertEqual(ledger.activeLeases(pool: "strict"), [])
    }
}
