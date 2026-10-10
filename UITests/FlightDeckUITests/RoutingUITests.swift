import XCTest

/// Settings → Flight Control against the app's routing fixture (`RoutingUIFixture`): add a rule
/// with Return (it compiles at once) and Use it; read a failure's actionable reason; adjust a
/// rule through its pill popovers; reorder and delete through the context menu and ⌫; switch
/// model from a hint's popover; the *new* badge, merge and rename on task kinds — each with a
/// screenshot attached (spec L3-R §9).
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
        dismissFlightDeckCrashReports()
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
        prefs.openFlightControlTab()
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
        // A macOS SwiftUI `Text` exposes its string as the accessibility *value* with an empty
        // label (see the hierarchy attached to a failing run), so `label` alone never matches.
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "never showed \"\(text)\"; shows \"\(element.exists ? "\(element.value as? String ?? element.label)" : "nothing")\"",
                       file: file, line: line)
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, message, file: file, line: line)
    }

    /// Rows are addressed by identifier whatever role SwiftUI gives them (a status glyph is an
    /// image, Use is a button, the failure is static text).
    private func element(_ id: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Types a sentence into the global "New rule…" field and presses Return, which adds the rule
    /// and starts compiling it — there is no Add or Compile button.
    private func addGlobalRule(_ sentence: String, in prefs: XCUIElement) {
        prefs.selectFlightControlSection("fc-section-routing")
        let field = prefs.textFields["routing-new-global"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(sentence + "\n")
    }

    func testReturnAddsAndCompilesAndUseConfirms() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Use Codex for unit and integration tests, and for complex algorithms", in: prefs)
        let use = prefs.buttons["routing-use-r1"]
        XCTAssertTrue(use.waitForExistence(timeout: 10), "Return should add the rule and compile it with no further click")
        waitFor(element("routing-target-r1", in: prefs), labelContains: "Codex · GPT-6-Sol · high")
        XCTAssertTrue(element("routing-condition-r1-0", in: prefs).exists, "the compiled conditions show as pills")
        XCTAssertEqual(prefs.textFields["routing-new-global"].value as? String ?? "", "", "Return clears the field")
        shot(prefs, "routing-compiled")
        use.click()
        let status = element("routing-status-r1", in: prefs)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        waitFor(status, labelContains: "Live")
        waitUntilGone(use, "Use goes away once the rule is live")
        shot(prefs, "routing-live")
    }

    func testACompileFailureShowsAnActionableReason() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Anything UI-heavy uses Sonnet", in: prefs)
        let failure = element("routing-failure-r1", in: prefs)
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        waitFor(failure, labelContains: "try “sonnet”")
        waitFor(element("routing-status-r1", in: prefs), labelContains: "Failed")
        shot(prefs, "routing-failed")
    }

    func testPillPopoversAdjustTheCompiledRule() {
        let app = launch()
        let prefs = openFlightControl(app)
        addGlobalRule("Use Codex for unit and integration tests, and for complex algorithms", in: prefs)
        XCTAssertTrue(prefs.buttons["routing-use-r1"].waitForExistence(timeout: 10))

        // Target pill → model pop-up. Popovers are their own windows, so query the app.
        element("routing-target-r1", in: prefs).click()
        let model = app.popUpButtons["routing-target-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), "the target pill opens its popover")
        shot(app.windows.firstMatch, "routing-target-popover")
        model.click()
        app.menuItems["GPT-6-Luna"].click()
        waitFor(element("routing-target-r1", in: prefs), labelContains: "GPT-6-Luna")
        XCTAssertTrue(element("routing-adjusted-r1", in: prefs).waitForExistence(timeout: 5),
                      "a hand-adjusted rule is marked as no longer matching its sentence")
        XCTAssertTrue(prefs.buttons["routing-use-r1"].exists, "adjusting keeps the rule's state")
        app.typeKey(.escape, modifierFlags: [])
        waitUntilGone(model, "Escape closes the popover")

        // Condition pill → threshold slider and Remove Condition.
        element("routing-condition-r1-2", in: prefs).click()
        let remove = app.buttons["routing-condition-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "a condition pill opens its popover")
        shot(app.windows.firstMatch, "routing-condition-popover")
        remove.click()
        waitUntilGone(element("routing-condition-r1-2", in: prefs), "the removed condition's pill is gone")
        shot(prefs, "routing-adjusted")
    }

    func testContextMenuReordersAndDeleteKeyDeletes() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Use Codex for tests", in: prefs)
        addGlobalRule("Use Codex for algorithms", in: prefs)
        let first = element("routing-sentence-r1", in: prefs)
        let second = element("routing-sentence-r2", in: prefs)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertLessThan(first.frame.minY, second.frame.minY)

        second.rightClick()
        prefs.menuItems["Move Up"].click()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in second.frame.minY < first.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed, "Move Up puts r2 first: first match wins")
        shot(prefs, "routing-reordered")

        first.rightClick()
        prefs.menuItems["Delete"].click()
        waitUntilGone(first, "Delete in the context menu removes the rule")

        second.click()
        prefs.typeKey(.delete, modifierFlags: [])
        waitUntilGone(second, "⌫ deletes the selected rule")
    }

    func testAHintPopoverSwitchesModel() {
        let app = launch()
        let prefs = openFlightControl(app)
        prefs.selectFlightControlSection("fc-section-routing")
        let bulb = element("routing-hint-p1", in: prefs)
        XCTAssertTrue(bulb.waitForExistence(timeout: 5), "the fixture project's confirmed rule carries a hint")
        bulb.click()
        let text = app.descendants(matching: .any).matching(identifier: "routing-hint-text").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the lightbulb opens its popover")
        waitFor(text, labelContains: "gpt-6-luna")
        shot(app.windows.firstMatch, "routing-hint-popover")
        app.buttons["routing-hint-switch"].click()
        waitFor(element("routing-target-p1", in: prefs), labelContains: "GPT-6-Luna")
        waitUntilGone(bulb, "the hint goes once the rule routes to the suggestion")
        waitFor(element("routing-status-p1", in: prefs), labelContains: "Live")
        shot(prefs, "routing-hint-applied")
    }

    func testTaskKindsNewBadgeMergeAndRename() {
        let prefs = openFlightControl(launch())
        prefs.selectFlightControlSection("fc-section-kinds")
        let badge = prefs.staticTexts["kind-new-snapshot-tests"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "a planning-proposed kind starts out new")
        shot(prefs, "kinds-new")
        prefs.staticTexts["Snapshot tests"].firstMatch.click()
        waitUntilGone(badge, "opening a kind clears its badge")

        prefs.popUpButtons["kind-merge-picker"].click()
        prefs.menuItems["Tests"].click()
        prefs.buttons["kind-merge-apply"].click()
        waitFor(prefs.staticTexts["kind-status-snapshot-tests"], labelContains: "Merged into tests")
        waitFor(prefs.staticTexts["kind-note"], labelContains: "Re-routed")
        shot(prefs, "kinds-merged")

        prefs.staticTexts["Algorithm"].firstMatch.click()
        let rename = prefs.textFields["kind-rename-field"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("Algorithms and data structures")
        prefs.buttons["kind-rename-apply"].click()
        XCTAssertTrue(prefs.staticTexts["Algorithms and data structures"].firstMatch.waitForExistence(timeout: 5))
        shot(prefs, "kinds-renamed")
    }
}
