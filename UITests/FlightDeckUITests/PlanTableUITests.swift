import AppKit
import XCTest

/// Typing in a plan's table: the table stays a grid (its cells are exposed as table cells, never
/// as raw pipes) while a cell takes the keys, and the plan's stored text changes only in that cell.
///
/// The fixture plan (`PlanningUIFixture`, `-FlightDeckPlanningFixture shaping`) carries a two
/// column table. The editor's accessibility value is the plan's Markdown, which is what is checked.
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

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func markdown(_ app: XCUIApplication) -> String {
        (element(app, "plan-editor").value as? String) ?? ""
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "plan-table-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTypingInACellEditsItInPlaceAndTabAddsARow() throws {
        let app = launch()
        let cell = element(app, "plan-table-cell-2-1")
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the plan's table never appeared as cells")
        XCTAssertEqual(cell.label, "Per tenant")
        cell.click()
        app.typeText(" now")
        XCTAssertTrue(markdown(app).contains("| Data | Per tenant now |"), markdown(app))
        attach(app, "typed")

        // A pipe typed in a cell is escaped, never a new cell.
        app.typeText("|")
        XCTAssertTrue(markdown(app).contains("| Data | Per tenant now\\| |"), markdown(app))

        // Tab in the last cell adds a row; the table is still the cells of a table.
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(element(app, "plan-table-cell-3-0").waitForExistence(timeout: 5), "Tab in the last cell added no row")
        app.typeText("New")
        XCTAssertTrue(markdown(app).contains("| New |"), markdown(app))
        attach(app, "new-row")

        // Undo takes the typing back a step at a time, never leaving a broken table.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(markdown(app).contains("| New |"), markdown(app))
    }
}
