import XCTest

/// Drives Settings → Capability Index against two fixture snapshots and keeps a screenshot of
/// each state. Opt-in, because `scripts/smoke.sh` runs the whole FlightDeckUITests bundle and
/// this class would otherwise add a minute of foreground to every smoke run. Run it on its own:
///
///     TEST_RUNNER_INDEX_UI=1 xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
///       -destination 'platform=macOS' -derivedDataPath DerivedData \
///       test -only-testing:FlightDeckUITests/CapabilityIndexUITests
///
/// (`xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables; a bare `INDEX_UI` is also read.)
/// Hermetic: `-FlightDeckResetState YES` gives the app nil persistence, and
/// `-FlightDeckCapabilityIndexFixture` makes it COPY the fixture into a scratch directory, so the
/// rollback below never edits the repo — and a reset run never schedules a refresh, so nothing
/// spends tokens. The runner only passes the fixture's path; it never reads the folder itself
/// (the xctrunner sandbox cannot reach the repo; see ScreenshotTests).
final class CapabilityIndexUITests: XCTestCase {
    private func environmentValue(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_\(name)"]
    }

    /// `INDEX_UI_FIXTURE` wins: `#filePath` is the path on the Mac that COMPILED the bundle, and
    /// when the suite runs on the UI-test Mac (smoke-remote.sh) that checkout does not exist there,
    /// so the app would be handed a fixture folder that is not on disk.
    private var fixturePath: String {
        if let override = environmentValue("INDEX_UI_FIXTURE"), !override.isEmpty { return override }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UITests/FlightDeckUITests
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui", isDirectory: true).path
    }

    private func preferencesWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.button, identifier: "Agents").firstMatch
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: preferencesWindow(app).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHeatmapCitationsDiffAndRollback() throws {
        guard environmentValue("INDEX_UI") == "1" else {
            throw XCTSkip("INDEX_UI unset; run with TEST_RUNNER_INDEX_UI=1 -only-testing:FlightDeckUITests/CapabilityIndexUITests")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckCapabilityIndexFixture", fixturePath]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")

        app.typeKey(",", modifierFlags: .command)
        let prefs = preferencesWindow(app)
        XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Settings never opened")
        prefs.openFlightControlTab()
        prefs.selectFlightControlSection("fc-section-index")

        let heatmap = prefs.descendants(matching: .any)["index-heatmap"]
        XCTAssertTrue(heatmap.waitForExistence(timeout: 10), "the capability index pane never appeared")
        // The header is a static Text with only an identifier, so its text is its `value`;
        // fall back to `label` in case the OS exposes it the other way round.
        let header = prefs.descendants(matching: .any)["index-last-refresh"]
        let headerText = { (header.value as? String) ?? header.label }
        XCTAssertTrue(headerText().contains("2026-10-04 06:00 UTC"), "current snapshot should be the newer fixture: \(headerText())")

        // The cell is a Button with an explicit accessibilityLabel, so `label` carries the score.
        let cell = prefs.descendants(matching: .any)["index-cell-codex/gpt-6-sol[effort=high]-test-authoring"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(cell.label.hasPrefix("0.80"), "cell label: \(cell.label)")
        shoot(app, "1-heatmap")

        cell.click()
        let citation = app.descendants(matching: .any)["index-citation-url"].firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 5), "clicking a cell must show its cited rows")
        shoot(app, "2-citations")
        app.descendants(matching: .any)["index-citations-done"].firstMatch.click()

        let diffRow = prefs.descendants(matching: .any).matching(identifier: "index-diff-row").firstMatch
        XCTAssertTrue(diffRow.waitForExistence(timeout: 5), "the diff against the previous snapshot is missing")
        shoot(app, "3-diff")

        prefs.descendants(matching: .any)["index-rollback"].firstMatch.click()
        let rolledBack = expectation(for: NSPredicate(format: "value CONTAINS %@", "2026-09-27 06:00 UTC"),
                                     evaluatedWith: header)
        wait(for: [rolledBack], timeout: 10)
        XCTAssertTrue(cell.label.hasPrefix("0.60"), "after rollback the cell shows the older score: \(cell.label)")
        shoot(app, "4-after-rollback")
    }
}
