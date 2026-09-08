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

    /// Launches the app on an isolated slate and returns it once its window exists.
    ///
    /// Extracted so a behaviour that does NOT depend on the shared sequence can live in its own
    /// test function and be run alone with `-only-testing:`. The giant
    /// `testTheWholeShellInOneSession` shape exists because most of its groups mutate state the
    /// next one reads; a group needing none of that should not inherit the property that any
    /// earlier failure stops it running at all.
    ///
    /// - `-ApplePersistenceIgnoreState`: XCUITest spawns the app via a raw exec, not
    ///   LaunchServices, so the macOS window-restoration handshake that normally creates the
    ///   initial window never completes and no window is made. Bypassing restoration matches
    ///   real-user launch semantics and changes no shipped behavior.
    /// - `-FlightDeckResetState`: start from a known seeded slate rather than whatever a previous
    ///   run persisted. This is the only thing isolating the test from real session state —
    ///   `smoke.sh` no longer deletes it, because doing so destroyed the developer's own sessions
    ///   on every run.
    /// - `-FlightDeckStateDir`: `-FlightDeckResetState` covers sessions and preferences but NOT
    ///   the search index, whose path is derived independently in `AppDelegate`. Without it a run
    ///   opens the developer's real `search-index.sqlite` and starts a backfill over their whole
    ///   transcript corpus mid-test.
    /// Shared by `launchIsolated(_:)` and `launchPreservingState(_:)` so the two can name the
    /// same directory without repeating the literal — the whole point of the pair is that a
    /// relaunch land on the state the first launch wrote.
    private static let isolatedStateDir = NSTemporaryDirectory() + "fd-smoke-state"

    @discardableResult
    private func launchIsolated(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
            "-FlightDeckStateDir", Self.isolatedStateDir,
        ] + extraArguments
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared"
        )
        return app
    }

    /// The counterpart to `launchIsolated(_:)`: relaunches against the SAME state directory but
    /// WITHOUT `-FlightDeckResetState`, so `SessionStore.restore()` runs against whatever the
    /// previous launch left in `sessions.json` instead of a freshly seeded slate. This is what
    /// `testSessionReattachesWithScrollbackAfterRelaunch` uses to prove a session survives a
    /// kill-and-relaunch: reusing `isolatedStateDir` rather than taking a path parameter is what
    /// guarantees the second launch actually sees the first one's session.
    ///
    /// Also used for that same test's FIRST launch, paired with `clearIsolatedStateDir()` —
    /// see that method's doc comment for why `launchIsolated(_:)` cannot be used there.
    @discardableResult
    private func launchPreservingState(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckStateDir", Self.isolatedStateDir,
        ] + extraArguments
        app.launch()
        app.activate()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared"
        )
        return app
    }

    /// Deletes `isolatedStateDir` outright, so a launch against it starts from a genuinely
    /// empty slate WITHOUT going through `-FlightDeckResetState`.
    ///
    /// That flag cannot be used for `testSessionReattachesWithScrollbackAfterRelaunch`'s FIRST
    /// launch: `FlightDeckApp.makeStore` wires `SessionStore`'s persistence to `nil` under
    /// reset (`persistence: resetState ? nil : Self.fileSessionPersistence()`), so the seeded
    /// session is never written to `sessions.json` at all, and `sessionUUIDFromIsolatedState()`
    /// would find nothing to capture before the app is even killed. Clearing the directory by
    /// hand and launching with `launchPreservingState(_:)` (live persistence) instead reaches
    /// the same clean slate a different way: `SessionStore.init`'s
    /// `if resetState || !restore() { seedInitialSession() }` still seeds a fresh session on an
    /// empty directory — `restore()` returns false, same as under reset — but this time
    /// `seedInitialSession()` also PERSISTS it, which is what makes the capture below possible.
    ///
    /// `try?` swallows "doesn't exist" along with everything else: a launch against a directory
    /// this failed to clear for some other reason would surface as that launch's own
    /// window-existence assertion failing, which names the real problem better than this would.
    private func clearIsolatedStateDir() {
        try? FileManager.default.removeItem(atPath: Self.isolatedStateDir)
    }

    /// Resolves `testSessionReattachesWithScrollbackAfterRelaunch`'s OWN session id by reading
    /// its isolated state directory's `sessions.json` directly, rather than assuming there is
    /// exactly one session anywhere — `/tmp/flight-deck-<uid>` (where the daemon actually lives)
    /// is shared with every other live Flight Deck session on this machine, so teardown needs
    /// the precise id to target rather than a directory-wide guess.
    private func sessionUUIDFromIsolatedState() -> UUID? {
        struct Entry: Decodable { let id: UUID }
        struct Snapshot: Decodable { let sessions: [Entry] }
        let url = URL(fileURLWithPath: Self.isolatedStateDir).appendingPathComponent("sessions.json")
        guard
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return snapshot.sessions.first?.id
    }

    /// Kills exactly one session's `fd-abduco` daemon, by id, and removes its socket and
    /// pidfile — SIGTERM, a short poll, then SIGKILL if it is still alive, mirroring
    /// `DaemonControl.terminate(_:)`'s own mechanics without depending on it: this test bundle
    /// is a separate process with no access to the app's internals, only to the same
    /// well-known `/tmp/flight-deck-<uid>/<id>.sock(.pid)` layout (`SessionDaemon.swift`) the
    /// app itself writes to.
    ///
    /// Deliberately takes a single `id` rather than a directory to sweep: that directory holds
    /// every OTHER live session's daemon too (the developer's own, or a teammate's), and this
    /// must never touch them.
    private func terminateOwnDaemon(_ id: UUID) {
        let socketPath = "/tmp/flight-deck-\(getuid())/\(id.uuidString.lowercased()).sock"
        let pidPath = socketPath + ".pid"
        defer {
            unlink(socketPath)
            unlink(pidPath)
        }
        guard
            let contents = try? String(contentsOfFile: pidPath, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0
        else { return }
        guard kill(pid, 0) == 0 else { return }

        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            usleep(50_000)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    /// ⌘K opens the search overlay while a terminal has focus.
    ///
    /// The one regression no unit test can catch. Ghostty binds `super+k` to `clear_screen` as a
    /// `performable` binding, and `MenuKeyEquivalents.shouldOfferToMenu` withholds performable
    /// bindings from the main menu — so without the `super+k=unbind` line in
    /// `GhosttyDefaults.conf`, the menu item renders perfectly and never fires whenever a
    /// terminal has focus, which is essentially always. `GhosttyDefaultsTests` asserts that line
    /// is present, but reads the TEST bundle's copy of the file, so it cannot catch the app
    /// target dropping the resource. Only a real focused surface shows that.
    ///
    /// Its own function rather than a group inside `testTheWholeShellInOneSession`: it depends on
    /// nothing the other groups set up, and as a group it could not run at all whenever an
    /// earlier, unrelated group failed — which is exactly what happened on its first run.
    func testCommandKOpensTheSearchOverlayOverAFocusedTerminal() {
        let app = launchIsolated()

        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["Search sessions and conversations"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K did not open the overlay")

        field.typeText("session")
        // TODO: assert a result row actually appeared. `app.staticTexts.count > 0` was here
        // before and asserted nothing — the sidebar always has static text on screen, filtered
        // or not. Doing this properly needs an accessibility identifier on the result rows in
        // `SearchOverlayView` to query against.

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 2), "Esc did not close the overlay")
    }

    /// The window title names the active project: `Flight Deck - <project>`.
    ///
    /// `WindowTitleTests` pins the rule and the store property it reads, but neither can see
    /// the only step that can silently do nothing — SwiftUI resolving `RootView`'s
    /// `navigationTitle` onto the real `NSWindow`. A `navigationTitle` placed on the wrong
    /// view of a `NavigationSplitView` renders nowhere on macOS and reports no error; the
    /// window simply keeps the `Window(WindowTitle.base, id:)` scene title. So the assertion
    /// is deliberately for the *decorated* title and not `hasPrefix("Flight Deck")`, which
    /// that failure would satisfy.
    ///
    /// The expected project is the seeded slate's: `-FlightDeckResetState YES` makes
    /// `SessionStore.seedInitialSession` open the home directory, so the name is the home
    /// folder's. Looked up rather than written out, so this does not pin the suite to one
    /// developer's machine.
    ///
    /// Looked up through `getpwuid`, NOT `NSHomeDirectory()`. The UI-test runner is a
    /// container-backed process, so its `NSHomeDirectory()` is
    /// `~/Library/Containers/<runner>/Data` and the name comes back as "Data" — while the
    /// app under test is unsandboxed and seeds from the real `/Users/<user>`. The passwd
    /// entry is the same for both.
    ///
    /// Its own function rather than a group inside `testTheWholeShellInOneSession`, for that
    /// suite's stated rule: it depends on none of the shared sequence, so it should not be
    /// unrunnable whenever an unrelated earlier group fails.
    func testTheWindowTitleNamesTheActiveProject() {
        let app = launchIsolated()
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let project = URL(fileURLWithPath: home, isDirectory: true).lastPathComponent

        XCTAssertEqual(
            app.windows.firstMatch.title, "Flight Deck - \(project)",
            "the window title does not name the active project"
        )
    }

    /// The spec's end-to-end payoff: a live session's scrollback survives Flight Deck being
    /// killed and relaunched, because the pty lives inside a detached `fd-abduco` daemon rather
    /// than inside Flight Deck's own process. `app.terminate()` kills the ghostty/Flight Deck
    /// client, but Phase 1 starts each session's daemon `setsid`'d specifically so that SIGTERM
    /// to its parent never reaches it, and the second launch's `SessionStore.restore()` finds
    /// the session recorded in `sessions.json` and attaches (`fd-abduco -a`) to whatever is
    /// still running for it — `LaunchPlan.decide` only types a fresh resume command when
    /// `daemonControl.isLive` says otherwise. A cold-started shell would never have seen this
    /// test's marker at all, which is exactly the failure mode this guards against.
    ///
    /// Its own launch, like the other standalone behaviours in this file: nothing here depends
    /// on the shared sequence, and the sequence's ⌘Q at the very end would leave no app alive
    /// for this test to kill and relaunch anyway.
    ///
    /// **Deliberately does not use `launchIsolated(_:)` for its first launch either** — see
    /// `clearIsolatedStateDir()`'s doc comment for why `-FlightDeckResetState` is unusable here:
    /// it wires `SessionStore`'s persistence to `nil`, so nothing would ever be written to
    /// `sessions.json` for this test to capture. `clearIsolatedStateDir()` +
    /// `launchPreservingState(_:)` reaches the same clean slate with persistence left live.
    ///
    /// **Reading terminal output.** `SurfaceView.accessibilityRole` reports `.textArea`, which
    /// XCUITest surfaces as a `textView` — the same element kind this file already reads with
    /// `.value as? String` for the Preferences command field. Its value is
    /// `cachedScreenContents`, a 500ms-cached live snapshot of the terminal's screen, so polling
    /// it is how this test observes output without a dedicated on-screen text query.
    ///
    /// **The marker.** A UUID-suffixed string never seen on screen before this test types it, so
    /// neither assertion can pass vacuously — a stale sighting from an earlier run or a
    /// similar-looking prompt cannot satisfy it.
    ///
    /// **Why there is a wait before the first `echo`.** A freshly seeded session already has a
    /// resume/launch command (`claude ...`) queued into its shell the moment the surface is
    /// created (`LaunchPlan.decide`'s cold path) — and no `claude` binary exists under test, so
    /// it fails immediately with "command not found" and the shell falls back to its own prompt.
    /// Typing this test's `echo` before that settles risks interleaving the two into one
    /// corrupted line, so this waits for the shell to finish that round trip first.
    func testSessionReattachesWithScrollbackAfterRelaunch() {
        let nonce = UUID().uuidString.prefix(8)
        let marker = "FD-REATTACH-\(nonce)"

        // Clear-then-launch-without-reset, not `launchIsolated()` — see this test's own doc
        // comment and `clearIsolatedStateDir()`'s for why: `-FlightDeckResetState` disables
        // `SessionStore` persistence outright, which would leave `sessions.json` unwritten for
        // the capture just below to ever find.
        clearIsolatedStateDir()
        var app = launchPreservingState()

        // Captured HERE, right after the seeded session is confirmed running, and BEFORE
        // anything below that could tear it down — deliberately NOT resolved from inside
        // teardown. A successful in-app close (below) runs `SessionStore.closeSession` ->
        // `persist()`, which writes an EMPTY `sessions` array back to this same
        // `sessions.json`; resolving the id after that point would read `nil` on every
        // SUCCESSFUL run and only ever "find" one on a run that already failed to clean up —
        // exactly backwards. Polled rather than read once: `persist()` runs synchronously, but
        // nothing guarantees it has already landed on disk in the instant the window appears.
        var sessionID: UUID?
        _ = waitFor(timeout: 5) {
            sessionID = sessionUUIDFromIsolatedState()
            return sessionID != nil
        }
        guard let sessionID else {
            XCTFail(
                "could not resolve the seeded session's id from "
                + "\(Self.isolatedStateDir)/sessions.json"
            )
            return
        }

        // Unconditional teardown so a failure partway through this test cannot leak the
        // daemon and its socket/pidfile under `/tmp/flight-deck-<uid>` past the run. The
        // in-app graceful close (`SessionStore.closeSession` -> `DaemonControl.terminate`, the
        // same path a user quitting a tab takes) is attempted first as a nicety, but does not
        // gate cleanup and must not fail the test if its hover-gated button never appears —
        // `terminateOwnDaemon` below covers cleanup unconditionally either way. Targeting the
        // `sessionID` captured above (not re-resolved here) is what makes this idempotent and
        // correct on the success path: whether or not the close above already tore the daemon
        // down, `terminateOwnDaemon` finds no live pid in that case and just unlinks whatever
        // socket/pidfile remain — a no-op, not a failure.
        //
        // Never a directory-wide sweep: `/tmp/flight-deck-<uid>` is shared with every other
        // live Flight Deck session on this machine (the developer's own, or a teammate's), so
        // only `sessionID` is ever targeted.
        defer {
            if app.state != .notRunning {
                let rows = app.staticTexts.matching(identifier: "session-row-title")
                rows.firstMatch.hover()
                let close = app.buttons["close-session"].firstMatch
                if close.waitForExistence(timeout: 5) {
                    close.click()
                    settle()
                }
                app.terminate()
            }
            terminateOwnDaemon(sessionID)
        }

        // Give the terminal keyboard focus — the same click this file already uses elsewhere
        // to hand focus from the sidebar back to the detail pane.
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click()
        settle()

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal surface found")
        func terminalText() -> String { (terminal.value as? String) ?? "" }

        // See the doc comment above: let the doomed `claude` resume attempt finish and the
        // shell return to its own prompt before typing anything of this test's own.
        settle()
        settle()
        settle()

        app.typeText("echo \(marker)\n")
        XCTAssertTrue(
            waitFor(timeout: 10) { terminalText().contains(marker) },
            "marker never appeared in the terminal before the app was killed"
        )

        // Kills the Flight Deck process outright. The session's `fd-abduco` daemon was started
        // `setsid`'d in Phase 1 specifically so it outlives its parent's death — this line is
        // the whole feature under test.
        app.terminate()

        // Same state directory, no `-FlightDeckResetState`: `SessionStore.restore()` reads the
        // session `sessions.json` recorded and, finding its daemon still live, attaches rather
        // than starting a fresh shell.
        app = launchPreservingState()

        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click()
        settle()

        let reattached = app.textViews.firstMatch
        XCTAssertTrue(
            reattached.waitForExistence(timeout: 10), "no terminal surface found after relaunch"
        )
        func reattachedText() -> String { (reattached.value as? String) ?? "" }

        // Presence is the whole proof, and count is deliberately not asserted. A correct
        // reattach shows the marker TWICE, not once: an interactive shell echoes typed input,
        // so both the input-echo line (`echo FD-REATTACH-<nonce>`) and the command's own output
        // line (`FD-REATTACH-<nonce>`) land in scrollback pre-terminate, and both replay on
        // reattach — the same echoed-prompt trap `CodexDialogDriver.swift:13-17` documents for
        // codex's own approval screens ("a live session carries the marker twice"). A cold
        // shell, by contrast, shows the marker ZERO times: `LaunchPlan.decide` only retypes the
        // resume command when `daemonControl.isLive` is false, and it retypes the ORIGINAL
        // `claude` command, not this test's `echo` — there is no path that retypes `echo` a
        // second time, so there is no over-count case to guard against either. Visible after
        // relaunch therefore means reattached-and-replayed; absent means cold-started; a count
        // would only be measuring the tty's own echo behavior, not the feature under test.
        XCTAssertTrue(
            waitFor(timeout: 10) { reattachedText().contains(marker) },
            "marker did not survive relaunch — the reattach replayed no scrollback (or the "
            + "session cold-started instead of reattaching)"
        )
    }

    /// Investigative, not a strict behaviour gate: does a LIVE `claude` session's on-screen
    /// TUI actually come back after Flight Deck is killed and relaunched, and does the
    /// reattached prompt still accept a freshly typed command? The scrollback test above
    /// proves the *text* the pty already emitted survives a relaunch; this asks the harder
    /// question the marker trick cannot answer — whether claude's alt-screen redraw and its
    /// live input box come back too, and whether the box is still wired up to receive input.
    /// Answered by DUMPING the terminal surface at three points (pre-detach, post-reattach,
    /// post-command) to stdout and as `XCTAttachment`s, so a human can read exactly what
    /// painted — the asserts here are deliberately light, because what shape a correct
    /// reattach takes is itself the open question.
    ///
    /// **Makes one real `claude` API call** (a one-word prompt, step 8 below) against the
    /// default, already-logged-in `~/.claude` account — this is not a fixture run.
    ///
    /// Shares its isolation machinery with `testSessionReattachesWithScrollbackAfterRelaunch`
    /// above: `clearIsolatedStateDir()` + `launchPreservingState()` for a clean slate with
    /// live persistence, `sessionUUIDFromIsolatedState()` to capture the daemon's id before
    /// anything could tear it down, and `terminateOwnDaemon(_:)` to reap only that daemon
    /// (never a directory-wide sweep) in teardown. See that test's doc comments for why each
    /// piece is shaped the way it is; this reuses them rather than re-deriving them.
    ///
    /// **No New Session UI needed.** The seeded initial session already IS a claude session:
    /// `SessionStore.seedInitialSession` calls `newSession(in:waking:)` with no `agent:`
    /// argument, and `Session.agent` defaults to `.claude` (`SessionModel.swift`). Confirmed
    /// below with a light assertion rather than assumed silently, so a change to that default
    /// would fail loudly here instead of this test silently investigating a codex session.
    ///
    /// **Detecting "claude painted".** `❯` (U+276F) is `InputBar.claudeMarker` —
    /// `InputBar.swift` documents it as the character Claude Code's own input box begins every
    /// row with, and `Fixtures/Claude/idle-empty-box.captured.txt` shows it landing at rest. A
    /// bare shell prompt never draws it, so polling the surface for that glyph is a reasonably
    /// specific signal that the TUI — not a `command not found` fallback shell — is on screen.
    /// Restated as a local literal rather than imported: this test bundle runs as a separate
    /// process from the app and cannot `import FlightDeck`.
    func testClaudeSessionReattachDisplayAndCommandFlush() {
        let claudeMarker: Character = "\u{276F}" // ❯ — see InputBar.claudeMarker

        // Clear-then-launch-without-reset, exactly like the scrollback test above — see that
        // test's doc comment and `clearIsolatedStateDir()`'s for why `-FlightDeckResetState`
        // is unusable here: it disables `SessionStore` persistence outright.
        clearIsolatedStateDir()
        var app = launchPreservingState()

        // Captured HERE, before anything below could tear the session down — see the
        // scrollback test's note on why this is polled rather than read once and resolved
        // before, not after, any close.
        var sessionID: UUID?
        _ = waitFor(timeout: 5) {
            sessionID = sessionUUIDFromIsolatedState()
            return sessionID != nil
        }
        guard let sessionID else {
            XCTFail(
                "could not resolve the seeded session's id from "
                + "\(Self.isolatedStateDir)/sessions.json"
            )
            return
        }

        // Unconditional teardown, exactly like the scrollback test: a failure partway through
        // must not leak the daemon and its socket/pidfile past this run. Targets only
        // `sessionID`, never a directory-wide sweep — `/tmp/flight-deck-<uid>` is shared with
        // every other live Flight Deck session on this machine.
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
            terminateOwnDaemon(sessionID)
        }

        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(
            waitFor(timeout: 10) { rows.count == 1 }, "expected exactly one seeded session"
        )

        // Give the terminal keyboard focus, the same click this file already uses elsewhere.
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click()
        settle()

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal surface found")
        func terminalText() -> String { (terminal.value as? String) ?? "" }

        // claude can take several seconds to boot before it paints its input box — generous
        // on purpose, this is the first thing under investigation.
        let painted = waitFor(timeout: 45) { terminalText().contains(claudeMarker) }
        XCTAssertTrue(
            painted,
            "claude never painted its input box before detach — is it installed and logged "
            + "in for the default ~/.claude account? got:\n\(terminalText())"
        )

        let preDetach = terminalText()
        print("PRE-DETACH SURFACE:\n\(preDetach)")
        let preDetachAttachment = XCTAttachment(string: preDetach)
        preDetachAttachment.name = "pre-detach"
        preDetachAttachment.lifetime = .keepAlways
        add(preDetachAttachment)

        // Kill Flight Deck outright. Phase 1 starts each session's `fd-abduco` daemon
        // `setsid`'d specifically so SIGTERM to its parent never reaches it — this line is
        // the detach half of the feature under investigation.
        app.terminate()

        // Same state directory, no `-FlightDeckResetState`: `SessionStore.restore()` finds
        // the session's daemon still live and attaches (`fd-abduco -a`) rather than starting
        // a fresh shell.
        app = launchPreservingState()

        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click()
        settle()

        let reattached = app.textViews.firstMatch
        XCTAssertTrue(
            reattached.waitForExistence(timeout: 10), "no terminal surface found after relaunch"
        )
        func reattachedText() -> String { (reattached.value as? String) ?? "" }

        // THE CRUX: does claude's alt-screen UI come back on reattach? Waited on generously
        // and then dumped — asserted only as non-empty (soft — the point is to SEE it, not to
        // pin a specific shape this investigation does not yet know to expect).
        _ = waitFor(timeout: 15) { !reattachedText().isEmpty }
        let postReattach = reattachedText()
        print("POST-REATTACH SURFACE:\n\(postReattach)")
        let postReattachAttachment = XCTAttachment(string: postReattach)
        postReattachAttachment.name = "post-reattach"
        postReattachAttachment.lifetime = .keepAlways
        add(postReattachAttachment)
        XCTAssertFalse(postReattach.isEmpty, "surface was completely empty after reattach")

        // Flush a fresh command at the reattached prompt — a real turn, kept to one cheap
        // word. Clicking first is what hands the reattached surface keyboard focus; the
        // surface changing at all after typing is this test's evidence that the box actually
        // accepted the keystrokes rather than swallowing them into a dead pty.
        reattached.click()
        settle()
        app.typeText("hi\n")
        _ = waitFor(timeout: 20) { reattachedText() != postReattach }

        let postCommand = reattachedText()
        print("POST-COMMAND SURFACE:\n\(postCommand)")
        let postCommandAttachment = XCTAttachment(string: postCommand)
        postCommandAttachment.name = "post-command"
        postCommandAttachment.lifetime = .keepAlways
        add(postCommandAttachment)
        XCTAssertNotEqual(
            postCommand, postReattach,
            "the surface did not change at all after typing and submitting — the reattached "
            + "input box may not be accepting keystrokes"
        )
    }

    func testTheWholeShellInOneSession() {
        let app = launchIsolated()
        let window = app.windows.firstMatch

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

            // Assert on whether the row READS as unread — not on the icon existing, and not on
            // one specific wording.
            //
            // `SessionStatusIcon` renders unread two different ways, and which one appears is
            // not something this test controls. With a live `SessionStatus` the label is
            // `SessionStatus.tooltip(unread:)` ("Finished — not yet viewed"); with a nil status
            // it is the literal "Unread"; and a nil status that is *not* marked renders nothing
            // at all, so the element does not exist. No `claude` runs under test, so nil-status
            // is the path actually measured here: absent before the mark, present reading
            // "Unread" after it, absent again once the mark clears.
            //
            // This used to assert the icon already existed as a precondition, on a comment
            // claiming the seeded sessions carry a live status. They do not — a stray `claude`
            // left over from an earlier run can give a row a status, which is presumably what
            // was measured once, and that made the precondition fail whenever no such process
            // happened to be around. Reading the state instead of the chrome holds either way.
            func readsUnread(_ label: String) -> Bool {
                label == "Unread" || label.contains("not yet viewed")
            }
            // Never interpolate `dot.label` unguarded: resolving `.label` on an element that
            // does not exist raises "Failed to get matching snapshot" and aborts the whole test
            // method, which is exactly how the stale precondition above took every later
            // activity down with it.
            func iconLabel() -> String { dot.exists ? dot.label : "<no status icon>" }

            XCTAssertFalse(
                dot.exists && readsUnread(dot.label),
                "precondition: row must not already read as unread before it is marked, got \(iconLabel())"
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
                waitFor(timeout: 5) { dot.exists && readsUnread(dot.label) },
                "marking a session unread did not make its row read as unread, got \(iconLabel())"
            )

            // Selecting a DIFFERENT row, then the marked row again, must clear the mark.
            rows.element(boundBy: 0).click()
            settle()
            title.click()

            // Cleared means "no longer reads as unread". With a nil status that is the icon
            // disappearing outright, so requiring it to still exist would assert the presence of
            // chrome the feature deliberately removes.
            XCTAssertTrue(
                waitFor(timeout: 5) { !dot.exists || !readsUnread(dot.label) },
                "re-selecting a marked row must clear its unread mark, but the row still reads "
                + "as unread (\(iconLabel()))"
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

        // The regression this exists for is not the search UI itself — it's ⌘K reaching the
        // menu at all while a terminal has focus. Ghostty binds ⌘K to `clear_screen` and
        // marks it `performable`, and `MenuKeyEquivalents.shouldOfferToMenu` withholds
        // performable bindings from the main menu — so a missing `keybind = super+k=unbind`
        // in `GhosttyDefaults.conf` leaves the menu item rendering perfectly and never firing.
        // A unit test asserts that line is present in the test bundle's copy of the file, but
        // only a real focused surface like this one can catch the app target dropping it.
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
