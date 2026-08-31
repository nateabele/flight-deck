import XCTest
@testable import FlightDeck
@testable import FleetKit

/// A plan gate is a call for a human, and must reach one.
///
/// **This is the defect the whole feature exists for.** While a gate is open, claude's
/// registry reports `status: "busy"` — measured over 33 minutes against pid 66955 on
/// 2026-08-29 — so every existing "you are needed" path is silent. `SessionNotificationPolicy`
/// keys off a `waiting` transition that never comes.
final class PlanGateNotificationTests: XCTestCase {

    func testAGateOpeningNotifiesEvenThoughTheStatusSaysBusy() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let before = SessionNotificationPolicy.Input(status: busy, planGate: nil)
        let after = SessionNotificationPolicy.Input(status: busy, planGate: .stub())
        XCTAssertTrue(SessionNotificationPolicy.shouldNotify(from: before, to: after))
    }

    /// A poll that re-reports the same gate is not a new event. A four-day gate polled every
    /// two seconds would otherwise be 170,000 notifications.
    func testTheSameGateNotifiesOnlyOnce() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let open = SessionNotificationPolicy.Input(status: busy, planGate: .stub())
        XCTAssertFalse(SessionNotificationPolicy.shouldNotify(from: open, to: open))
    }

    /// A revised plan is a new call id and a genuinely new thing to read.
    func testANewCallIDNotifiesAgain() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let first = SessionNotificationPolicy.Input(status: busy, planGate: .stub(call: "c1"))
        let second = SessionNotificationPolicy.Input(status: busy, planGate: .stub(call: "c2"))
        XCTAssertTrue(SessionNotificationPolicy.shouldNotify(from: first, to: second))
    }

    func testAGateClosingDoesNotNotify() {
        let busy = SessionStatus(activity: .busy, waitingFor: nil)
        let open = SessionNotificationPolicy.Input(status: busy, planGate: .stub())
        let closed = SessionNotificationPolicy.Input(status: busy, planGate: nil)
        XCTAssertFalse(SessionNotificationPolicy.shouldNotify(from: open, to: closed))
    }
}

private extension WirePlanGate {
    static func stub(call: String = "toolu_01ABC") -> WirePlanGate {
        WirePlanGate(callID: call, tier: "annotate", plan: "# Plan",
                     startedAt: "2026-08-29T17:40:36.186Z", annotationCount: 0)
    }
}
