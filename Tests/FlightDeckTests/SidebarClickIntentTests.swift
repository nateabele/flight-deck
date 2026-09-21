import XCTest
@testable import FlightDeck

/// The click-vs-drag rule behind the sidebar's row-wide collapse toggle. Pure by design — see
/// `SidebarInputMonitor`'s doc comment — so none of this needs a window or an `NSEvent`.
@MainActor
final class SidebarClickIntentTests: XCTestCase {
    /// Far enough from the trailing edge to clear the close-button strip, which is where every
    /// case below wants to be unless it says otherwise.
    private let overTheTitle = SidebarClickIntent.closeButtonExclusion + 100

    private func toggles(
        from down: CGPoint,
        to up: CGPoint,
        downRow: Int = 3,
        upRow: Int = 3,
        clickCount: Int = 1,
        distanceFromTrailingEdge: CGFloat? = nil
    ) -> Bool {
        SidebarClickIntent.togglesCollapse(
            downPoint: down,
            upPoint: up,
            downRow: downRow,
            upRow: upRow,
            clickCount: clickCount,
            downDistanceFromTrailingEdge: distanceFromTrailingEdge ?? overTheTitle
        )
    }

    func testAPressThatBarelyMovesIsAClick() {
        // 3pt of travel: a hand resting on the mouse, not a drag.
        XCTAssertTrue(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 42, y: 198)))
    }

    func testAPressThatDoesNotMoveAtAllIsAClick() {
        XCTAssertTrue(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 200)))
    }

    func testTravelBeyondTheThresholdIsADragNotAClick() {
        // Straight down the sidebar, which is the direction a reorder drag moves. Most real
        // drags never deliver their mouse-up here at all — see the doc comment — so this is
        // the belt-and-braces half of the rule.
        XCTAssertFalse(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 190)))
    }

    func testTravelIsMeasuredAsDistanceNotPerAxis() {
        // 3pt on each axis is under the threshold on either alone, and 4.24pt together.
        XCTAssertFalse(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 43, y: 203)))
    }

    func testReleasingOverADifferentRowDoesNotToggle() {
        XCTAssertFalse(
            toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 199), downRow: 3, upRow: 4)
        )
    }

    func testADoubleClickDoesNotToggle() {
        // Without this the two clicks would toggle twice and the project would appear not to
        // have moved.
        XCTAssertFalse(toggles(from: CGPoint(x: 40, y: 200), to: CGPoint(x: 40, y: 200), clickCount: 2))
    }

    func testAClickOnTheCloseButtonStripDoesNotToggle() {
        // The hover-revealed X. Excluded by geometry because the probe ruled out telling it
        // apart by hit-test view — SwiftUI answers with the row's one hosting view either way.
        XCTAssertFalse(
            toggles(
                from: CGPoint(x: 230, y: 200),
                to: CGPoint(x: 230, y: 200),
                distanceFromTrailingEdge: 8
            )
        )
    }

    func testTheExclusionEndsAtItsConstant() {
        let boundary = CGPoint(x: 40, y: 200)
        XCTAssertFalse(
            toggles(from: boundary, to: boundary,
                    distanceFromTrailingEdge: SidebarClickIntent.closeButtonExclusion)
        )
        XCTAssertTrue(
            toggles(from: boundary, to: boundary,
                    distanceFromTrailingEdge: SidebarClickIntent.closeButtonExclusion + 0.5)
        )
    }
}
