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
}
