import XCTest

/// Settings → Flight Control against the app's routing fixture (`RoutingUIFixture`): add,
/// compile, confirm and fail a rule; dismiss a hint; the *new* badge, merge and rename on task
/// kinds — each with a screenshot attached (spec L3-R §9).
///
/// Skipped unless `TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1`. `scripts/smoke.sh` runs this whole UI
/// bundle, and these seize the foreground for a minute that gate should not pay. Run them with
/// `scripts/test-routing-ui.sh`, once — never in a loop.
final class RoutingUITests: XCTestCase {
    override func setUpWithError() throws {
        // Both spellings: `xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables, and
        // whether the prefix survives depends on the toolchain (see `ScreenshotTests`).
        let env = ProcessInfo.processInfo.environment
        guard env["FLIGHTDECK_ROUTING_UI"] == "1" || env["TEST_RUNNER_FLIGHTDECK_ROUTING_UI"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1 (scripts/test-routing-ui.sh) to run")
        }
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckRoutingFixture", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")
        return app
    }

    /// Located by content, like `TerminalSmokeTests.preferencesWindow`: the window holding the
    /// Agents tab button, because macOS titles the Settings window differently across releases.
    private func openFlightControl(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let prefs = app.windows.containing(.button, identifier: "Agents").firstMatch
        XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Settings never opened")
        prefs.buttons["Flight Control"].click()
        XCTAssertTrue(prefs.buttons["fc-section-routing"].waitForExistence(timeout: 5), "the Flight Control tab did not open")
        return prefs
    }

    private func shot(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "never showed \"\(text)\"; shows \"\(element.exists ? element.label : "nothing")\"",
                       file: file, line: line)
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, message, file: file, line: line)
    }

    private func addGlobalRule(_ sentence: String, in prefs: XCUIElement) {
        prefs.buttons["fc-section-routing"].click()
        let field = prefs.textFields["routing-add-field-global"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(sentence)
        prefs.buttons["routing-add-global"].click()
    }

    func testAddCompileAndConfirmARule() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Use Codex for unit and integration tests, and for complex algorithms", in: prefs)
        let state = prefs.staticTexts["routing-state-r1"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        waitFor(state, labelContains: "Draft")
        prefs.buttons["routing-compile-r1"].click()
        waitFor(state, labelContains: "Compiled")
        waitFor(prefs.staticTexts["routing-compiled-r1"], labelContains: "codex · gpt-6-sol · effort high · pool codex-default")
        shot(prefs, "routing-compiled")
        prefs.buttons["routing-confirm-r1"].click()
        waitFor(state, labelContains: "Confirmed")
        shot(prefs, "routing-confirmed")
    }

    func testACompileFailureShowsItsReason() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Use Codex when a task needs teleportation", in: prefs)
        XCTAssertTrue(prefs.buttons["routing-compile-r1"].waitForExistence(timeout: 5))
        prefs.buttons["routing-compile-r1"].click()
        waitFor(prefs.staticTexts["routing-state-r1"], labelContains: "Failed")
        waitFor(prefs.staticTexts["routing-failure-r1"], labelContains: "unknown dimension teleportation")
        shot(prefs, "routing-failed")
    }

    func testARuleHintCanBeDismissed() {
        let prefs = openFlightControl(launch())
        prefs.buttons["fc-section-routing"].click()
        let hint = prefs.staticTexts["routing-hint-p1"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "the fixture project's confirmed rule carries a hint")
        waitFor(hint, labelContains: "gpt-6-luna")
        shot(prefs, "routing-hint")
        prefs.buttons["routing-hint-dismiss-p1"].click()
        waitUntilGone(hint, "a dismissed hint stays gone")
    }

    func testTaskKindsNewBadgeMergeAndRename() {
        let prefs = openFlightControl(launch())
        prefs.buttons["fc-section-kinds"].click()
        let badge = prefs.staticTexts["kind-new-snapshot-tests"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "a planning-proposed kind starts out new")
        shot(prefs, "kinds-new")
        prefs.staticTexts["Snapshot tests"].click()
        waitUntilGone(badge, "opening a kind clears its badge")

        prefs.popUpButtons["kind-merge-picker"].click()
        prefs.menuItems["Tests"].click()
        prefs.buttons["kind-merge-apply"].click()
        waitFor(prefs.staticTexts["kind-status-snapshot-tests"], labelContains: "Merged into tests")
        waitFor(prefs.staticTexts["kind-note"], labelContains: "Re-routed")
        shot(prefs, "kinds-merged")

        prefs.staticTexts["Algorithm"].click()
        let rename = prefs.textFields["kind-rename-field"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("Algorithms and data structures")
        prefs.buttons["kind-rename-apply"].click()
        XCTAssertTrue(prefs.staticTexts["Algorithms and data structures"].waitForExistence(timeout: 5))
        shot(prefs, "kinds-renamed")
    }
}
