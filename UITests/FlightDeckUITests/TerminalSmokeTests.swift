import XCTest

final class TerminalSmokeTests: XCTestCase {
    func testAppLaunchesAndShowsTerminalSurface() {
        let app = XCUIApplication()
        app.launch()
        app.activate()
        // The app window must exist and contain a rendered content view.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        // The window must be non-empty (the terminal surface occupies it).
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, 100)
    }

    func testClosingSeededSessionKeepsAppAlive() {
        let app = XCUIApplication()
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
}
