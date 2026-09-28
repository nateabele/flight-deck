import XCTest
@testable import FlightDeck

/// Where the split-flap card goes, in AppKit screen coordinates (y up). The card lives in its
/// own child panel so the tape's ScrollView can't clip it; that makes placement our job, and
/// this is all of it.
final class CardPlacementTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 500)
    private let card = CGSize(width: 180, height: 70)

    /// Room below: the card hangs under the label, leading edges aligned.
    func testOpensBelowTheLabel() {
        let label = CGRect(x: 300, y: 450, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: label, within: window, gap: 9)
        XCTAssertEqual(frame, CGRect(x: 300, y: 450 - 9 - 70, width: 180, height: 70))
    }

    /// Near the window's bottom edge there's no room below, so it flips up over the label.
    func testFlipsUpNearTheBottomEdge() {
        let label = CGRect(x: 300, y: 140, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: label, within: window, gap: 9)
        XCTAssertEqual(frame.minY, 140 + 18 + 9, "flipped: starts a gap above the label")
        XCTAssertGreaterThan(frame.minY, label.maxY)
    }

    /// Neither side fits (a squat window): below wins, the reading direction, rather than
    /// covering the label's own row.
    func testStaysBelowWhenNeitherSideFits() {
        let squat = CGRect(x: 100, y: 100, width: 800, height: 100)
        let label = CGRect(x: 300, y: 140, width: 40, height: 18)
        let frame = CardPlacement.frame(for: card, anchor: label, within: squat, gap: 9)
        XCTAssertEqual(frame.maxY, 140 - 9)
    }

    /// A label at the trailing edge slides its card back inside the window rather than
    /// hanging it off the side; one at the leading edge stays put.
    func testClampsHorizontallyInsideTheWindow() {
        let trailing = CGRect(x: 870, y: 450, width: 28, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: trailing, within: window, gap: 9).maxX, window.maxX)
        let leading = CGRect(x: 90, y: 450, width: 28, height: 18)
        XCTAssertEqual(CardPlacement.frame(for: card, anchor: leading, within: window, gap: 9).minX, window.minX)
    }
}
