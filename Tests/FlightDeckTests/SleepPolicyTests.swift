import XCTest
@testable import FlightDeck

final class SleepPolicyTests: XCTestCase {
    let policy = SleepPolicy(idleThreshold: 600)
    let now = Date()
    func base(_ f: (inout SleepCandidate) -> Void) -> SleepCandidate {
        var c = SleepCandidate(id: UUID(), activity: .idle, isSelected: false,
                               reportsBackgroundWork: false, hasLiveDescendants: false,
                               idleSince: now.addingTimeInterval(-3600),
                               isDaemonized: true, isAsleep: false)
        f(&c); return c
    }
    func testEligibleWhenIdleLongEnoughUnfocusedNoBgWork() {
        XCTAssertEqual(policy.evaluate(base { _ in }, now: now), .sleep)
    }
    func testBusyNeverSleeps() {
        XCTAssertEqual(policy.evaluate(base { $0.activity = .busy }, now: now), .ineligible("busy"))
    }
    func testWaitingIsEligible() {
        XCTAssertEqual(policy.evaluate(base { $0.activity = .waiting }, now: now), .sleep)
    }
    func testSelectedNeverSleeps() {
        XCTAssertEqual(policy.evaluate(base { $0.isSelected = true }, now: now), .ineligible("selected"))
    }
    func testReportedBackgroundWorkBlocks() {
        XCTAssertEqual(policy.evaluate(base { $0.reportsBackgroundWork = true }, now: now), .ineligible("background-work"))
    }
    func testLiveDescendantsBlock() {
        XCTAssertEqual(policy.evaluate(base { $0.hasLiveDescendants = true }, now: now), .ineligible("background-work"))
    }
    func testBelowThresholdWaits() {
        let c = base { $0.idleSince = now.addingTimeInterval(-60) }
        XCTAssertEqual(policy.evaluate(c, now: now), .ineligible("not-idle-long-enough"))
    }
    func testNilIdleSinceIneligible() {
        XCTAssertEqual(policy.evaluate(base { $0.idleSince = nil }, now: now), .ineligible("not-idle-long-enough"))
    }
    func testNonDaemonizedIneligible() {
        XCTAssertEqual(policy.evaluate(base { $0.isDaemonized = false }, now: now), .ineligible("no-daemon"))
    }
    func testAlreadyAsleepIsNoOp() {
        XCTAssertEqual(policy.evaluate(base { $0.isAsleep = true }, now: now), .ineligible("already-asleep"))
    }
}
