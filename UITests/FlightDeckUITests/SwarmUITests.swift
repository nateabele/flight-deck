import AppKit
import XCTest

/// L3-S's UI suite (spec §11), against the fixture backend `scripts/test-ui-flight-control.sh`
/// builds: stub br/am over one state file, a stub agent drawing claude's composer box and closing
/// its task, deterministic routing. Skipped unless that script set the fixture paths, so
/// `scripts/smoke.sh` (which runs this whole bundle) never runs it.
///
/// Header text is read from the Swarm Details popover, never the header row: the row is one
/// combined accessibility element and XCUITest reads its label as "" (`TerminalSmokeTests`).
final class SwarmUITests: XCTestCase {
    private func environmentValue(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_\(name)"]
    }

    override func setUp() { continueAfterFailure = false }

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckFixture", fixture, "-FlightControlFixtureBackend", fixture,
                                "-FlightDeckDaemonDir", fixture + "/daemons"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "swarm-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func text(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }

    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "project-header").firstMatch
    }

    private func menu(_ app: XCUIApplication, _ item: String) {
        header(app).rightClick()
        let entry = app.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no \(item) in the project menu")
        entry.click()
    }

    private func popoverTexts(_ app: XCUIApplication) -> [String] {
        menu(app, "Swarm Details…")
        let popover = app.descendants(matching: .any).matching(identifier: "swarm-popover").firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no swarm popover")
        let texts = popover.staticTexts.allElementsBoundByIndex.map(text)
        app.typeKey(.escape, modifierFlags: [])
        return texts
    }

    private func chips(_ app: XCUIApplication) -> [String] {
        app.staticTexts.matching(identifier: "swarm-task-chip").allElementsBoundByIndex.map(text)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    func testLaunchReuseContestedPauseResumeAndRestart() throws {
        guard let fixture = environmentValue("FLIGHT_CONTROL_FIXTURE") else {
            throw XCTSkip("run scripts/test-ui-flight-control.sh")
        }
        var app = launch(fixture)
        XCTAssertTrue(header(app).waitForExistence(timeout: 20))

        // Launch from the sheet with a cap of 2.
        menu(app, "Run Ready Tasks…")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "swarm-launch-sheet").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["launch-row-fx-a"].waitForExistence(timeout: 10))
        shot(app, "1-launch-sheet")
        app.steppers["launch-cap"].decrementArrows.firstMatch.click()
        app.buttons["launch-swarm"].click()

        // Two agents start, each with its task chip; the header says 2/2.
        XCTAssertTrue(waitUntil(60) { chips(app).count >= 2 }, "chips: \(chips(app))")
        XCTAssertTrue(chips(app).contains { $0.hasPrefix("fx-a") })
        shot(app, "2-rows")
        XCTAssertTrue(popoverTexts(app).contains { $0.hasPrefix("swarm 2/2") })

        // fx-a closes; its agent is reused (same config) for fx-c.
        XCTAssertTrue(waitUntil(90) { chips(app).contains { $0.hasPrefix("fx-c") } }, "chips: \(chips(app))")
        shot(app, "3-reuse")

        // fx-b's agent hit the guard: the row is contested and the drawer names the holder.
        XCTAssertTrue(app.images["swarm-contested"].waitForExistence(timeout: 60), "no contested badge")
        app.staticTexts.matching(identifier: "swarm-task-chip")
            .matching(NSPredicate(format: "value BEGINSWITH 'fx-b' OR label BEGINSWITH 'fx-b'")).firstMatch.click()
        let lane = app.descendants(matching: .any)["observe-lane-assignment"]
        XCTAssertTrue(lane.waitForExistence(timeout: 20), "no Assignment lane")
        XCTAssertTrue(waitUntil(20) { lane.staticTexts.allElementsBoundByIndex.contains { text($0).contains("held by") } })
        shot(app, "4-contested")

        // Pause and resume from the header.
        menu(app, "Pause Swarm")
        XCTAssertTrue(popoverTexts(app).contains { $0.hasPrefix("swarm paused") })
        shot(app, "5-paused")
        menu(app, "Resume Swarm")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(popoverTexts(app).contains { $0.hasPrefix("swarm paused") })

        // Relaunch: the swarm comes back paused, with the banner.
        app.terminate()
        app = launch(fixture)
        XCTAssertTrue(header(app).waitForExistence(timeout: 20))
        XCTAssertTrue(popoverTexts(app).contains("Swarm paused after restart · Resume"))
        shot(app, "6-restart-banner")
    }

    func testHandOffMarkerFromASeededSwarm() throws {
        guard let fixture = environmentValue("FLIGHT_CONTROL_SEEDED") else {
            throw XCTSkip("run scripts/test-ui-flight-control.sh")
        }
        let app = launch(fixture)
        let markers = app.staticTexts.matching(identifier: "swarm-marker")
        XCTAssertTrue(waitUntil(20) { markers.allElementsBoundByIndex.contains { text($0) == "handed off →" } })
        XCTAssertTrue(waitUntil(20) { chips(app).contains("fx-a · tests") })
        shot(app, "handed-off")
    }
}
