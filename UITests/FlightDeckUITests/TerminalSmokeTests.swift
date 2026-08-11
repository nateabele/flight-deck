import XCTest

/// UI coverage, consolidated by app launch rather than by assertion.
///
/// Every XCUITest `launch()` spawns Flight Deck, seizes the foreground, and costs
/// seconds of wall clock; several of these tests also fire raw key events into
/// whatever holds focus. Eight one-assertion tests meant eight takeovers per run,
/// which made the machine unusable while the suite ran and made the suite too slow
/// to run often.
///
/// So the grouping rule is: **assertions that only READ the seeded state share a
/// launch; only state-mutating flows get their own.** Within a shared test, each
/// group is wrapped in `XCTContext.runActivity` so a failure still names the check
/// that failed. `XCTAssert` does not abort the enclosing test, so a failure in one
/// group does not hide the groups after it.
///
/// Three launches:
///  1. `testSeededStateThenCommandQQuits` — every read-only assertion, then ⌘Q last
///     (it terminates the app, so nothing can follow it).
///  2. `testCommandNInsertsBelowTheActiveSessionAndSelectsIt` — the ordering flow,
///     kept isolated because it is the subtlest and most regression-prone.
///  3. `testRenameThenCloseKeepsAppAlive` — the two remaining mutations, in order.
final class TerminalSmokeTests: XCTestCase {
    /// - `-ApplePersistenceIgnoreState`: XCUITest spawns the app via a raw exec, not
    ///   LaunchServices, so the macOS window-restoration handshake that normally creates
    ///   the initial window never completes and no window is made. Bypassing restoration
    ///   matches real-user launch semantics and changes no shipped behavior.
    /// - `-FlightDeckResetState`: the bundle launches the app once per test case, so a
    ///   session persisted by an earlier case would otherwise be restored into a later
    ///   one and make tests order-dependent.
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
        ]
        app.launch()
        return app
    }

    @discardableResult
    private func waitForWindow(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "no window appeared")
        return window
    }

    /// Settles the runloop briefly so a late-arriving duplicate event (e.g. a double-fired
    /// ⌘N) has a chance to show up before the surrounding assertion re-checks state.
    private func settle() {
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    // MARK: - Launch 1: every read-only assertion, then quit

    func testSeededStateThenCommandQQuits() {
        let app = launchApp()
        app.activate()
        let window = waitForWindow(app)

        XCTContext.runActivity(named: "window renders a terminal surface") { _ in
            XCTAssertGreaterThan(window.frame.height, 100)
        }

        // The other checks assert only that a window exists and is tall enough, which the
        // "No Session" ContentUnavailableView satisfies just as well — that is exactly how
        // a nil libghostty provider once shipped with a green smoke gate.
        XCTContext.runActivity(named: "selected session shows a terminal, not the empty state") { _ in
            let rows = app.staticTexts.matching(identifier: "session-row-title")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(
                app.staticTexts["No Session"].exists,
                "a session is selected but the detail pane shows the empty-state view"
            )
        }

        XCTContext.runActivity(named: "sidebar button offers New Session when a session exists") { _ in
            let button = app.buttons["new-session"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.label.contains("New Session"), "got: \(button.label)")
        }

        // New Window is the item `WindowGroup` used to contribute, and it is what was
        // claiming ⌘N. Asserting its absence is what proves the single-window scene swap
        // actually freed the shortcut, rather than us assuming it did.
        XCTContext.runActivity(named: "File menu offers both creation commands and no New Window") { _ in
            let file = app.menuBarItems["File"]
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.click()
            XCTAssertTrue(app.menuItems["New Session"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.menuItems["Add Project…"].exists)
            XCTAssertFalse(app.menuItems["New Window"].exists, "WindowGroup's New Window should be gone")
            app.typeKey(.escape, modifierFlags: [])
        }

        // Last, because it terminates the app.
        //
        // AppKit gives a view's `performKeyEquivalent` first refusal, ahead of the main
        // menu, and the Ghostty surface claims every shortcut libghostty treats as a
        // binding — so before `MenuKeyEquivalents` this keystroke was swallowed and the app
        // just sat there. The assertion is deliberately "the process exits", because that is
        // the only evidence the menu item fired rather than the key reaching the pty.
        XCTContext.runActivity(named: "⌘Q quits while the terminal has focus") { _ in
            XCTAssertEqual(app.state, .runningForeground)
            app.typeKey("q", modifierFlags: .command)
            let exited = NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue)
            expectation(for: exited, evaluatedWith: app)
            waitForExpectations(timeout: 10)
        }
    }

    // MARK: - Launch 2: ⌘N ordering

    /// ⌘N adds a session directly below the active one, and selects it. With row count alone
    /// (the old assertion), "insert below the active row" and "append to the end" are
    /// indistinguishable — the active row is always the most recently created one, so the two
    /// coincide until a *different* row is made active first. This test forces that: it
    /// re-selects the first row before the second ⌘N so the insert lands mid-list, then checks
    /// both the resulting row order and which row ends up selected.
    ///
    /// Kept in its own launch: it is the subtlest flow here, and cascading failures from an
    /// earlier group sharing its app instance would be hard to read.
    func testCommandNInsertsBelowTheActiveSessionAndSelectsIt() {
        let app = launchApp()
        app.activate()
        waitForWindow(app)

        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)

        // First ⌘N: "session 1" (seeded, active) -> "session 1", "session 2" (new, active).
        app.typeKey("n", modifierFlags: .command)
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 10)
        // The expectation resolves the instant the count reaches 2; a double-fire arriving on
        // a *later* runloop tick would slip past that instant undetected. Settle briefly and
        // re-assert so a late second creation still fails the test.
        settle()
        XCTAssertEqual(rows.count, 2)

        // Re-select the first row so the second ⌘N is a genuine mid-list insert — this is
        // what actually distinguishes "below the active row" from "append to the end". The
        // row's accessible `session-row-title` text carries its own (double-tap-only) gesture
        // recognizer, which swallows a plain click before it reaches the List's row-selection
        // handling; clicking the row's `Cell` (index 1 — index 0 is the section header)
        // lands on blank row space instead and reliably selects it.
        app.cells.element(boundBy: 1).click()

        app.typeKey("n", modifierFlags: .command)
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: rows)
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

    // MARK: - Launch 3: the remaining mutations

    func testRenameThenCloseKeepsAppAlive() {
        let app = launchApp()
        let window = waitForWindow(app)

        XCTContext.runActivity(named: "double-click renames a session") { _ in
            // Targeted by its own accessibility identifier rather than outline position:
            // a positional lookup would silently break the moment a second repo/session
            // exists or SwiftUI changes how it flattens sections into the outline.
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

        // Closing the session frees its surface while the app lives — the exact
        // use-after-free path the GhosttyApp singleton fix protects.
        XCTContext.runActivity(named: "closing the last session keeps the app alive") { _ in
            let close = app.buttons["close-session"].firstMatch
            if close.waitForExistence(timeout: 5) {
                close.click()
            }
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(window.exists)
        }
    }
}
