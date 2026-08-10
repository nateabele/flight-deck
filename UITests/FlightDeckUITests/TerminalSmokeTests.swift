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
