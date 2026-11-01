import AppKit
import XCTest

/// Ask threads through the real app (planning v2 P1, spec §14 "UI flows"): ✦ Ask on a selection
/// opens the panel on a new thread and sends; a thread's reply is read in the panel; ✓ on its diff
/// puts the proposed words into the plan.
///
/// The fixture is the app's own (`PlanningUIFixture`, `-FlightDeckPlanningFixture threads`): the
/// shaping plan with one thread that has already answered with a pending diff on the plan's
/// opening sentence. No ThreadRunner runs under it — a turn would run a real agent CLI here — so
/// the reply is the seeded one and the new Ask stays queued. The ✓ is real end to end: the app
/// appends `applyThreadDiff`, starts the round runner to fold it, and the editor shows the edit.
final class AskThreadUITests: XCTestCase {
    /// `PlanningUIFixture`'s seeded thread, repeated here: the UI-test bundle can't import the app.
    private static let threadTitle = "Is the opening sentence right?"
    private static let threadReply = "It undersells the fixture. I propose saying what the plan is for."
    private static let threadNew = "A synthetic plan that an ask thread has edited."

    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckPlanningFixture", "threads"]
        dismissFlightDeckCrashReports()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        XCTAssertTrue(editor(app).waitForExistence(timeout: 20), "the plan editor never appeared")
        XCUIElement.perform(withKeyModifiers: .option) { app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click() }
        pause(3)
        scrollToPlan(app)
        return app
    }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement { element(app, "plan-editor") }

    /// Static text only: a predicate over every element's value walks the plan editor's whole text
    /// and times the query out.
    private func text(_ app: XCUIApplication, containing words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "ask-thread-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func at(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Scrolls the detail pane until the plan is in the window: the board sits above it.
    private func scrollToPlan(_ app: XCUIApplication) {
        let detail = app.scrollViews["intake-detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "no detail pane")
        for _ in 0..<12 where editor(app).frame.minY > detail.frame.minY + 60 {
            detail.scroll(byDeltaX: 0, deltaY: -300)
            pause(0.3)
        }
        pause(1)
    }

    /// Selects a few words of plan: a click below the pinned board puts the caret in the plan, and
    /// ⇧⌥→ extends it by words, wherever the click landed (a drag that starts on a blank line
    /// between a heading and its list selects nothing).
    private func select(_ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        at(app, window.width * 0.5, window.height * 0.82).click()
        pause(0.3)
        for _ in 0..<4 { editor(app).typeKey(.rightArrow, modifierFlags: [.shift, .option]) }
        pause(0.5)
    }

    private func eventually(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(0.5)
        }
        return condition()
    }

    func testAskThenReadTheReplyThenAcceptItsDiff() {
        let app = launch()

        // ✦ Ask on a selection: the panel opens on a new thread, composer focused.
        select(app)
        let ask = element(app, "selection-toolbar-ask")
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "no ✦ Ask on the selection toolbar")
        shot(app, "selected")
        ask.click()
        let composer = element(app, "thread-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "✦ Ask opened no thread panel")
        composer.click()
        composer.typeText("Why this step, and not a smaller one?")
        composer.typeKey(.return, modifierFlags: .command)
        // Accepted: the composer empties (a refusal keeps the words and says why). The thread itself
        // appears once ThreadRunner folds its open, which this fixture never starts.
        // The new-thread composer goes away with the send; one that stays still holds the words.
        XCTAssertTrue(eventually(10) { !composer.exists || (composer.value as? String ?? "").isEmpty }, "the Ask was not sent")
        shot(app, "asked")

        // The seeded thread's reply, read in the panel. At the inspector's width the index is a page.
        let toggle = element(app, "thread-index-toggle")
        if toggle.waitForExistence(timeout: 2) { toggle.click() }
        let row = app.descendants(matching: .any).matching(identifier: "thread-index-row")
            .matching(NSPredicate(format: "label CONTAINS %@", Self.threadTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the answered thread is not in the index")
        row.click()
        XCTAssertTrue(text(app, containing: Self.threadReply).waitForExistence(timeout: 10), "the reply is not shown")
        shot(app, "reply")

        // ✓ on its diff: the proposed words become the plan's text once the runner folds the edit.
        let accept = element(app, "thread-diff-accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 5), "the diff has no ✓ in the conversation")
        accept.click()
        let landed = eventually(45) { (editor(app).value as? String)?.contains(Self.threadNew) == true }
        shot(app, "accepted")
        XCTAssertTrue(landed, "the accepted words never reached the plan's text")
    }
}
