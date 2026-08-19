import XCTest
@testable import FlightDeck

/// No clock inside the type, so every transition is assertable without waiting five seconds
/// or standing up a window.
@MainActor
final class ToolOverlayVisibilityTests: XCTestCase {
    private let t0 = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        t0.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    func testHiddenBeforeAnythingHappens() {
        XCTAssertFalse(ToolOverlayVisibility().isVisible(at: t0))
    }

    func testMouseMovementShowsIt() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertTrue(v.isVisible(at: t0))
    }

    func testItStaysVisibleJustInsideTheIdleTimeout() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertTrue(v.isVisible(at: at(4.9)))
    }

    func testItFadesAfterFiveIdleSeconds() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertFalse(v.isVisible(at: at(5.1)))
    }

    func testTypingHidesItImmediately() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.keyPressed()
        XCTAssertFalse(v.isVisible(at: at(0.1)))
    }

    func testTypingKeepsItHiddenUntilTheMouseMovesAgain() {
        // Not merely "hidden now": without the suppression flag, the stamp from the earlier
        // move would bring the buttons back on the next redraw while the user is still typing.
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.keyPressed()
        XCTAssertFalse(v.isVisible(at: at(1.0)))
        v.mouseMoved(at: at(2.0))
        XCTAssertTrue(v.isVisible(at: at(2.0)))
    }

    func testHoveringPinsItPastTheIdleTimeout() {
        // Without this you cannot aim at a button: the cluster would fade while the pointer
        // travelled to it.
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.hoverChanged(true)
        XCTAssertTrue(v.isVisible(at: at(60)))
    }

    func testLeavingTheClusterUnpinsIt() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.hoverChanged(true)
        v.hoverChanged(false)
        XCTAssertFalse(v.isVisible(at: at(60)))
    }

    func testTheDeadlineIsFiveSecondsAfterTheLastMove() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertEqual(v.idleDeadline(), t0.advanced(by: .seconds(5)))
    }

    func testThereIsNoDeadlineWhenNothingIsPending() {
        XCTAssertNil(ToolOverlayVisibility().idleDeadline())
        var typed = ToolOverlayVisibility()
        typed.mouseMoved(at: t0)
        typed.keyPressed()
        XCTAssertNil(typed.idleDeadline(), "a suppressed overlay has nothing left to time out")
    }
}
