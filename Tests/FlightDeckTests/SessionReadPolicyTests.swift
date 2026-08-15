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

    /// The whole sidebar must not light up blue on launch.
    ///
    /// `statuses` starts empty, so the first registry read is `nil -> idle` for every session
    /// at once. Treating that as an edge marked every unselected tab unread the moment the app
    /// opened, which is precisely the noise the dot exists to cut through: nothing *finished*
    /// while the user was away, the app simply started.
    func testAppearingIdleFromNothingDoesNotMark() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: nil, new: status(.idle), isViewed: false),
            .none
        )
    }

    /// Same rule covers a `claude` that restarts, or a brand-new session registering for the
    /// first time: the user created it, they did not miss it finishing.
    func testSessionAppearingIdleWhileViewedAlsoDoesNotMark() {
        XCTAssertEqual(
            SessionReadPolicy.change(old: nil, new: status(.idle), isViewed: true),
            .none
        )
    }

    /// The guard is "we saw it working", not merely "it is idle now" — so a real completion
    /// still marks even though the launch case above does not.
    func testRealCompletionStillMarksAfterTheLaunchFix() {
        for from in [SessionActivity.busy, .waiting, .shell] {
            XCTAssertEqual(
                SessionReadPolicy.change(old: status(from), new: status(.idle), isViewed: false),
                .mark,
                "\(from) -> idle while away should mark"
            )
        }
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
