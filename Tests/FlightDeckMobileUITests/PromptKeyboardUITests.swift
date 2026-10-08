import XCTest

/// The prompt card against the keyboard, on the simulator: no gap between the card and the
/// keyboard while its own field is typed into, and all of the card still on screen after
/// paging to a taller question with the keyboard up. Measured from element frames, and the
/// screens are attached so a failure can be looked at.
final class PromptKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testTheCardSitsOnTheKeyboardAndStaysOnScreenAsItPages() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "promptKeyboard"]
        app.launch()

        let field = app.textFields["prompt-typed-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        attach(app, "1-before")
        field.tap()
        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5),
                      "no software keyboard — the simulator has a hardware keyboard attached")
        sleep(1)
        attach(app, "2-typing")
        let card = app.otherElements["prompt-card"]
        // XCUITest's keyboard frame starts BELOW the 44pt suggestion bar the keyboard draws on
        // top of itself (on the iPhone 16-class simulator: frame 583, drawn edge 539). Measured
        // from the card's last control, whose 12pt card padding plus 6pt margin sit below it.
        let gap = keyboardTop(keyboard) - app.buttons["Next"].frame.maxY
        print("PROMPTKB typing card=\(card.frame) keyboard=\(keyboard.frame) gap=\(gap)")
        XCTAssertLessThanOrEqual(gap, 24, "the card floats \(gap)pt above the keyboard")

        field.typeText("teal")
        app.buttons["Next"].tap()
        sleep(1)
        attach(app, "3-next")
        let navBottom = app.navigationBars.element.frame.maxY
        let visibleBottom = keyboard.exists ? keyboard.frame.minY : app.frame.maxY
        print("PROMPTKB next card=\(card.frame) navBottom=\(navBottom) keyboard=\(keyboard.exists ? keyboard.frame : .zero)")
        XCTAssertGreaterThanOrEqual(card.frame.minY, navBottom, "the card's top is under the navigation bar")
        XCTAssertLessThanOrEqual(card.frame.maxY, visibleBottom + 1, "the card's bottom is under the keyboard")
        XCTAssertFalse(keyboard.exists, "paging puts the keyboard away")

        // The worst case: the tall question, with the keyboard brought back up over it.
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        sleep(1)
        attach(app, "4-tall-typing")
        print("PROMPTKB tall card=\(card.frame) navBottom=\(navBottom) keyboard=\(keyboard.frame)")
        XCTAssertGreaterThanOrEqual(card.frame.minY, navBottom - 1, "the tall card's top is under the navigation bar")
        let send = app.buttons["Send answers"]
        print("PROMPTKB tall field=\(field.frame) send=\(send.frame)")
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboardTop(keyboard), "Send answers is under the keyboard")
        XCTAssertGreaterThanOrEqual(keyboardTop(keyboard) - send.frame.maxY, 0)
        XCTAssertLessThanOrEqual(keyboardTop(keyboard) - send.frame.maxY, 24, "the tall card floats above the keyboard")
        XCTAssertGreaterThanOrEqual(field.frame.minY, navBottom, "the field is under the navigation bar")
    }

    /// The message box is gone while the question is expanded, back when the card is
    /// minimized — which shrinks the card to its title — and gone again on expand.
    func testMinimizingAQuestionGivesTheMessageBoxBack() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "promptKeyboard"]
        app.launch()
        let card = app.otherElements["prompt-card"]
        let composer = app.descendants(matching: .any)["composer-field"]
        let toggle = app.buttons["prompt-minimize"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertFalse(composer.exists, "an expanded question hides the message box")
        let expandedHeight = card.frame.height
        attach(app, "5-expanded")

        toggle.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "minimized, the message box is back")
        sleep(1)
        XCTAssertGreaterThan(app.buttons["Dismiss"].frame.minX, card.frame.maxX - 60,
                             "minimized, the × stays in the card's corner")
        XCTAssertFalse(app.buttons["Next"].exists, "minimized, the options and buttons are gone")
        XCTAssertLessThan(card.frame.height, expandedHeight / 2)
        XCTAssertEqual(toggle.label, "Expand")
        attach(app, "6-minimized")

        toggle.tap()
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
        XCTAssertFalse(composer.exists, "expanded again, the message box goes again")
    }

    /// A lone question shows its heading once, at the card's left edge, and the minimize
    /// button beside the title line below it rather than beside the heading.
    func testALoneQuestionShowsItsHeadingOnceWithTheButtonOnTheTitleLine() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "promptKeyboard", "-UITestSingle", "YES"]
        app.launch()
        let card = app.otherElements["prompt-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        attach(app, "7-single")
        XCTAssertEqual(app.staticTexts.matching(identifier: "COLOR").count, 1, "heading shown once")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Which color do you like best?").count, 1,
                       "title shown once")
        let heading = app.staticTexts["COLOR"]
        let title = app.staticTexts["Which color do you like best?"]
        let toggle = app.buttons["prompt-minimize"]
        XCTAssertLessThan(heading.frame.minX, toggle.frame.minX, "the heading keeps the left edge")
        XCTAssertGreaterThan(toggle.frame.minY, heading.frame.maxY - 2, "the button is below the heading")
        XCTAssertGreaterThan(title.frame.minX, toggle.frame.maxX, "the title sits after the button")
    }

    /// The keyboard's drawn top edge, suggestion bar included — see the first measurement.
    private func keyboardTop(_ keyboard: XCUIElement) -> CGFloat { keyboard.frame.minY - 44 }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath:
            "/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/8a334862-0e05-4951-b162-f08508f22e45/scratchpad/kb-\(name).png"))
    }
}
