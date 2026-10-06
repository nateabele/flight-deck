import XCTest
import IntakeKit
@testable import FlightDeck

/// The header row is one combined accessibility element (`ProjectHeaderRow`), so the swarm's
/// summary and banner reach VoiceOver only through its label. (XCUITest reads that label as ""
/// — `TerminalSmokeTests` notes it — so the UI test reads the popover instead.)
@MainActor
final class SwarmHeaderTests: XCTestCase {
    func testTheSummaryAndBannerJoinTheHeaderLabel() {
        let summary = SwarmHeaderSummary(text: "swarm paused · 1/3", banner: SwarmStore.restartBanner, state: .paused)
        XCTAssertEqual(ProjectHeaderRow.swarmAccessibilityParts(summary),
                       ["swarm paused · 1/3", "Swarm paused after restart · Resume"])
        XCTAssertEqual(ProjectHeaderRow.swarmAccessibilityParts(nil), [])
    }

    func testThePopoverListsWaitingTasksWithReasons() {
        var record = SwarmRecord(id: UUID(), project: "/p", cap: 2, poolCaps: [:], filter: .allReady, state: .running,
                                 agents: [], createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        record.waiting = [WaitingTask(task: "fx-2", reason: "codex-subs is full and nothing else fits")]
        record.unroutable = [WaitingTask(task: "fx-9", reason: "no execution block")]
        XCTAssertEqual(SwarmPopover.lines(for: record),
                       ["fx-2 — codex-subs is full and nothing else fits", "fx-9 — unroutable: no execution block"])
    }
}
