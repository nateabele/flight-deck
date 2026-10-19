import XCTest

/// The message box on the real conversation screen while a question arrives, changes and
/// leaves — driven from `UITestHarness.promptArrival`'s toolbar, the way the Mac's status
/// reaches the phone after the screen is open.
final class PromptArrivalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testTheMessageBoxIsHiddenWhileAQuestionIsUp() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "promptArrival"]
        app.launch()
        let card = app.otherElements["prompt-card"]
        let composer = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "nothing open, the message box is there")

        app.buttons["Ask A"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        sleep(1)
        attach(app, "arrive-A")
        XCTAssertFalse(composer.exists, "a question arrives: the message box goes")

        app.buttons["Ask B"].tap()
        XCTAssertTrue(app.staticTexts["Which one, for Second?"].waitForExistence(timeout: 5))
        sleep(1)
        attach(app, "A-to-B")
        XCTAssertFalse(composer.exists, "the next question replaces it: still gone")

        app.buttons["Permit"].tap()
        sleep(1)
        XCTAssertTrue(composer.exists, "a permission dialog leaves the message box")

        app.buttons["Ask A"].tap()
        sleep(1)
        attach(app, "P-to-A")
        XCTAssertFalse(composer.exists, "permission to question: gone")

        app.buttons["Clear"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "answered: the message box is back")

        app.buttons["Ask B"].tap()
        sleep(1)
        attach(app, "clear-to-B")
        XCTAssertFalse(composer.exists, "a second question arrives: gone again")
    }

    /// Minimizing a question does not bring the message box back, and a new question after a
    /// minimized one opens expanded.
    func testAMinimizedQuestionKeepsTheMessageBoxHidden() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "promptArrival"]
        app.launch()
        let composer = app.descendants(matching: .any)["composer-field"]
        let toggle = app.buttons["prompt-minimize"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        app.buttons["Ask A"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        toggle.tap()
        sleep(1)
        attach(app, "minimized")
        XCTAssertEqual(toggle.label, "Expand")
        XCTAssertFalse(composer.exists, "minimized: still gone")

        app.buttons["Ask B"].tap()
        XCTAssertTrue(app.staticTexts["Which one, for Second?"].waitForExistence(timeout: 5),
                      "the next question opens expanded")
        XCTAssertFalse(composer.exists)

        app.buttons["Clear"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "answered: the message box is back")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
