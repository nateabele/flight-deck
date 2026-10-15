import AppKit
import XCTest

/// The plan's selection toolbar must work on a later version of the plan (reported 2026-10-15,
/// on the maintainer's LarkOS intake): after synthesis, selecting text showed the toolbar, but pressing
/// Comment, Question and the rest did nothing. Hosted-window tests pressed the toolbar's panel
/// with synthetic events and passed, so this drives the real app through the window server, with
/// the real mouse.
///
/// The fixture is the app's own (`PlanningUIFixture`, `-FlightDeckPlanningFixture synthesized`):
/// a draft, a synthesis that read notes written on it, and two refines, each a long plan of
/// paragraphs and tables, open on the latest version.
final class NotesToolbarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckPlanningFixture", "synthesized"]
        dismissFlightDeckCrashReports()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        XCTAssertTrue(editor(app).waitForExistence(timeout: 20), "the plan editor never appeared")
        // As big as the screen, as the plan is read: the board is pinned over the top of the pane,
        // and in the default window it leaves a few lines of plan.
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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "notes-toolbar-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A point in the window, in the window's own coordinates.
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

    /// Selects by dragging across part of one line near the foot of the window, below the pinned
    /// board, where the plan's text is once `scrollToPlan` has run.
    private func drag(_ app: XCUIApplication, down: CGFloat = 0, from: CGFloat = 0.5, length: CGFloat = 300) {
        let window = app.windows.firstMatch.frame
        let (x, y) = (window.width * from, window.height * 0.82 + down)
        at(app, x, y).press(forDuration: 0.1, thenDragTo: at(app, x + length, y))
    }

    private func toolbarButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    /// The rail's own "Add Note" is always there, so a draft card is a second one: its commit button.
    private func addNoteButtons(_ app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "label == 'Add Note'")).count
    }

    private func draftOpen(_ app: XCUIApplication, after baseline: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if addNoteButtons(app) > baseline { return true }
            pause(0.25)
        }
        return false
    }

    /// Select, wait for the toolbar, press `kind`, and a draft card must open.
    private func comment(_ app: XCUIApplication, _ moment: String, kind: String = "Comment",
                         select: () -> Void) {
        select()
        shot(app, "\(moment)-selected")
        let button = toolbarButton(app, kind)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(moment): no \(kind) button on the selection toolbar")
        shot(app, "\(moment)-toolbar")
        let baseline = addNoteButtons(app)
        button.click()
        let opened = draftOpen(app, after: baseline)
        shot(app, "\(moment)-after")
        XCTAssertTrue(opened, "\(moment): pressing \(kind) on the selection toolbar opened no draft in the rail")
    }

    private func cancelDraft(_ app: XCUIApplication) {
        app.buttons["Cancel"].firstMatch.click()
        pause(0.5)
    }

    /// Away to the session's terminal and back to the plan: the plan editor is built afresh and
    /// restores the reading position.
    private func switchTabAndBack(_ app: XCUIApplication) {
        let session = app.staticTexts.matching(identifier: "session-row-title").element(boundBy: 1)
        XCTAssertTrue(session.waitForExistence(timeout: 5), "no session row in the sidebar")
        session.click()
        pause(1)
        let header = app.staticTexts.matching(NSPredicate(format: "identifier == 'project-header' AND value CONTAINS 'planning-fixture'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "no project header in the sidebar: \(app.staticTexts.allElementsBoundByIndex.prefix(30).map { "\($0.identifier)=\($0.value ?? "")" })")
        header.click()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 10), "the plan editor did not come back")
        scrollToPlan(app)
    }

    // MARK: Scenarios

    func testCommentOnTheLatestVersion() throws {
        let app = launch()
        comment(app, "latest") { drag(app) }
    }

    func testCommentAfterSwitchingTabsAndBack() throws {
        let app = launch()
        switchTabAndBack(app)
        pause(3)
        comment(app, "after-restore") { drag(app) }
    }

    func testCommentRightAfterTheRestore() throws {
        let app = launch()
        switchTabAndBack(app)
        comment(app, "during-restore") { drag(app) }
    }

    /// Selects inside the first table's cells, which the editor draws as a grid over the text.
    func testCommentOnTextInATable() throws {
        let app = launch()
        comment(app, "table") { drag(app, down: -app.windows.firstMatch.frame.height * 0.2, from: 0.5, length: 120) }
    }

    /// After the round list: another version, then back to the latest.
    func testCommentAfterSwitchingVersionsInTheRoundList() throws {
        let app = launch()
        let card = { (n: Int) in app.buttons["round-card-\(n)"].firstMatch }
        XCTAssertTrue(card(1).waitForExistence(timeout: 5), "no round card in the board")
        let detail = app.scrollViews["intake-detail"].firstMatch
        for _ in 0..<6 { detail.scroll(byDeltaX: 0, deltaY: 600) }
        pause(1)
        card(2).click()
        pause(2)
        for _ in 0..<6 { detail.scroll(byDeltaX: 0, deltaY: 600) }
        card(4).click()
        pause(2)
        scrollToPlan(app)
        comment(app, "after-versions") { drag(app) }
    }

    /// Opens the inspector on `mode` ("1" Notes, "2" Rounds).
    private func inspector(_ app: XCUIApplication, mode: String) {
        let toggle = element(app, "intake-inspector-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no inspector toggle")
        toggle.click()
        pause(2.5)
        app.typeKey(mode, modifierFlags: [.command, .option])
        pause(1.5)
    }

    func testCommentWithTheInspectorOnNotes() throws {
        let app = launch()
        inspector(app, mode: "1")
        scrollToPlan(app)
        comment(app, "inspector-notes") { drag(app) }
    }

    /// The rail is not on screen in Rounds mode: press Comment, then look at Notes for the draft.
    func testCommentWithTheInspectorOnRounds() throws {
        let app = launch()
        inspector(app, mode: "2")
        scrollToPlan(app)
        drag(app)
        let button = toolbarButton(app, "Comment")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "inspector-rounds: no Comment button on the selection toolbar")
        app.typeKey("1", modifierFlags: [.command, .option])
        pause(1)
        let baseline = addNoteButtons(app)
        if button.exists { button.click() } else {
            // Switching modes took the selection, and with it the toolbar: select again on Notes.
            drag(app)
            let again = toolbarButton(app, "Comment")
            XCTAssertTrue(again.waitForExistence(timeout: 5), "no toolbar after switching to Notes")
            again.click()
        }
        XCTAssertTrue(draftOpen(app, after: baseline), "inspector-rounds: pressing Comment opened no draft")
    }
}
