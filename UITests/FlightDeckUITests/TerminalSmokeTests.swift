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

    /// ⌘Q must quit while the terminal has focus.
    ///
    /// AppKit gives a view's `performKeyEquivalent` first refusal, ahead of the main menu,
    /// and the Ghostty surface claims every shortcut libghostty treats as a binding — so
    /// before `MenuKeyEquivalents` this keystroke was swallowed and the app just sat there.
    /// The assertion is deliberately "the process exits", because that is the only evidence
    /// that the menu item actually fired rather than the key reaching the pty.
    func testCommandQQuitsWhileTerminalHasFocus() {
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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)

        app.typeKey("q", modifierFlags: .command)

        let exited = NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue)
        expectation(for: exited, evaluatedWith: app)
        waitForExpectations(timeout: 10)
    }

    func testDoubleClickRenamesSession() {
        let app = XCUIApplication()
        // See testAppLaunchesAndShowsTerminalSurface: bypass window restoration
        // and force a clean session slate so this test doesn't inherit a
        // session from an earlier test case in the same smoke.sh run.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()

        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        // Targeted by its own accessibility identifier rather than outline position:
        // a positional lookup (e.g. "cell at index 1") would silently break the
        // moment a second repo/session exists or SwiftUI changes how it flattens
        // sections into the outline.
        let title = app.staticTexts["session-row-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.doubleClick()

        let field = app.textFields["session-title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        // "renamed" was never on screen before this point (the seeded title is
        // "session 1"), so the assertion below cannot pass vacuously.
        field.typeText("renamed\n")

        XCTAssertTrue(app.staticTexts["renamed"].waitForExistence(timeout: 5))
    }

    /// The seeded session must render an actual terminal, not the empty-state view.
    ///
    /// The other tests assert only that a window exists and is tall enough, which the
    /// "No Session" ContentUnavailableView satisfies just as well — that is exactly how a
    /// nil libghostty provider once shipped with a green smoke gate.
    func testSelectedSessionShowsATerminalNotTheEmptyState() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // A session row exists...
        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        // ...so the detail pane must NOT be showing the empty state.
        XCTAssertFalse(
            app.staticTexts["No Session"].exists,
            "a session is selected but the detail pane shows the empty-state view"
        )
    }
}
