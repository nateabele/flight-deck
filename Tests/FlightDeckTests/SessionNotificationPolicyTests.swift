import XCTest
@testable import FlightDeck

final class SessionNotificationPolicyTests: XCTestCase {
    private typealias Policy = SessionNotificationPolicy

    private let busy = SessionStatus(activity: .busy)
    private let waiting = SessionStatus(activity: .waiting, waitingFor: "permission prompt")

    func testNotifiesOnEnteringWaitingWhileBackgrounded() {
        XCTAssertEqual(Policy.action(old: busy, new: waiting, appActive: false), .notify)
    }

    func testSuppressedWhileAppIsFrontmost() {
        XCTAssertEqual(Policy.action(old: busy, new: waiting, appActive: true), .none)
    }

    func testDoesNotRefireWhileStillWaiting() {
        XCTAssertEqual(Policy.action(old: waiting, new: waiting, appActive: false), .none)
    }

    func testWithdrawsWhenLeavingWaiting() {
        XCTAssertEqual(Policy.action(old: waiting, new: busy, appActive: false), .withdraw)
    }

    /// Withdrawal must not depend on focus — the prompt resolved either way.
    func testWithdrawsEvenWhileFrontmost() {
        XCTAssertEqual(Policy.action(old: waiting, new: busy, appActive: true), .withdraw)
    }

    func testWithdrawsWhenSessionDisappearsWhileWaiting() {
        XCTAssertEqual(Policy.action(old: waiting, new: nil, appActive: false), .withdraw)
    }

    func testNotifiesWhenSessionAppearsAlreadyWaiting() {
        XCTAssertEqual(Policy.action(old: nil, new: waiting, appActive: false), .notify)
    }

    func testNoActionForUnrelatedTransitions() {
        XCTAssertEqual(Policy.action(old: busy, new: busy, appActive: false), .none)
        XCTAssertEqual(
            Policy.action(old: SessionStatus(activity: .idle),
                          new: SessionStatus(activity: .busy), appActive: false),
            .none
        )
        XCTAssertEqual(Policy.action(old: nil, new: nil, appActive: false), .none)
    }
}
