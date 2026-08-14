import XCTest
@testable import FlightDeck

final class SessionReadPolicyTests: XCTestCase {
    private func status(_ activity: SessionActivity) -> SessionStatus {
        SessionStatus(activity: activity)
    }

    // MARK: The marking edge

    func testFinishingWhileNotViewedMarksUnread() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: status(.busy), new: status(.idle), isViewed: false),
            .mark
        )
    }

    func testFinishingWhileViewedClearsInstead() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: status(.busy), new: status(.idle), isViewed: true),
            .clear
        )
    }

    /// The edge is what keeps a long-idle session from re-marking on every registry poll —
    /// the same reason `SessionNotificationPolicy` is edge-triggered.
    func testStayingIdleDoesNotReMark() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: status(.idle), new: status(.idle), isViewed: false),
            .none
        )
    }

    /// A busy session renders a spinner, so its mark is invisible until it lands on idle
    /// again — at which point the edge runs and decides afresh.
    func testLeavingIdleIsLeftAlone() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: status(.idle), new: status(.busy), isViewed: false),
            .none
        )
    }

    func testWaitingDoesNotMark() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: status(.busy), new: status(.waiting), isViewed: false),
            .none
        )
    }

    /// A session appearing already-idle (first registry read after launch) still counts as
    /// an edge into idle: there was no previous idle to have seen.
    func testAppearingIdleFromNothingMarks() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: nil, new: status(.idle), isViewed: false),
            .mark
        )
    }

    func testDisappearingIsLeftAlone() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: status(.idle), new: nil, isViewed: false),
            .none
        )
    }

    // MARK: Tooltip channel

    /// The unread state is drawn in colour alone, so the text channel has to carry it too.
    func testUnreadIdleGetsItsOwnTooltip() {
        XCTAssertEqual(status(.idle).tooltip(unread: true), "Finished — not yet viewed")
        XCTAssertEqual(status(.idle).tooltip(unread: false), "Idle")
    }

    func testUnreadDoesNotLeakIntoNonIdleTooltips() {
        XCTAssertEqual(status(.busy).tooltip(unread: true), status(.busy).tooltip)
        XCTAssertEqual(status(.waiting).tooltip(unread: true), status(.waiting).tooltip)
    }
}
