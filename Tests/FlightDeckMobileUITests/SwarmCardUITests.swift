import XCTest

/// The swarm card's Pause/Resume swap, on the simulator, with fixture data (spec §11 "Phone").
final class SwarmCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPauseSwapsToResume() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "swarmCard"]
        app.launch()
        let title = app.staticTexts["swarm-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "swarm 2/3 · 1 waiting")
        XCTAssertEqual(app.staticTexts["swarm-card-meter"].label, "claude-subs · Work · 62%")
        add(XCTAttachment(screenshot: app.screenshot()))
        app.buttons["swarm-card-pause"].tap()
        XCTAssertTrue(app.buttons["swarm-card-resume"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["swarm-card-title"].label, "swarm paused · 2/3")
        add(XCTAttachment(screenshot: app.screenshot()))
    }
}
