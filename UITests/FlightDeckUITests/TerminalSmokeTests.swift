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
        let row = app.staticTexts.matching(identifier: "session-row-title").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let close = app.buttons["close-session"].firstMatch
        // The close button is hover-gated (see SessionRow), so the row must be hovered
        // before it exists. Without this the guarded click below silently never fires
        // and the test degrades to a launch smoke check.
        row.hover()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

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

    /// The File menu carries both creation commands and no longer offers New Window.
    ///
    /// New Window is the item `WindowGroup` used to contribute, and it is what was claiming
    /// ⌘N. Asserting its absence here is what proves the single-window scene swap actually
    /// freed the shortcut, rather than us assuming it did.
    func testFileMenuOffersBothCreationCommandsAndNoNewWindow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let file = app.menuBarItems["File"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.click()

        XCTAssertTrue(app.menuItems["New Session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Add Project…"].exists)
        XCTAssertFalse(app.menuItems["New Window"].exists, "WindowGroup's New Window should be gone")

        app.typeKey(.escape, modifierFlags: [])   // close the menu
    }

    /// ⌘N adds a session directly below the active one, and selects it. With row count alone
    /// (the old assertion), "insert below the active row" and "append to the end" are
    /// indistinguishable — the active row is always the most recently created one, so the two
    /// coincide until a *different* row is made active first. This test forces that: it
    /// re-selects the first row before the second ⌘N so the insert lands mid-list, then checks
    /// both the resulting row order and which row ends up selected.
    func testCommandNAddsASessionBelowTheActiveOne() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)

        // First ⌘N: "session 1" (seeded, active) -> "session 1", "session 2" (new, active).
        app.typeKey("n", modifierFlags: .command)
        let two = NSPredicate(format: "count == 2")
        expectation(for: two, evaluatedWith: rows)
        waitForExpectations(timeout: 10)
        // The expectation resolves the instant the count reaches 2; a double-fire arriving on
        // a *later* runloop tick would slip past that instant undetected. Settle briefly and
        // re-assert so a late second creation still fails the test.
        settle()
        XCTAssertEqual(rows.count, 2)

        // Re-select the first row so the second ⌘N is a genuine mid-list insert — this is
        // what actually distinguishes "below the active row" from "append to the end".
        //
        // Deliberately clicks the row's TITLE TEXT, not blank row space. The title carries
        // the rename recognizer, and while that was an exclusive `onTapGesture(count: 2)` it
        // swallowed single clicks so the row never selected — the one part of the row users
        // aim at was the one part that did not work. `SessionRow.handleTitleTap()` now
        // detects the double click itself, and this click is the regression guard for it.
        rows.element(boundBy: 0).click()
        XCTAssertTrue(
            app.cells.element(boundBy: 1).isSelected,
            "clicking a row's title text must select that row"
        )

        // Second ⌘N: insert below the now-active first row.
        app.typeKey("n", modifierFlags: .command)
        let three = NSPredicate(format: "count == 3")
        expectation(for: three, evaluatedWith: rows)
        waitForExpectations(timeout: 10)
        settle()
        XCTAssertEqual(rows.count, 3)

        let labels = (0..<3).map { rows.element(boundBy: $0).value as? String }
        XCTAssertEqual(
            labels, ["session 1", "session 3", "session 2"],
            "expected the new session inserted directly below the re-selected first row, got \(labels)"
        )

        // The newly created session ("session 3", the middle row) must end up selected, not
        // "session 2" left over from a stale/nil selection binding after the mid-list insert.
        // `isSelected` is exposed reliably on the row's `Cell` (unlike the nested
        // `session-row-title` text, which never reports selected) — cell index 2 here, since
        // the header still occupies index 0.
        XCTAssertTrue(
            app.cells.element(boundBy: 2).isSelected,
            "expected the new \"session 3\" row (not the stale \"session 2\" selection) to be selected"
        )
    }

    /// Settles the runloop briefly so a late-arriving duplicate event (e.g. a double-fired
    /// ⌘N) has a chance to show up before the surrounding assertion re-checks state.
    private func settle() {
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// The button's label follows state: with a seeded session it offers New Session.
    func testSidebarButtonOffersNewSessionWhenASessionExists() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let button = app.buttons["new-session"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.label.contains("New Session"), "got: \(button.label)")
    }

    /// The close button is hover-gated now, so it must be absent at rest and present
    /// once the pointer is over the row.
    ///
    /// This does not also assert the status icon (`SessionStatusIcon`) despite the icon
    /// sitting right beside the close button: the smoke environment has no live `claude`,
    /// so `store.status(for:)` is nil and the icon renders nothing. Asserting it would
    /// require a live session, which is out of scope for this test.
    func testHoverRevealsCloseButton() {
        let app = XCUIApplication()
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()

        let row = app.staticTexts.matching(
            identifier: "session-row-title"
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))

        // Park the pointer on a neutral, non-row element before the negative assertion.
        // testClosingSeededSessionKeepsAppAlive leaves the physical pointer parked over a
        // sidebar row when it ends, and every test relaunches the app at that same
        // on-screen position. The negative assertion below only passes today because
        // SwiftUI's `.onHover` is edge-triggered on cursor movement and does not fire for
        // a pointer that is already stationary when a new window appears under it — so
        // the row never reports itself hovered even though the pointer sits on top of it.
        // That is an accident of window-creation timing, not a real assertion that hover
        // starts false; moving the pointer here first makes the "hidden at rest" claim
        // actually true regardless of where a previous test case left the cursor.
        app.buttons["new-session"].hover()

        XCTAssertFalse(app.buttons["close-session"].exists,
                       "close button should be hidden until hover")

        row.hover()

        XCTAssertTrue(app.buttons["close-session"].waitForExistence(timeout: 5))
    }
}
