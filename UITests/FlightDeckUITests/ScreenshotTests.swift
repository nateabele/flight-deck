import AppKit
import XCTest

/// Produces the README screenshot.
///
/// Not part of the smoke gate. `scripts/smoke.sh` runs the behaviour tests; this runs from
/// `scripts/screenshot.sh` on demand, because a UI test seizes the foreground for the length
/// of its run and there is no reason to pay that on every suite.
///
/// The posed deck itself is built by `scripts/make-screenshot-fixture.py`, not here, and the
/// split is forced by a sandbox boundary rather than chosen. This bundle runs inside the
/// xctrunner sandbox: it cannot write to the repo, and it cannot write to `/private/tmp`
/// either — both come back `Operation not permitted`. The only place it can write is its own
/// container, which the app is a separate process and is not permitted to read, so a fixture
/// built here is a fixture the app cannot open. The script builds it; this consumes it.
///
/// What the picture shows is derived, not drawn. `applyRegistry` resolves the sidebar glyphs
/// from status files and `TranscriptWatcher` the sub-agent counts from transcripts, exactly as
/// in a live run. The fixture supplies inputs, never rendering.
///
/// The run touches no real state: the fixture redirects the session snapshot, the status
/// registry that would otherwise be `~/.claude/sessions`, and the transcript tree that would
/// otherwise be `~/.claude/projects`, and its shell replaces the login shell so no `claude` is
/// ever spawned. See `SessionFixture`.
final class ScreenshotTests: XCTestCase {
    /// Set by `scripts/screenshot.sh`. Read under both spellings because `xcodebuild test`
    /// hands the test process only variables prefixed `TEST_RUNNER_`, and whether the prefix
    /// survives depends on the toolchain.
    private func environmentValue(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_\(name)"]
    }

    private struct Expected: Decodable {
        let visibleTitles: [String]
    }

    func testCaptureReadmeScreenshot() throws {
        // Skip rather than fail when the fixture is absent. `scripts/smoke.sh` runs the whole
        // UI-test bundle, so this test runs there too — and it is not a behaviour gate, it is
        // a camera. Failing the smoke run because nobody asked for a screenshot would be a
        // false alarm on every suite. `scripts/screenshot.sh` sets the variable, and fails
        // loudly by itself if no image comes back.
        guard let fixturePath = environmentValue("FLIGHT_DECK_FIXTURE") else {
            throw XCTSkip("FLIGHT_DECK_FIXTURE unset; run scripts/screenshot.sh to capture")
        }
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)

        // The expected titles come out of the fixture rather than being restated here, so the
        // deck is defined in exactly one place and this cannot drift from it.
        let expected = try JSONDecoder().decode(
            Expected.self,
            from: Data(contentsOf: fixture.appendingPathComponent("expected.json"))
        )

        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
            "-FlightDeckFixture", fixture.path,
        ]
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")

        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(
            rows.element(boundBy: expected.visibleTitles.count - 1).waitForExistence(timeout: 20),
            "the fixture did not restore; expected \(expected.visibleTitles.count) visible rows"
        )

        // The deck has to have settled before the shutter, or the picture is of an app that
        // has not finished waking up. Polling the row titles is the cheapest proxy a UI test
        // has: rows only carry their fixture titles once `restore()` has run, and
        // `applyRegistry` lands on the same clock tick.
        let wanted = Set(expected.visibleTitles)
        let deadline = Date().addingTimeInterval(20)
        var seen = Set<String>()
        while Date() < deadline, seen != wanted {
            seen = Set((0..<rows.count).compactMap { rows.element(boundBy: $0).value as? String })
            if seen == wanted { break }
            usleep(250_000)
        }
        XCTAssertEqual(seen, wanted, "sidebar never settled on the posed deck")

        // Has to outlast the fixture's own two delays: the shell's 1.5s before it paints, and
        // the nudge script's 2.5s before it drops the transcripts in — plus a watcher tick to
        // notice them and turn the busy row's spinner into a spinner-with-count.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { settled.fulfill() }
        wait(for: [settled], timeout: 10)

        // The window rather than the screen: crops to the app, so the image does not depend on
        // display size, window position, or what else is on the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "flight-deck"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
