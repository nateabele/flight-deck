import XCTest
@testable import FlightDeck

final class SessionStatusTests: XCTestCase {
    func testIdleTooltip() {
        XCTAssertEqual(SessionStatus(activity: .idle).tooltip, "Idle")
    }

    func testBusyTooltipWithoutSubagents() {
        XCTAssertEqual(SessionStatus(activity: .busy).tooltip, "Working")
    }

    func testBusyTooltipSingularSubagent() {
        XCTAssertEqual(
            SessionStatus(activity: .busy, subagentCount: 1).tooltip,
            "Working — 1 subagent"
        )
    }

    func testBusyTooltipPluralSubagents() {
        XCTAssertEqual(
            SessionStatus(activity: .busy, subagentCount: 3).tooltip,
            "Working — 3 subagents"
        )
    }

    func testWaitingTooltipIncludesReason() {
        XCTAssertEqual(
            SessionStatus(activity: .waiting, waitingFor: "permission prompt").tooltip,
            "Waiting for you — permission prompt"
        )
    }

    func testWaitingTooltipWithoutReason() {
        XCTAssertEqual(SessionStatus(activity: .waiting).tooltip, "Waiting for you")
    }

    /// The count is only meaningful while busy; other states render their own glyph.
    func testSubagentCountIgnoredWhenNotBusy() {
        XCTAssertEqual(SessionStatus(activity: .waiting, subagentCount: 5).tooltip,
                       "Waiting for you")
    }

    /// The two axes are independent, so one label has to carry both. The background clause is
    /// always last, which is what lets the iOS literals be a suffix of the macOS ones.
    func testTooltipComposesBackgroundWork() {
        XCTAssertEqual(
            SessionStatus(activity: .idle).tooltip(unread: false, backgroundWork: true),
            "Idle — background command running"
        )
        XCTAssertEqual(
            SessionStatus(activity: .idle).tooltip(unread: true, backgroundWork: true),
            "Finished — not yet viewed — background command running"
        )
        XCTAssertEqual(
            SessionStatus(activity: .busy, subagentCount: 2)
                .tooltip(unread: false, backgroundWork: true),
            "Working — 2 subagents — background command running"
        )
        XCTAssertEqual(
            SessionStatus(activity: .waiting, waitingFor: "permission prompt")
                .tooltip(unread: false, backgroundWork: true),
            "Waiting for you — permission prompt — background command running"
        )
    }

    /// Without the flag nothing changes — every pre-existing string is byte-identical.
    func testTooltipUnchangedWithoutBackgroundWork() {
        XCTAssertEqual(SessionStatus(activity: .idle).tooltip(unread: false), "Idle")
        XCTAssertEqual(SessionStatus(activity: .busy).tooltip(unread: false), "Working")
    }
}
