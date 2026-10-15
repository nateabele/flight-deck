import AppKit
import XCTest

/// Typing in a plan's table, with the real keys in the running app: the caret goes into the table
/// by the arrow keys, a cell takes the typing, a pipe is escaped, Tab at the last cell adds a row,
/// and ⌘Z takes it back. The plan's stored text changes only where the keys were.
///
/// The fixture plan (`PlanningUIFixture`, `-FlightDeckPlanningFixture shaping`) carries a two
/// column table under its first paragraph. The editor's accessibility value is the plan's
/// Markdown, which is what is checked.
final class PlanTableUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckPlanningFixture", "shaping"]
        dismissFlightDeckCrashReports()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "plan-editor").firstMatch
    }

    private func markdown(_ app: XCUIApplication) -> String { (editor(app).value as? String) ?? "" }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "plan-table-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTypingInACellEditsItInPlaceAndTabAddsARow() throws {
        let app = launch()
        let plan = editor(app)
        XCTAssertTrue(plan.waitForExistence(timeout: 30), "the plan never opened")
        // In at the plan's first line, then down through the heading and the paragraph into the table.
        plan.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0)).withOffset(CGVector(dx: 0, dy: 20)).click()
        app.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<3 { app.typeKey(.downArrow, modifierFlags: []) }
        // Header row, then the body rows: the caret is in the table's cells.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(" now")
        let typed = markdown(app)
        XCTAssertTrue(typed.contains("| Data | Per tenant now |"), typed)
        XCTAssertEqual(typed.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count, 4, "no row added by typing")
        attach(app, "typed")

        // A pipe typed in a cell is escaped, never a new cell.
        app.typeText("|")
        XCTAssertTrue(markdown(app).contains("| Data | Per tenant now\\| |"), markdown(app))

        // Tab in the last cell adds a row.
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("New")
        let added = markdown(app)
        XCTAssertEqual(added.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count, 5, added)
        XCTAssertTrue(added.contains("| New |"), added)
        attach(app, "new-row")

        // Undo takes the typing back a step at a time.
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(markdown(app).contains("| New |"), markdown(app))
    }
}
