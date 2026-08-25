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

    /// Polls `condition` until it holds or the deadline passes.
    ///
    /// `waitForExistence` only answers "did this element appear", which is the wrong question
    /// for state that changes an element's LABEL while it stays on screen the whole time — the
    /// unread mark being the case in point.
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// macOS names the Settings window inconsistently across releases ("Preferences" on
    /// some, SwiftUI's generated "FlightDeck Settings" on others), so it is located
    /// defensively by content — the window whose descendants include the Agents tab
    /// button — rather than by a hard-coded title.
    ///
    /// Locating by content buys release-independence at the cost of a coupling that is easy to
    /// miss: this anchor is a *tab title*, so renaming a tab silently turns every Preferences
    /// assertion in this file into "the Preferences window did not open". That is exactly what
    /// the "Claude" -> "Agents" rename did (the single Claude tab became the reorderable agent
    /// registry), and the misleading message is why it read as a window bug rather than a
    /// locator bug. If a tab is renamed again, this line is the first thing to change.
    private func preferencesWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.button, identifier: "Agents").firstMatch
    }

    /// The one behaviour that earns its own launch.
    ///
    /// Reordering projects needs TWO projects, and the big test's seeded slate has one. The
    /// only production route to a second project is an `NSOpenPanel`, which a UI test cannot
    /// drive reliably — hence `-FlightDeckSeedSecondProject`, a flag `FlightDeckApp` honours
    /// only under `-FlightDeckResetState`. Adding a second project to the shared slate instead
    /// would have shifted every row index the big test asserts on, so this pays one extra
    /// launch to keep that test's arithmetic intact.
    ///
    /// This covers a bug that shipped: project headings could not be dragged AT ALL, because a
    /// row-wide `.onTapGesture` (collapse-on-click) consumed the mouse-down `List`'s `.onMove`
    /// needs. The toggle moved onto the chevron button, leaving the rest of the header
    /// grabbable.
    func testProjectHeadingsReorderByDragging() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
            "-FlightDeckSeedSecondProject", "YES",
        ]
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")

        // `.accessibilityElement(children: .combine)` on the header means it is not a
        // StaticText, so match on identifier across any element type rather than guessing.
        let headers = app.descendants(matching: .any).matching(identifier: "project-header")
        XCTAssertTrue(
            headers.element(boundBy: 1).waitForExistence(timeout: 10),
            "expected two project headings; the seed flag may not have taken effect"
        )
        XCTAssertEqual(headers.count, 2, "precondition: exactly two projects")

        // Order is read from the SESSION rows, not the headings. The heading is an
        // `.accessibilityElement(children: .combine)`, and XCUITest reports its label as ""
        // (see the FOLLOWUPS note on project-header accessibility), so asserting on heading
        // labels would compare "" to "" and pass no matter what happened. Each seeded project
        // owns exactly one session, so the session order IS the project order.
        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertEqual(rows.count, 2, "precondition: one session per seeded project")
        let before = (0..<2).map { rows.element(boundBy: $0).value as? String }

        // Drag the first heading past the second. The drop lands below the second project's
        // own rows, so aim well beneath it rather than exactly on it.
        // Both ends are coordinates: the press/drag pair is typed, and mixing an element
        // source with a coordinate destination does not compile. Pressing mid-header also
        // keeps the press off the chevron button at the leading edge.
        headers.element(boundBy: 0)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.6,
                thenDragTo: headers.element(boundBy: 1)
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
                    .withOffset(CGVector(dx: 0, dy: 60))
            )
        settle()

        let after = (0..<2).map { rows.element(boundBy: $0).value as? String }
        XCTAssertNotEqual(
            after, before,
            "dragging a project heading did not reorder anything — a gesture on the header is "
            + "probably swallowing the mouse-down again (got \(after))"
        )
        XCTAssertEqual(
            after.compactMap { $0 }.sorted(), before.compactMap { $0 }.sorted(),
            "the reorder lost or duplicated a project"
        )

        app.terminate()
    }

    /// Flake hunt for the permission-bypass confirmation. **Skipped unless
    /// `FLIGHTDECK_FLAKE_HUNT` is set**, so it costs normal runs nothing:
    ///
    ///     TEST_RUNNER_FLIGHTDECK_FLAKE_HUNT=1 FLIGHTDECK_TEST_THROTTLE=0 ./scripts/smoke.sh
    ///
    /// The `TEST_RUNNER_` prefix is required and is not decoration: `xcodebuild` does not pass
    /// arbitrary shell variables into the UI-test runner process, and only forwards ones with
    /// that prefix, stripping it on the way in. Setting a bare `FLIGHTDECK_FLAKE_HUNT` silently
    /// skips this test — measured, having done exactly that first.
    ///
    /// Exists because the suite is deliberately ONE test function of `runActivity` groups, so
    /// `-only-testing:` cannot target a single behaviour — and chasing a ~20%-rate flake by
    /// re-running the whole 70-second suite is the wrong tool by two orders of magnitude. This
    /// reproduces the suspect sequence — the command field's ⌘A+delete churn, then the checkbox
    /// click — `iterations` times inside ONE launch, so 20 samples cost ~40s instead of ~23min.
    ///
    /// Statistics worth stating: at a 20% failure rate, 5 clean samples still pass by luck 33%
    /// of the time, so a 5-run batch was never evidence of a fix. 20 samples drops that to 1.2%.
    ///
    /// The same pattern is the right answer for any future flake here: add a hunt case, loop the
    /// suspect sequence in one launch, and delete it or leave it skipped once the cause is known.
    func testPermissionBypassConfirmationUnderChurn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FLIGHTDECK_FLAKE_HUNT"] != nil,
            "flake hunt — set FLIGHTDECK_FLAKE_HUNT=1 to run"
        )

        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")

        app.typeKey(",", modifierFlags: .command)
        let prefs = preferencesWindow(app)
        XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Preferences never opened")

        let iterations = 20
        var failures: [String] = []

        for i in 1...iterations {
            // Reproduce the churn the real suite's preceding activity causes: ⌘A + delete in the
            // command field mutates `flags`, which trips `.onChange(of: flags)` -> re-render.
            let field = prefs.textViews["command-field"]
            guard field.waitForExistence(timeout: 5) else {
                failures.append("iteration \(i): command field missing")
                continue
            }
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])

            let checkbox = prefs.checkBoxes.matching(identifier: "Skip all permission checks").firstMatch
            guard checkbox.waitForExistence(timeout: 5) else {
                failures.append("iteration \(i): checkbox missing")
                continue
            }
            guard checkbox.value as? Int == 0 else {
                failures.append("iteration \(i): checkbox was already ON before the click")
                continue
            }

            checkbox.click()
            let sheet = prefs.sheets.firstMatch
            if sheet.waitForExistence(timeout: 5) {
                sheet.buttons["Cancel"].click()
                if checkbox.value as? Int != 0 {
                    failures.append("iteration \(i): Cancel left the bypass ENABLED")
                }
            } else if checkbox.value as? Int != 0 {
                // The outcome that would matter: the gate did not fire and the flag went on.
                failures.append("iteration \(i): SECURITY — no confirmation AND bypass toggled on")
            } else {
                failures.append("iteration \(i): no confirmation appeared (checkbox stayed off)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count)/\(iterations) iterations failed:\n" + failures.joined(separator: "\n")
        )
        app.terminate()
    }

    /// ⌘W must close a session even when the sidebar — not the terminal — holds focus.
    ///
    /// Earns its own launch for the same reason the drag test does: it needs a slate the big
    /// test's arithmetic does not have (two sessions, focus parked in the sidebar), and its
    /// failure mode is the app *quitting*, which would take every group after it with it.
    ///
    /// **The hazard.** ⌘W is answered by `TerminalHostView.performClose(_:)`, reached through
    /// the key window's responder chain. That chain runs first responder → superviews → window.
    /// `TerminalHostView` is an ancestor of the Ghostty surface but NOT of the sidebar, which
    /// is a sibling branch of the split view. So with focus in the sidebar the action walks
    /// straight past the handler to the window — and because
    /// `applicationShouldTerminateAfterLastWindowClosed` returns true and there is one window,
    /// closing it quits the app and reaps every session. A user who has learned "⌘W closes the
    /// tab" would eventually lose all of them from the one place in the UI where clicking a
    /// session is the natural gesture.
    ///
    /// **Why the click is on the already-selected row.** Clicking a *different* row re-parents
    /// its surface, and `TerminalPane.updateNSView` calls `Ghostty.moveFocus(to:)` on a
    /// re-parent — handing focus straight back to the terminal and hiding the very hazard under
    /// test. Clicking the row that is already selected re-parents nothing, so focus stays where
    /// the click put it. One click, not two: `SidebarInputMonitor` maps a double click to
    /// inline rename.
    ///
    /// **The precondition assertion is load-bearing.** If focus is not actually in the sidebar
    /// when ⌘W is sent, this test passes while observing nothing — the vacuous-pass shape. It
    /// fails loudly on that instead, naming what held focus.
    func testCommandWWithSidebarFocusClosesASessionRatherThanQuitting() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")

        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(waitFor(timeout: 10) { rows.count == 1 }, "seeded slate should hold one session")

        // Two sessions, so closing one cannot empty the app — otherwise "closed the last tab
        // and quit" and "quit instead of closing a tab" produce the same observable end state.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitFor(timeout: 10) { rows.count == 2 }, "⌘N did not add a second session")
        settle()

        // ⌘N leaves the new session selected, so this clicks the already-selected row.
        rows.element(boundBy: 1).click()
        settle()

        XCTAssertFalse(
            app.textFields["session-title-field"].exists,
            "the click started an inline rename; ⌘W would not reach the row handler"
        )

        // Focus is established BEHAVIOURALLY rather than by reading an attribute: neither
        // `hasFocus` nor `hasKeyboardFocus` exists on `XCUIElement` in this XCTest, and
        // guessing at a third spelling is how a precondition ends up silently absent. Up-arrow
        // moves the selection only when the list holds focus — if the terminal had it instead,
        // the key goes to the shell as a history recall and the selection does not move.
        //
        // Cell indices: 0 is the project header, 1 and 2 the two sessions.
        XCTAssertTrue(app.cells.element(boundBy: 2).isSelected, "precondition: ⌘N should leave the new session selected")
        app.typeKey(.upArrow, modifierFlags: [])
        settle()
        XCTAssertTrue(
            app.cells.element(boundBy: 1).isSelected,
            """
            precondition failed: Up did not move the sidebar selection, so focus is not in the \
            sidebar and this test cannot observe the hazard — a pass would mean nothing. Find \
            another way to park focus in the list rather than deleting this check.
            """
        )

        let before = rows.count
        app.typeKey("w", modifierFlags: .command)
        settle()

        // Checked before the row count: if the app quit, the count is 0 for a reason that has
        // nothing to do with closing a tab, and this message is the one worth reading.
        XCTAssertNotEqual(
            app.state, .notRunning,
            "⌘W with the sidebar focused QUIT THE APP instead of closing a session"
        )
        XCTAssertTrue(
            app.windows.firstMatch.exists,
            "⌘W with the sidebar focused closed the window instead of a session"
        )
        XCTAssertEqual(rows.count, before - 1, "⌘W with the sidebar focused closed no session")

        app.terminate()
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

        XCTContext.runActivity(named: "sidebar button offers a New Session for the default agent") { _ in
            let button = app.buttons["new-session"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            // The label is agent-specific and live: `NewSessionAffordance.resolve` renders
            // "New <Agent> Session" for the slot the held modifiers select, re-labelling to the
            // next agent the instant ⇧ goes down on the way to ⌘⇧N. Unmodified, it names the
            // first agent in this project's order, and with `-FlightDeckResetState` there are no
            // stored preferences — so the order is `Preferences.defaultAgents`, whose first
            // entry is `.claude` (`displayName` "Claude").
            //
            // Asserted whole rather than as a `contains("New Session")` substring, which is what
            // this used to do: that spelling passes for "New Session" and fails for every
            // agent-labelled variant, so it broke the moment the label went live and told us
            // only that *something* differed.
            XCTAssertEqual(button.label, "New Claude Session", "got: \(button.label)")
        }

        // New Window is the item `WindowGroup` used to contribute, and it is what was
        // claiming ⌘N. Asserting its absence is what proves the single-window scene swap
        // actually freed the shortcut, rather than us assuming it did.
        XCTContext.runActivity(named: "File menu offers both creation commands and no New Window") { _ in
            let file = app.menuBarItems["File"]
            XCTAssertTrue(file.waitForExistence(timeout: 5))
            file.click()
            // One entry per agent in agent order, not a single "New Session" — `SessionCommands`
            // splits them so two agents can never contribute two items with the same title.
            // An agent with 2+ accounts renders as a submenu instead of a flat row, but the
            // parent item carries the same title either way, so this holds for both shapes.
            XCTAssertTrue(app.menuItems["New Claude Session"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.menuItems["New Codex Session"].exists)
            XCTAssertFalse(
                app.menuItems["New Session"].exists,
                "the agent-less item is what the per-agent split replaced; two agents must not "
                + "both answer to one title"
            )
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
            // Deliberately clicks the row's TITLE TEXT, not blank row space. The title used to
            // carry a hand-rolled double-click detector as an exclusive `onTapGesture(count: 2)`
            // that swallowed single clicks, so the row never selected — the one part of the row
            // users aim at was the one part that did not work. The title carries no SwiftUI tap
            // recognizer at all today (see `SessionRow`'s doc comment on the title `Text`), so a
            // single click on it reaches `List`'s ordinary selection handling like any other
            // part of the row, and this click is the regression guard.
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

        // The regression guard for a bug that shipped: pressing on a row's TITLE TEXT could not
        // start a drag, so reordering silently did nothing for anyone who grabbed a row where
        // it reads. The cause was the title's own tap recognizer (the hand-rolled double-click
        // rename) consuming the mouse-down that `List`'s `.onMove` needs.
        //
        // Deliberately presses the title rather than blank row space — blank space always
        // worked, so a test that grabbed there would have passed against the broken build.
        //
        // The assertion is "the order changed", not a specific final order: where a drop lands
        // depends on drop-target geometry that varies with row height and list insets, and
        // pinning it would buy flakiness rather than coverage. The bug was that *nothing*
        // happened, and that is exactly what this distinguishes.
        // Blank row space to the right of a title: the region that always worked by hand.
        // Used as the CONTROL below — if a drag from here does not reorder either, the
        // failure is XCUITest's inability to drive a SwiftUI list reorder, not the app.
        func blankSpace(inRow index: Int, dy: CGFloat = 0) -> XCUICoordinate {
            rows.element(boundBy: index)
                .coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
                .withOffset(CGVector(dx: 40, dy: dy))
        }

        XCTContext.runActivity(named: "control: a session reorders by dragging blank row space") { _ in
            XCTAssertEqual(rows.count, 3, "precondition: three sessions")
            let before = (0..<3).map { rows.element(boundBy: $0).value as? String }

            blankSpace(inRow: 0).press(forDuration: 0.6, thenDragTo: blankSpace(inRow: 2, dy: 8))
            settle()

            let after = (0..<3).map { rows.element(boundBy: $0).value as? String }
            XCTAssertNotEqual(
                after, before,
                "CONTROL FAILED: dragging blank row space did not reorder either, so this test "
                + "cannot drive a list reorder at all and says nothing about the title-drag bug "
                + "(got \(after))"
            )
        }

        // The regression guard for a bug that shipped: pressing on a row's TITLE TEXT could not
        // start a drag, so reordering silently did nothing for anyone who grabbed a row where
        // it reads. The cause was the title's own tap recognizer (the hand-rolled double-click
        // rename) consuming the mouse-down that `List`'s `.onMove` needs. The title carries no
        // SwiftUI tap recognizer of any kind today, and no subview either — double-click is
        // detected by a passive `.leftMouseDown` monitor outside the view hierarchy
        // (`SidebarInputMonitor.swift`), which returns every event unchanged, so the drag still
        // sees the mouse-down it needs.
        //
        // Deliberately presses the title rather than blank space — blank space always worked,
        // so a test that grabbed there would have passed against the broken build. That is
        // what the control above is for, and why it is a separate activity.
        //
        // The assertion is "the order changed", not a specific final order: where a drop lands
        // depends on drop-target geometry that varies with row height and list insets, and
        // pinning it would buy flakiness rather than coverage. The bug was that *nothing*
        // happened, and that is exactly what this distinguishes.
        //
        // MATCHED PAIR, do not separate or delete independently: this activity ("a session
        // reorders by dragging its title text") and "double-clicking a session title renames
        // it" (below, after the context-menu rename group) each pin one half of the conflict
        // commit `b18b86a` traded away and this branch put back. Satisfy only the drag test
        // and someone removes the monitor — rename dies again, which is literally
        // what `b18b86a` did. Satisfy only the rename test and someone reaches for
        // `.onTapGesture(count: 2)` on the title — drag dies again. Losing that knowledge is
        // exactly what happened last time; writing it down here is the point.
        XCTContext.runActivity(named: "a session reorders by dragging its title text") { _ in
            let before = (0..<3).map { rows.element(boundBy: $0).value as? String }

            rows.element(boundBy: 0).press(
                forDuration: 0.6, thenDragTo: rows.element(boundBy: 2)
            )
            settle()

            let after = (0..<3).map { rows.element(boundBy: $0).value as? String }
            XCTAssertNotEqual(
                after, before,
                "dragging a row by its title text did not reorder anything — the title's tap "
                + "recognizer is probably swallowing the mouse-down again (got \(after))"
            )
            XCTAssertEqual(
                after.compactMap { $0 }.sorted(), before.compactMap { $0 }.sorted(),
                "the reorder lost or duplicated a session"
            )
        }

        // Dragging leaves first responder in the sidebar. Every group below this point acts on
        // the terminal — Select All / Copy, and ⌘F, which routes through libghostty — so hand
        // focus back by clicking the detail pane, the way a user would. Without this the drag
        // groups silently break the clipboard and find-bar assertions further down.
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click()
        settle()

        // Deliberately AFTER the drag groups. Renaming makes a row's title the string
        // "renamed", but more importantly a failure here used to abort the whole test before
        // the drag groups ran, hiding their result — the reordering evidence is worth more
        // than the ordering convenience of renaming first.
        XCTContext.runActivity(named: "the context menu renames a session") { _ in
            // Targeted by accessibility identifier rather than outline position: a positional
            // lookup would silently break the moment SwiftUI changes how it flattens sections.
            let title = rows.firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            // Right-click, not double-click. Rename moved off the title's click path so that
            // a row can be dragged by its title — see the note on the `Text` in SessionSidebar.
            title.rightClick()
            let rename = app.menuItems["Rename"]
            XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename item in the row menu")
            rename.click()

            let field = app.textFields["session-title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeKey("a", modifierFlags: .command)
            // "renamed" was never on screen before this point, so the assertion below cannot
            // pass vacuously.
            field.typeText("renamed\n")

            XCTAssertTrue(app.staticTexts["renamed"].waitForExistence(timeout: 5))
        }

        // MATCHED PAIR, do not separate or delete independently: see the note on "a session
        // reorders by dragging its title text" above, which this activity completes. Rename
        // was traded away in `b18b86a` to fix drag-to-reorder because the two looked
        // incompatible; they are not, once detection moves out of the row entirely
        // (`SidebarInputMonitor.swift`). This activity is the half of that pair that proves rename
        // survives; the drag activity above proves reordering does. Deleting either one alone
        // reopens the trade this branch closed.
        XCTContext.runActivity(named: "double-clicking a session title renames it") { _ in
            let otherTitlesBefore = (1..<3).map { rows.element(boundBy: $0).label }

            // Deliberately a COORDINATE double-click, not `rows.element(boundBy: 0).doubleClick()`.
            //
            // Measured: `XCUIElement.doubleClick()` drives an accessibility action and emits no
            // mouse events at all. Instrumenting the app's own local event monitor during a full
            // smoke run logged exactly three `.leftMouseUp` events for the entire suite, and both
            // in the main launch were coordinate-based clicks — every element-level `.click()`
            // and `.doubleClick()` produced none. Since rename is driven by real mouse input
            // (see `SidebarInputMonitor.swift` for why it cannot be a gesture or a subview), an
            // element-level double click can never exercise it, and a test written that way
            // fails against a perfectly working build.
            //
            // A coordinate double-click posts real events, which is also what a user does.
            rows.element(boundBy: 0)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .doubleClick()
            let field = app.textFields["session-title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "double-clicking a row title must open the rename field")
            // A double-click must open exactly ONE field. This and the unchanged-titles check
            // below are what distinguish "renamed the row I clicked" from "renamed some other
            // row": a mechanism that resolved the wrong row would still open exactly one field,
            // so the count alone is not enough and the pair is deliberate.
            XCTAssertEqual(
                app.textFields.matching(identifier: "session-title-field").count, 1,
                "exactly one rename field should be open after a single double-click"
            )
            field.typeKey("a", modifierFlags: .command)
            field.typeText("dbl renamed\n")
            XCTAssertTrue(app.staticTexts["dbl renamed"].waitForExistence(timeout: 5))

            let otherTitlesAfter = (1..<3).map { rows.element(boundBy: $0).label }
            XCTAssertEqual(
                otherTitlesAfter, otherTitlesBefore,
                "double-clicking row 0 must not change any other row's title"
            )
        }

        // Return-to-rename is reachable only while the sidebar's table is first responder, not
        // while the terminal or a rename field owns it (`SidebarInputMonitor.handleKeyDown`).
        // Reaching that state takes two clicks, for the measured reason spelled out below.
        XCTContext.runActivity(named: "Return renames the selected session while the sidebar has focus") { _ in
            let target = rows.element(boundBy: 1)
            // A COORDINATE click, for the same measured reason the double-click activity above
            // uses one: `XCUIElement.click()` drives an accessibility action and emits no mouse
            // event at all, so the monitor never sees it and focus never moves. A coordinate
            // click posts a real mouse event, the way a user's click does.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            // Then click the SAME row again, well after the double-click interval.
            //
            // Measured, and it is the crux of this feature: the first click switches session,
            // which re-parents the terminal surface, and `TerminalPane` calls
            // `Ghostty.moveFocus(to: surface)` on re-parent — asynchronously, so it lands after
            // the sidebar claims first responder and hands the keyboard straight back to the
            // terminal. That auto-focus is right for a terminal app and is deliberately left
            // alone. It only fires when the surface actually changes, so a second click on the
            // already-selected row switches nothing and the sidebar keeps focus.
            //
            // The two `settle()` calls (~1s) put the second click far outside the double-click
            // interval; without them this would register as a double-click and open the rename
            // field for the WRONG reason, passing whether or not Return works.
            settle()
            settle()
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            // The two clicks above must NOT have registered as a double-click, or this activity
            // would be measuring double-click-to-rename a second time instead of Return. The
            // settles put them ~1s apart against a 0.5s default interval, but that interval is a
            // user preference and can be raised, so assert the intent rather than trusting it.
            XCTAssertFalse(
                app.textFields["session-title-field"].exists,
                "the two focusing clicks registered as a double-click; this activity would then "
                + "prove nothing about Return. Raise the settle count or lower the system "
                + "double-click interval."
            )
            XCTAssertTrue(
                app.cells.element(boundBy: 2).isSelected,
                "clicking row 1 must select it before Return is asserted against it"
            )

            // No Tab here, deliberately. The terminal consumes Tab like any other key, and the
            // coordinate click above is what moves first responder to the sidebar table (see
            // `SidebarInputMonitor`, which claims focus on a single click exactly as
            // `SurfaceView` does for the terminal). Pressing Tab first would move focus back
            // off the table and break this.
            app.typeKey(.return, modifierFlags: [])
            let field = app.textFields["session-title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "Return did not open the rename field while the sidebar had focus")

            // MEASURED, not assumed: the plan required that Return not be hijacked while the
            // rename field ITSELF is open, and the negative activity below only measures
            // TERMINAL focus — it says nothing about RENAME-FIELD focus. Focus has moved from
            // the sidebar `List` to this `TextField` by now, so a second Return here should be
            // the field's own `.onSubmit` committing it, not a second rename opening on top of
            // it and not `store.renameRequest` being left set with nothing left to consume it
            // — which would silently kill Return-to-rename for every row after this one.
            field.typeKey("a", modifierFlags: .command)
            // "return renamed" was never on screen before this point, so the assertion below
            // cannot pass vacuously.
            field.typeText("return renamed")
            app.typeKey(.return, modifierFlags: [])

            XCTAssertTrue(app.staticTexts["return renamed"].waitForExistence(timeout: 5))
            XCTAssertEqual(
                app.textFields.matching(identifier: "session-title-field").count, 0,
                "Return while the rename field was open should commit it, not leave it open "
                + "or open a second one"
            )

            // And the request channel must not have been left stranded by that in-field
            // Return: Return must still work on a different row right afterward.
            // Same two-click shape as above, and for the same measured reason: the first click
            // switches session and `TerminalPane` hands focus back to the terminal, so only a
            // second click on the now-selected row leaves the sidebar focused. The settles keep
            // that second click outside the double-click interval, so this cannot pass by
            // accidentally triggering double-click-to-rename instead of Return.
            let other = rows.element(boundBy: 0)
            other.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            settle()
            settle()
            other.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(
                field.waitForExistence(timeout: 5),
                "Return should still open the rename field on another row — renameRequest "
                + "must not have been left stranded by the in-field Return above"
            )
            app.typeKey(.escape, modifierFlags: [])
            settle()
            XCTAssertFalse(
                field.exists,
                "Escape should close the rename field opened for this stranding check"
            )
        }

        // The negative half of the pair above: Return must not reach for a rename when the
        // terminal, not the sidebar `List`, holds focus — otherwise every Return a user sends
        // to the shell while a session is selected would hijack its title instead. Clicking
        // the detail pane is the same focus-transfer this file already relies on for the
        // Copy and ⌘F groups further down, so it is trusted here too.
        XCTContext.runActivity(named: "Return does not rename when the terminal, not the sidebar, has focus") { _ in
            app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
                .click()
            settle()

            app.typeKey(.return, modifierFlags: [])
            settle()

            XCTAssertFalse(
                app.textFields["session-title-field"].exists,
                "Return opened the rename field even though focus was in the terminal, not the sidebar"
            )
        }

        // ⌘R is a menu key equivalent, not a raw keystroke handled by `SidebarInputMonitor`:
        // `MenuKeyEquivalents.swift` offers this binding to the main menu before any view sees
        // it. So unlike Return above, it does NOT require the sidebar table to hold first
        // responder — no two-click focus dance is needed here, just select the row (a plain
        // `.click()`, as the Mark-as-Unread activity below also uses for selection) and press
        // ⌘R. The row menu's own "Rename" item and the double-click and Return paths above all
        // route through the same `store.renameRequest` channel; this activity is the fourth
        // path into it.
        XCTContext.runActivity(named: "Cmd-R opens the rename field for the selected session and commits it") { _ in
            let target = rows.element(boundBy: 2)
            target.click()
            XCTAssertTrue(
                app.cells.element(boundBy: 3).isSelected,
                "clicking row 2 must select it before Cmd-R is asserted against it"
            )

            app.typeKey("r", modifierFlags: .command)
            let field = app.textFields["session-title-field"]
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "Cmd-R did not open the rename field for the selected session")

            field.typeKey("a", modifierFlags: .command)
            // "cmdR renamed" was never on screen before this point, so the assertion below
            // cannot pass vacuously.
            field.typeText("cmdR renamed\n")

            XCTAssertTrue(app.staticTexts["cmdR renamed"].waitForExistence(timeout: 5))
        }

        // The human approved "Mark as Unread" conditional on one thing: re-activating an
        // inactive tab clears the mark. That condition, not just the mark itself, is what this
        // activity asserts. The precondition that keeps "the dot appears" from passing
        // vacuously is not that row 2 is untouched — it was selected during the ⌘⇧]/⌘⇧[
        // cycling group and moved by both drag groups above. It has no status dot yet because
        // no `claude` actually runs under test, so nothing has ever set a `SessionStatus` for
        // it, and `SessionStatusIcon` draws nothing for a session that is neither statused nor
        // marked unread.
        XCTContext.runActivity(
            named: "Mark as Unread is first in the context menu, marks the row, and clears on reselect"
        ) { _ in
            let title = rows.element(boundBy: 2)
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let markedCell = app.cells.element(boundBy: 3)
            let dot = markedCell.descendants(matching: .any).matching(identifier: "session-status").firstMatch

            // Assert on the LABEL, not on the icon's existence.
            //
            // Measured: the seeded sessions DO carry a live status here, so the status icon is
            // already present before anything is marked — an existence check would fail its own
            // precondition. What "unread" changes is the wording: `SessionStatus.tooltip(unread:)`
            // returns "Finished — not yet viewed" for an idle+unread session and the plain status
            // tooltip otherwise, and that label is what the icon publishes.
            let unreadWording = "not yet viewed"
            XCTAssertTrue(dot.waitForExistence(timeout: 5), "precondition: the row has a status icon")
            XCTAssertFalse(
                dot.label.contains(unreadWording),
                "precondition: row must not already read as unread before it is marked, got \(dot.label)"
            )

            title.rightClick()
            // `app.menus.firstMatch` can resolve to a menu-bar menu rather than this popup —
            // scope to the menu that actually holds this row's items by requiring a menu item
            // this row's context menu is known to carry ("Rename"; see the group above).
            let menu = app.menus.containing(.menuItem, identifier: "Rename").firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "no context menu appeared")
            let firstItem = menu.menuItems.element(boundBy: 0)
            XCTAssertEqual(
                firstItem.title, "Mark as Unread",
                "Mark as Unread must be the FIRST item in the row's context menu, got \(firstItem.title)"
            )
            // Click the already-resolved element rather than re-querying by
            // `.accessibilityIdentifier`: SwiftUI's `.accessibilityIdentifier` on a
            // `contextMenu` Button commonly does not reach the backing `NSMenuItem`, so
            // `app.menuItems["session-mark-unread"]` is not the proven idiom in this file —
            // title-based lookup (as used for "Rename" above) is.
            firstItem.click()

            XCTAssertTrue(
                waitFor(timeout: 5) { dot.exists && dot.label.contains(unreadWording) },
                "marking a session unread did not change its status icon to the unread wording, got \(dot.label)"
            )

            // Selecting a DIFFERENT row, then the marked row again, must clear the mark.
            rows.element(boundBy: 0).click()
            settle()
            title.click()

            XCTAssertTrue(
                waitFor(timeout: 5) { dot.exists && !dot.label.contains(unreadWording) },
                "re-selecting a marked row must clear its unread mark, but the icon still reads "
                + "as unread (\(dot.label))"
            )
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

        // Preferences (⌘,) opens a separate window whose tabs are wired to the flag catalog.
        // The window is located by `preferencesWindow(_:)` rather than by title — see that
        // helper's doc comment for why, and for the coupling that costs.
        XCTContext.runActivity(named: "⌘, opens Preferences with its four tabs") { _ in
            app.typeKey(",", modifierFlags: .command)
            let prefs = preferencesWindow(app)
            XCTAssertTrue(prefs.waitForExistence(timeout: 5), "Preferences window did not open")
            // Agents replaced the old single-agent Claude tab; Tools arrived with the external
            // tools pane. Asserted by name so a renamed or dropped tab fails here — where the
            // message names the tab — rather than downstream as a missing window.
            XCTAssertTrue(prefs.buttons["Agents"].exists)
            XCTAssertTrue(prefs.buttons["Projects"].exists)
            XCTAssertTrue(prefs.buttons["Shell & Environment"].exists)
            XCTAssertTrue(prefs.buttons["Tools"].exists)
        }

        XCTContext.runActivity(named: "toggling a control updates the command field") { _ in
            let prefs = preferencesWindow(app)
            // The agent flag editor lives behind the Agents tab now. No row click is needed to
            // reach Claude's: `AgentsSettingsTab` renders `agents.first` when its list has no
            // selection yet, and `Preferences.defaultAgents` puts `.claude` first.
            prefs.buttons["Agents"].click()
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
            // The activity immediately above does ⌘A + delete in the command field, which
            // drives `applyTextToControls` -> mutates `flags` -> trips
            // `.onChange(of: flags) { syncTextFromControls() }` (FlagEditor.swift:119). If this
            // activity's checkbox click lands inside that churn, the click either no-ops or sets
            // `pendingDangerousFlag` only for the re-render to immediately clear it — both look
            // identical from here as "no confirmation appeared". Settling first drains that
            // churn before the click, so a real failure of the confirmation gate is not
            // masked by a timing collision with the previous activity.
            settle()

            let prefs = preferencesWindow(app)
            let checkbox = prefs.checkBoxes.matching(identifier: "Skip all permission checks").firstMatch
            XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
            XCTAssertEqual(checkbox.value as? Int, 0)

            checkbox.click()
            // Scoped to the Preferences window's own sheets, not `app.sheets.firstMatch` — the
            // latter can resolve to an unrelated window's sheet and report a false positive.
            let sheet = prefs.sheets.firstMatch
            if !sheet.waitForExistence(timeout: 5) {
                // This gate guards `--dangerously-skip-permissions`, so a missed click and a
                // genuinely broken confirmation must not read as the same failure.
                XCTAssertEqual(
                    checkbox.value as? Int, 0,
                    "SECURITY: no confirmation appeared AND the bypass toggled on — the gate did not fire"
                )
                XCTFail("no confirmation appeared, but the checkbox stayed off — missed click, not a broken gate")
                return
            }
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
