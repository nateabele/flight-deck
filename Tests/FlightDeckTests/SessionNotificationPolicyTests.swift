import XCTest
@testable import FlightDeck

final class SessionNotificationPolicyTests: XCTestCase {
    private typealias Policy = SessionNotificationPolicy

    private let busy = SessionStatus(activity: .busy)
    private let waiting = SessionStatus(activity: .waiting, waitingFor: "permission prompt")

    /// Every existing case here is about status alone — `planGate` is nil on both sides
    /// throughout this file. `PlanGateNotificationTests` covers the gate half.
    private func input(_ status: SessionStatus?) -> Policy.Input {
        Policy.Input(status: status, planGate: nil)
    }

    func testNotifiesOnEnteringWaitingWhileBackgrounded() {
        XCTAssertEqual(
            Policy.action(old: input(busy), new: input(waiting), appActive: false), .notify
        )
    }

    func testSuppressedWhileAppIsFrontmost() {
        XCTAssertEqual(
            Policy.action(old: input(busy), new: input(waiting), appActive: true), .none
        )
    }

    func testDoesNotRefireWhileStillWaiting() {
        XCTAssertEqual(
            Policy.action(old: input(waiting), new: input(waiting), appActive: false), .none
        )
    }

    func testWithdrawsWhenLeavingWaiting() {
        XCTAssertEqual(
            Policy.action(old: input(waiting), new: input(busy), appActive: false), .withdraw
        )
    }

    /// Withdrawal must not depend on focus — the prompt resolved either way.
    func testWithdrawsEvenWhileFrontmost() {
        XCTAssertEqual(
            Policy.action(old: input(waiting), new: input(busy), appActive: true), .withdraw
        )
    }

    func testWithdrawsWhenSessionDisappearsWhileWaiting() {
        XCTAssertEqual(
            Policy.action(old: input(waiting), new: input(nil), appActive: false), .withdraw
        )
    }

    func testNotifiesWhenSessionAppearsAlreadyWaiting() {
        XCTAssertEqual(
            Policy.action(old: input(nil), new: input(waiting), appActive: false), .notify
        )
    }

    func testNoActionForUnrelatedTransitions() {
        XCTAssertEqual(Policy.action(old: input(busy), new: input(busy), appActive: false), .none)
        XCTAssertEqual(
            Policy.action(
                old: input(SessionStatus(activity: .idle)),
                new: input(SessionStatus(activity: .busy)), appActive: false
            ),
            .none
        )
        XCTAssertEqual(Policy.action(old: input(nil), new: input(nil), appActive: false), .none)
    }
}
