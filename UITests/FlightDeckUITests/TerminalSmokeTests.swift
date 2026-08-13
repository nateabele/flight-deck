import AppKit
import XCTest

/// The whole UI gate, in **one** app launch.
///
/// Every XCUITest `launch()` spawns Flight Deck, seizes the foreground, and fires key
/// events into whatever holds focus. One assertion per test meant one takeover per
/// assertion, which made the machine unusable while the suite ran.
///
/// So this deliberately ignores the usual one-behaviour-per-test convention: it is a
/// single session that walks the app through every checked behaviour in dependency
/// order, accumulating assertions as it goes. That is a real trade — a failure early on
/// leaves later groups asserting against unexpected state — and it is taken knowingly,
/// because the cost of the alternative is measured in machine takeovers.
///
/// Two things keep it debuggable:
///  - Each behaviour is wrapped in `XCTContext.runActivity`, so a failure names the group
///    it happened in rather than just a line number.
///  - `XCTAssert` does not abort the enclosing test, so one failing group does not hide
///    the groups after it.
///
/// Order is load-bearing: read-only checks first, then the mutations that build on each
/// other (⌘N → rename → close), and ⌘Q strictly last because it terminates the app.
final class TerminalSmokeTests: XCTestCase {
    /// Settles the runloop briefly so a late-arriving duplicate event (e.g. a double-fired
    /// ⌘N) has a chance to show up before the surrounding assertion re-checks state.
    private func settle() {
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// macOS names the Settings window inconsistently across releases ("Preferences" on
    /// some, SwiftUI's generated "FlightDeck Settings" on others), so it is located
    /// defensively by content — the window whose descendants include the Claude tab
    /// button — rather than by a hard-coded title.
    private func preferencesWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.button, identifier: "Claude").firstMatch
    }

    func testTheWholeShellInOneSession() {
        let app = XCUIApplication()
        // - `-ApplePersistenceIgnoreState`: XCUITest spawns the app via a raw exec, not
        //   LaunchServices, so the macOS window-restoration handshake that normally creates
        //   the initial window never completes and no window is made. Bypassing restoration
        //   matches real-user launch semantics and changes no shipped behavior.
        // - `-FlightDeckResetState`: start from a known seeded slate rather than whatever a
        //   previous run persisted. This is now the *only* thing isolating the test from real
        //   session state — `smoke.sh` no longer deletes it, because doing so destroyed the
        //   developer's own sessions on every run.
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
        ]
        app.launch()
        app.activate()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "no window appeared")

        let rows = app.staticTexts.matching(identifier: "session-row-title")

        XCTContext.runActivity(named: "window renders a terminal surface") { _ in
            XCTAssertGreaterThan(window.frame.height, 100)
        }

        // A window that is merely tall enough is also satisfied by the "No Session"
        // ContentUnavailableView — which is exactly how a nil libghostty provider once
        // shipped with a green smoke gate. This is the check that distinguishes them.
        XCTContext.runActivity(named: "selected session shows a terminal, not the empty state") { _ in
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

        // ⌘N adds a session directly below the active one, and selects it. With row count
        // alone, "insert below the active row" and "append to the end" are indistinguishable
        // — the active row is always the most recently created one, so the two coincide until
        // a *different* row is made active first. This forces that case.
        XCTContext.runActivity(named: "⌘N inserts below the active session and selects it") { _ in
            XCTAssertEqual(rows.count, 1)

            // First ⌘N: "session 1" (seeded, active) -> "session 1", "session 2" (new, active).
            app.typeKey("n", modifierFlags: .command)
            expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
            waitForExpectations(timeout: 10)
            // The expectation resolves the instant the count reaches 2; a double-fire arriving
            // on a *later* runloop tick would slip past that instant undetected. Settle and
            // re-assert so a late second creation still fails.
            settle()
            XCTAssertEqual(rows.count, 2)

            // Re-select the first row so the second ⌘N is a genuine mid-list insert — this is
            // what actually distinguishes "below the active row" from "append to the end".
            //
            // Deliberately clicks the row's TITLE TEXT, not blank row space. The title carries
            // the rename recognizer, and while that was an exclusive `onTapGesture(count: 2)`
            // it swallowed single clicks so the row never selected — the one part of the row
            // users aim at was the one part that did not work. `SessionRow.handleTitleTap()`
            // now detects the double click itself, and this click is the regression guard.
            rows.element(boundBy: 0).click()
            XCTAssertTrue(
                app.cells.element(boundBy: 1).isSelected,
                "clicking a row's title text must select that row"
            )

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

            // The newly created "session 3" (middle row) must end up selected, not "session 2"
            // left over from a stale selection binding after the mid-list insert. `isSelected`
            // is reliable on the row's `Cell` (unlike the nested text, which never reports
            // selected) — cell index 2, since the header still occupies index 0.
            XCTAssertTrue(
                app.cells.element(boundBy: 2).isSelected,
                "expected the new \"session 3\" row (not the stale \"session 2\" selection) to be selected"
            )
        }

        // The keystroke, not the menu item, is what this proves. libghostty binds ⌘⇧[ / ⌘⇧]
        // to previous_tab/next_tab, and the Ghostty surface claims every binding ahead of the
        // main menu — so with focus in the terminal these keys reach `TabNavigationCommands`
        // only because `MenuKeyEquivalents` hands consumed-only bindings over first. Clicking
        // the menu items would exercise none of that, which is why this types instead.
        //
        // Inherited state: rows are ["session 1", "session 3", "session 2"] with "session 3"
        // (row 1) selected. Only the selection moves here.
        XCTContext.runActivity(named: "⌘⇧] and ⌘⇧[ cycle sessions and wrap around") { _ in
            XCTAssertEqual(rows.count, 3, "precondition: three sessions from the ⌘N group")
            XCTAssertTrue(app.cells.element(boundBy: 2).isSelected, "precondition: row 1 selected")

            // Forward one: row 1 -> row 2.
            app.typeKey("]", modifierFlags: [.command, .shift])
            settle()
            XCTAssertTrue(
                app.cells.element(boundBy: 3).isSelected,
                "⌘⇧] did not advance the selection — the terminal probably swallowed the key"
            )

            // Forward again from the last row: wraps to row 0.
            app.typeKey("]", modifierFlags: [.command, .shift])
            settle()
            XCTAssertTrue(
                app.cells.element(boundBy: 1).isSelected,
                "⌘⇧] did not wrap from the last session to the first"
            )

            // Backward from the first row: wraps to the last, row 2.
            app.typeKey("[", modifierFlags: [.command, .shift])
            settle()
            XCTAssertTrue(
                app.cells.element(boundBy: 3).isSelected,
                "⌘⇧[ did not wrap from the first session to the last"
            )

            // The rows themselves must be untouched — a stray "[" or "]" reaching the pty
            // would not change these, but a misrouted key that hit rename or create would.
            let labels = (0..<3).map { rows.element(boundBy: $0).value as? String }
            XCTAssertEqual(labels, ["session 1", "session 3", "session 2"])
        }

        XCTContext.runActivity(named: "double-click renames a session") { _ in
            // Targeted by accessibility identifier rather than outline position: a positional
            // lookup would silently break the moment SwiftUI changes how it flattens sections.
            let title = rows.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.doubleClick()

            let field = app.textFields["session-title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeKey("a", modifierFlags: .command)
            // "renamed" was never on screen before this point, so the assertion below cannot
            // pass vacuously.
            field.typeText("renamed\n")

            XCTAssertTrue(app.staticTexts["renamed"].waitForExistence(timeout: 5))
        }

        // Closing a session frees its surface while the app lives — the exact use-after-free
        // path the process-wide GhosttyApp singleton protects against.
        // The close button is hover-gated in `SessionRow`, so it does not exist until the
        // pointer is over the row. Asserting that directly, and immediately before the
        // close group, is what stops that group from silently degrading: a guarded
        // `if close.exists { close.click() }` against a hover-gated button skips without
        // failing, and the close assertion below would then prove nothing.
        //
        // A single session makes the negative assertion honest, which it is not across
        // separate launches: with one launch per test, every relaunch puts a new window
        // under a pointer left parked on a row by the previous test, and `.onHover` is
        // edge-triggered so it never fires for an already-stationary pointer. That made
        // "hidden at rest" pass by accident of window-creation timing. Here the pointer's
        // position is deterministic, because we put it somewhere neutral ourselves.
        XCTContext.runActivity(named: "the close button is revealed by hover, not shown at rest") { _ in
            app.buttons["new-session"].hover()
            XCTAssertFalse(
                app.buttons["close-session"].exists,
                "close button should be hidden until the row is hovered"
            )

            rows.firstMatch.hover()
            XCTAssertTrue(app.buttons["close-session"].waitForExistence(timeout: 5))
        }

        XCTContext.runActivity(named: "closing a session keeps the app alive") { _ in
            // Unguarded: the group above has already established the button exists under
            // hover, so a missing button here is a real failure rather than a skip.
            let close = app.buttons["close-session"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.click()

            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(window.exists)
        }

        // Preferences (⌘,) opens a separate window whose three tabs are wired to the flag
        // catalog. The window is located by `preferencesWindow(_:)` rather than by title —
        // see that helper's doc comment for why.
        XCTContext.runActivity(named: "⌘, opens Preferences with three tabs") { _ in
            app.typeKey(",", modifierFlags: .command)
            let prefs = preferencesWindow(app)
            XCTAssertTrue(prefs.waitForExistence(timeout: 5), "Preferences window did not open")
            XCTAssertTrue(prefs.buttons["Claude"].exists)
            XCTAssertTrue(prefs.buttons["Projects"].exists)
            XCTAssertTrue(prefs.buttons["Shell & Environment"].exists)
        }

        XCTContext.runActivity(named: "toggling a control updates the command field") { _ in
            let prefs = preferencesWindow(app)
            prefs.buttons["Claude"].click()
            let field = prefs.textViews["command-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertFalse((field.value as? String ?? "").contains("--verbose"))

            prefs.checkBoxes.matching(identifier: "Verbose").firstMatch.click()
            expectation(
                for: NSPredicate(format: "value CONTAINS %@", "--verbose"), evaluatedWith: field
            )
            waitForExpectations(timeout: 5)
        }

        // The other direction of the sync, and the reason ⌘↩ exists: commit without blurring.
        // Asserts on `--brief` (catalog label "Agent-to-user messages", not "Brief" — the
        // control's accessibility identifier is `spec.label` verbatim) rather than `--verbose`:
        // the previous group already turned `--verbose` on and, in this single shared session,
        // that mutation persists — reusing it here would not distinguish "the sync ran" from
        // "it was already on".
        XCTContext.runActivity(named: "typing in the command field updates the controls") { _ in
            let prefs = preferencesWindow(app)
            let field = prefs.textViews["command-field"]
            let checkbox = prefs.checkBoxes.matching(identifier: "Agent-to-user messages").firstMatch
            XCTAssertEqual(checkbox.value as? Int, 0)

            field.click()
            field.typeText(" --brief")
            field.typeKey(.return, modifierFlags: .command)

            expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: checkbox)
            waitForExpectations(timeout: 5)
        }

        // The whole point of the locked prefix: select-all + delete must not destroy it.
        XCTContext.runActivity(named: "the locked prefix survives select-all and delete") { _ in
            let prefs = preferencesWindow(app)
            let field = prefs.textViews["command-field"]
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])

            let value = field.value as? String ?? ""
            XCTAssertTrue(value.hasPrefix("claude --session-id"), "locked prefix was destroyed: \(value)")
        }

        // The permission-bypass toggle is gated by a confirmation. Cancel must leave it off —
        // the gate returns before mutating the model, so the checkbox must not stick on.
        XCTContext.runActivity(named: "enabling permission bypass asks first, and Cancel leaves it off") { _ in
            let prefs = preferencesWindow(app)
            let checkbox = prefs.checkBoxes.matching(identifier: "Skip all permission checks").firstMatch
            XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
            XCTAssertEqual(checkbox.value as? Int, 0)

            checkbox.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "no confirmation appeared")
            sheet.buttons["Cancel"].click()

            XCTAssertEqual(checkbox.value as? Int, 0, "Cancel left the bypass enabled")
            let field = prefs.textViews["command-field"]
            XCTAssertFalse((field.value as? String ?? "").contains("--dangerously-skip-permissions"))
        }

        // Close Preferences so the groups below act on the main window.
        app.typeKey("w", modifierFlags: .command)

        // libghostty delegates every clipboard operation to the host runtime; those callbacks
        // used to be empty stubs, so ⌘C looked wired (the menu item existed, the responder
        // method ran) and still copied nothing. Asserting on the *pasteboard* is what makes
        // this a real check rather than a test of menu plumbing.
        XCTContext.runActivity(named: "Copy puts the terminal's selection on the pasteboard") { _ in
            let sentinel = "flight-deck-clipboard-sentinel-\(UUID().uuidString)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sentinel, forType: .string)

            let edit = app.menuBars.menuBarItems["Edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))

            edit.click()
            app.menuItems["Select All"].click()
            edit.click()
            app.menuItems["Copy"].click()

            // The shell has drawn at least a prompt by now, so a select-all is non-empty.
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            XCTAssertNotEqual(copied, sentinel, "Copy left the pasteboard untouched")
            XCTAssertFalse(copied.isEmpty, "Copy wrote an empty string")
        }

        // These have no SwiftUI defaults — `EditCommands` adds them. A missing item here means
        // the shortcut is gone too, since the key equivalent lives on the menu item.
        XCTContext.runActivity(named: "Edit menu exposes the find and paste items") { _ in
            let edit = app.menuBars.menuBarItems["Edit"]
            edit.click()
            for title in ["Paste as Plain Text", "Paste Selection", "Find…", "Find Next",
                          "Find Previous", "Use Selection for Find"] {
                XCTAssertTrue(app.menuItems[title].exists, "Edit menu is missing \(title)")
            }
            app.typeKey(.escape, modifierFlags: [])
        }

        // ⌘F is the whole find feature end to end: the key reaches libghostty, which emits
        // START_SEARCH, which `GhosttyApp` routes to the surface's `searchState`, which is
        // what makes `TerminalSearchBar` appear. Before this work the action was dropped and
        // there was no bar to show.
        XCTContext.runActivity(named: "⌘F opens the find bar and Escape dismisses it") { _ in
            app.typeKey("f", modifierFlags: .command)
            let field = app.windows.firstMatch.textFields["Find"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "find bar never appeared")

            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(
                field.waitForNonExistence(timeout: 5),
                "find bar stayed up after Escape"
            )
        }

        // Strictly last: it terminates the app.
        //
        // AppKit gives a view's `performKeyEquivalent` first refusal, ahead of the main menu,
        // and the Ghostty surface claims every shortcut libghostty treats as a binding — so
        // before `MenuKeyEquivalents` this keystroke was swallowed and the app just sat there.
        // The assertion is deliberately "the process exits", because that is the only evidence
        // the menu item fired rather than the key reaching the pty.
        XCTContext.runActivity(named: "⌘Q quits while the terminal has focus") { _ in
            XCTAssertEqual(app.state, .runningForeground)
            app.typeKey("q", modifierFlags: .command)
            let exited = NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue)
            expectation(for: exited, evaluatedWith: app)
            waitForExpectations(timeout: 10)
        }
    }
}
