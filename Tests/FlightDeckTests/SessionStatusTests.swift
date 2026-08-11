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

    func testShellTooltip() {
        XCTAssertEqual(
            SessionStatus(activity: .shell).tooltip,
            "Background command running"
        )
    }

    /// The count is only meaningful while busy; other states render their own glyph.
    func testSubagentCountIgnoredWhenNotBusy() {
        XCTAssertEqual(SessionStatus(activity: .waiting, subagentCount: 5).tooltip,
                       "Waiting for you")
    }
}
