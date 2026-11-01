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

    /// Scrolls the detail pane until all of `target` is inside the window, down or back up: the
    /// board sits above the plan, and a block's diagram is in the lower part of its frame.
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        let detail = app.scrollViews["intake-detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "no detail pane")
        let window = app.windows.firstMatch.frame
        for _ in 0..<20 {
            let frame = target.frame
            if frame.minY > window.minY + 100, frame.maxY < window.maxY - 40 { break }
            detail.scroll(byDeltaX: 0, deltaY: frame.midY > window.midY ? -200 : 200)
            pause(0.3)
        }
        pause(1)
    }

    private func eventually(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.5)
        }
        return condition()
    }

    /// The width in "live, drawn, <size>, <width> pt".
    private static func width(in value: String) -> Int? {
        value.split(separator: ",").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " pt", with: "")) }
    }

    private func isOn(_ button: XCUIElement) -> Bool { (button.value as? Int) == 1 || button.isSelected }

    func testOpenAPlanWithADiagramAndSwitchItsSize() {
        let app = launch()
        let block = element(app, "visual-block-\(Self.visualID)")
        XCTAssertTrue(block.waitForExistence(timeout: 20), "the plan's diagram block never appeared")
        // An NSSegmentedControl in select-one mode reads as a radio group.
        let sizes = app.radioGroups["visual-sizes"].firstMatch
        scrollTo(block, in: app)
        XCTAssertTrue(sizes.waitForExistence(timeout: 10), "the block has no size control")
        // Mermaid draws in a web view: the block says when it has drawn ("live, drawn").
        // "live, drawn, <size>, <width> pt": the page drew at that size, this wide.
        let drawn = eventually(20) { (block.value as? String)?.hasPrefix("live, drawn, wide,") == true }
        shot(app, "wide")
        let state = (block.value as? String) ?? "nil"
        let note = XCTAttachment(string: "block value: \(state)")
        note.name = "visual-size-draw-state"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertTrue(drawn, "the diagram was never drawn; the block says: \(state)")
        let wideWidth = Self.width(in: state)
        let wide = sizes.radioButtons["wide"], narrow = sizes.radioButtons["narrow"]
        XCTAssertTrue(wide.exists && narrow.exists, "the size control does not offer both sizes")
        XCTAssertTrue(isOn(wide), "the first size is not the one shown")

        narrow.click()
        XCTAssertTrue(eventually(20) { (block.value as? String)?.hasPrefix("live, drawn, narrow,") == true },
                      "the diagram was not drawn at the new size; the block says: \((block.value as? String) ?? "nil")")
        let narrowWidth = Self.width(in: (block.value as? String) ?? "")
        XCTAssertNotNil(wideWidth)
        XCTAssertLessThan(narrowWidth ?? .max, wideWidth ?? 0, "narrow drew narrower than wide")
        shot(app, "narrow")
        XCTAssertTrue(isOn(narrow), "choosing narrow did not switch the block's size")
        XCTAssertFalse(isOn(wide))
        XCTAssertFalse(element(app, "visual-placeholder").exists, "the block fell back to its missing placeholder")
    }
}
