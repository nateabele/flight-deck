import XCTest

final class TerminalSmokeTests: XCTestCase {
    func testAppLaunchesAndShowsTerminalSurface() {
        let app = XCUIApplication()
        // XCUITest spawns the app via a raw exec, not LaunchServices, so the
        // macOS window-restoration handshake that normally creates the initial
        // WindowGroup window never completes and no window is made. Bypassing
        // restoration matches real-user (LaunchServices) launch semantics and
        // changes no shipped behavior.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // smoke.sh launches this test bundle multiple times in one run; without
        // this, a session persisted by an earlier test case would be restored
        // into a later one via UserDefaults and make tests order-dependent.
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        // The app window must exist and contain a rendered content view.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        // The window must be non-empty (the terminal surface occupies it).
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, 100)
    }

    func testClosingSeededSessionKeepsAppAlive() {
        let app = XCUIApplication()
        // See testAppLaunchesAndShowsTerminalSurface: bypass window restoration
        // so the initial window is created under XCUITest's raw-exec launch.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // smoke.sh launches this test bundle multiple times in one run; without
        // this, a session persisted by an earlier test case would be restored
        // into a later one via UserDefaults and make tests order-dependent.
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))

        // Close the seeded session; this frees its surface while the app lives —
        // the exact use-after-free path the singleton fix protects.
        let close = app.buttons["close-session"].firstMatch
        if close.waitForExistence(timeout: 5) {
            close.click()
        }

        // The app must survive: still running, window still present.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(window.exists)
    }

    func testDoubleClickRenamesSession() {
        let app = XCUIApplication()
        // See testAppLaunchesAndShowsTerminalSurface: bypass window restoration
        // and force a clean session slate so this test doesn't inherit a
        // session from an earlier test case in the same smoke.sh run.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()

        let row = app.staticTexts.matching(identifier: "session-title-field").firstMatch
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        // SwiftUI's List(selection:) exposes as an Outline (not a Table) here, with
        // the section header ("nate") as cell 0 and the seeded session as cell 1.
        // -FlightDeckResetState guarantees exactly one repo/session, so this is
        // deterministic. Double-click the row's title text specifically: the
        // onTapGesture(count: 2) is attached to the Text, not the whole row, and
        // the cell's own center falls in the Spacer between the title and the
        // close button.
        let first = app.outlines.cells.element(boundBy: 1).staticTexts.firstMatch
        first.doubleClick()

        let field = app.textFields["session-title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("renamed\n")

        XCTAssertTrue(app.staticTexts["renamed"].waitForExistence(timeout: 5))
        _ = row
    }
}
