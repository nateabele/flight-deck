import AppKit
import XCTest

/// A plan's visual block through the real app (planning v2 P2a, spec §8, §14): the plan opens with
/// a Mermaid diagram drawn inline, and switching the block's size redraws it at the other size.
///
/// The fixture is the app's own (`PlanningUIFixture`, `-FlightDeckPlanningFixture visuals`): the
/// shaping plan with one `fd-visual` block near its top, stored in two sizes, `wide` and `narrow`.
final class VisualSizeUITests: XCTestCase {
    /// `PlanningUIFixture.visualID`, repeated here: the UI-test bundle can't import the app.
    private static let visualID = "fixture-flow"

    override func setUp() { continueAfterFailure = false }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "visual-size-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckPlanningFixture", "visuals"]
        dismissFlightDeckCrashReports()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        XCTAssertTrue(element(app, "plan-editor").waitForExistence(timeout: 20), "the plan editor never appeared")
        XCUIElement.perform(withKeyModifiers: .option) { app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click() }
        pause(3)
        return app
    }

    /// Scrolls the detail pane until the block is in the window: the board sits above the plan.
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        let detail = app.scrollViews["intake-detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "no detail pane")
        for _ in 0..<12 where !(target.exists && target.isHittable) {
            detail.scroll(byDeltaX: 0, deltaY: -300)
            pause(0.3)
        }
        pause(1)
    }

    func testOpenAPlanWithADiagramAndSwitchItsSize() {
        let app = launch()
        let block = element(app, "visual-block-\(Self.visualID)")
        XCTAssertTrue(block.waitForExistence(timeout: 20), "the plan's diagram block never appeared")
        let sizes = app.segmentedControls["visual-sizes"].firstMatch
        scrollTo(sizes, in: app)
        XCTAssertTrue(sizes.waitForExistence(timeout: 10), "the block has no size control")
        // Mermaid draws in a web view: give it its first draw before looking.
        pause(3)
        shot(app, "wide")
        let wide = sizes.buttons["wide"], narrow = sizes.buttons["narrow"]
        XCTAssertTrue(wide.exists && narrow.exists, "the size control does not offer both sizes")
        XCTAssertTrue(wide.isSelected, "the first size is not the one shown")

        narrow.click()
        pause(3)
        shot(app, "narrow")
        XCTAssertTrue(narrow.isSelected, "choosing narrow did not switch the block's size")
        XCTAssertFalse(wide.isSelected)
        XCTAssertFalse(element(app, "visual-placeholder").exists, "the block fell back to its missing placeholder")
    }
}
