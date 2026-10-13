import AppKit
import XCTest

/// Opening the planning inspector must leave every column of the window drawn and the plan
/// starting at its top. Reported 2026-10-11 on a Release built from `118e6db0`: with the
/// inspector open the session sidebar, the Intakes list and the inspector were empty dark panes
/// and the plan could not be scrolled to its top; closing the inspector brought them back.
///
/// A real window, key and frontmost, with its toolbar: an offscreen hosted `RootView` never
/// showed it (`ProjectViewInspectorLiveTests`), so the window frame is part of what this pins.
///
/// The fixture is the app's own (`PlanningUIFixture`, `-FlightDeckPlanningFixture shaping`):
/// a reset run with one Flight Control project whose shaping plan is on screen.
///
/// Accessibility frames alone cannot see "blank": a column whose layer is not drawn still
/// reports its rows. So each column is also checked for ink in the window's own screenshot.
final class PlanningInspectorUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckPlanningFixture", "shaping"]
        dismissFlightDeckCrashReports()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) -> XCUIScreenshot {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "planning-inspector-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    /// The share of pixels in `rect` (screen points) that differ from the rect's most common
    /// colour: about 0 for an empty pane, a few percent for a column of text rows.
    private func ink(in rect: CGRect, of screenshot: XCUIScreenshot, window: CGRect) -> Double {
        guard let cg = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              window.width > 0 else { return 0 }
        let scale = CGFloat(cg.width) / window.width
        let local = rect.intersection(window).offsetBy(dx: -window.minX, dy: -window.minY)
        let crop = CGRect(x: local.minX * scale, y: local.minY * scale,
                          width: local.width * scale, height: local.height * scale).integral
        guard let part = cg.cropping(to: crop) else { return 0 }
        let rep = NSBitmapImageRep(cgImage: part)
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Quantised, so a gradient or vibrancy does not count as ink.
                let key = (UInt32(c.redComponent * 31) << 10) | (UInt32(c.greenComponent * 31) << 5) | UInt32(c.blueComponent * 31)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        guard total > 0, let top = counts.values.max() else { return 0 }
        return Double(total - top) / Double(total)
    }

    /// Every column the report saw blank, checked by hit-testing and by ink.
    private func assertEveryColumnDrawn(_ app: XCUIApplication, _ screenshot: XCUIScreenshot, _ moment: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let sessionRow = element(app, "session-row-title")
        let intakeRow = element(app, "intake-row")
        let eyebrow = element(app, "intake-state-eyebrow")
        XCTAssertTrue(sessionRow.isHittable, "\(moment): the sidebar's session row is not on screen", file: file, line: line)
        XCTAssertTrue(intakeRow.isHittable, "\(moment): the Intakes list's row is not on screen", file: file, line: line)
        // The document's first line: the plan view opens at its top, so this is visible unless
        // the content was laid out taller than the window and pushed up under the toolbar.
        XCTAssertTrue(eyebrow.isHittable, "\(moment): the plan document's top is not on screen", file: file, line: line)
        XCTAssertGreaterThanOrEqual(eyebrow.frame.minY, window.minY, "\(moment): the document starts above the window",
                                    file: file, line: line)

        let sidebar = CGRect(x: window.minX, y: sessionRow.frame.minY - 40,
                             width: sessionRow.frame.maxX - window.minX, height: 120)
        let intakes = CGRect(x: intakeRow.frame.minX, y: intakeRow.frame.minY - 60,
                             width: intakeRow.frame.width, height: intakeRow.frame.height + 80)
        let sidebarInk = ink(in: sidebar, of: screenshot, window: window)
        let intakesInk = ink(in: intakes, of: screenshot, window: window)
        XCTAssertGreaterThan(sidebarInk, 0.01, "\(moment): the session sidebar is blank (ink \(sidebarInk))", file: file, line: line)
        XCTAssertGreaterThan(intakesInk, 0.01, "\(moment): the Intakes list is blank (ink \(intakesInk))", file: file, line: line)
    }

    func testOpeningTheInspectorKeepsEveryColumnDrawn() throws {
        let app = launch()
        let detail = element(app, "intake-detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 20), "the fixture plan never opened")
        let eyebrow = element(app, "intake-state-eyebrow")
        XCTAssertTrue(eyebrow.waitForExistence(timeout: 10), "the plan's header never appeared")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        assertEveryColumnDrawn(app, shot(app, "1-closed"), "before opening")

        let toggle = element(app, "intake-inspector-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no inspector toggle in the toolbar")
        toggle.click()
        // By its segment: the column's own `intake-inspector` identifier is what the segmented
        // control's radio group reports, not `inspector-mode-picker`.
        let picker = app.radioButtons["Notes Inspector"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the inspector's Notes|Rounds control never appeared")
        // Past the column's open animation (`IntakeDetailView.openSettle`).
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let open = shot(app, "2-open")
        XCTAssertTrue(picker.isHittable, "the inspector's Notes|Rounds control is not on screen")
        assertEveryColumnDrawn(app, open, "with the inspector open")

        // Both modes: the report did not say which one was showing.
        app.typeKey("1", modifierFlags: [.command, .option])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        assertEveryColumnDrawn(app, shot(app, "3-notes"), "on Notes")
        app.typeKey("2", modifierFlags: [.command, .option])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        assertEveryColumnDrawn(app, shot(app, "4-rounds"), "on Rounds")

        toggle.click()
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        assertEveryColumnDrawn(app, shot(app, "5-closed-again"), "after closing")
    }

    private func waitGone(_ e: XCUIElement, _ message: String, timeout: TimeInterval = 10,
                          file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, message, file: file, line: line)
    }

    /// Archive / Unarchive / Move to Trash on the Intakes list (2026-10-12): from the row's context
    /// menu and from the list's own shortcuts — ⌃⌘A (Mail's Archive) and ⌘⌫ (Finder's Move to
    /// Trash), live only while the list has focus. The fixture plan is paused, so Archive acts at
    /// once; Move to Trash always confirms.
    func testArchiveUnarchiveAndTrashAPlan() throws {
        let app = launch()
        let row = element(app, "intake-row")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the fixture plan's row never appeared")
        // The row combines its children into one element, so the badge is read off the row's
        // value; and the outer `project-view` identifier overrides the checkbox's own, so the
        // checkbox is found by its title.
        let badge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'intake-row' AND value CONTAINS 'Archived'")).firstMatch
        let showArchived = app.checkBoxes["Show Archived"].firstMatch
        XCTAssertTrue(showArchived.waitForExistence(timeout: 5), "no Show Archived control under the list")

        // Context menu → Archive: the plan leaves the list.
        row.rightClick()
        let archiveItem = app.menuItems["Archive"].firstMatch
        XCTAssertTrue(archiveItem.waitForExistence(timeout: 5), "no Archive in the row's context menu")
        archiveItem.click()
        waitGone(row, "the archived plan is still listed")

        // Show Archived → it is back, dimmed and badged; Unarchive from its menu.
        showArchived.click()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Show Archived did not bring the plan back")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "the archived plan has no Archived badge")
        row.rightClick()
        let unarchiveItem = app.menuItems["Unarchive"].firstMatch
        XCTAssertTrue(unarchiveItem.waitForExistence(timeout: 5), "no Unarchive on an archived plan")
        unarchiveItem.click()
        waitGone(badge, "Unarchive left the Archived badge")
        showArchived.click()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the unarchived plan is not listed")

        // ⌃⌘A with the list focused archives the selected plan.
        row.click()
        app.typeKey("a", modifierFlags: [.control, .command])
        waitGone(row, "⌃⌘A did not archive the selected plan")

        // Back via Show Archived, ⌃⌘A again unarchives, then ⌘⌫ → confirm → gone for good.
        showArchived.click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        app.typeKey("a", modifierFlags: [.control, .command])
        waitGone(badge, "⌃⌘A on an archived plan did not unarchive it")
        row.click()
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
        let trash = app.buttons["Move to Trash"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "⌘⌫ did not ask to move the plan to the Trash")
        trash.click()
        waitGone(row, "the trashed plan is still listed, with Show Archived on")
    }

    /// The composer's expanded mode (2026-10-13): the corner arrow moves the draft from the list's
    /// foot to the main view and back, as the same text, with one live editor at a time.
    func testTheComposerExpandsAndCollapsesWithItsDraft() throws {
        let app = launch()
        let field = element(app, "intake-intent-field")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the list's composer never appeared")
        field.click()
        field.typeText("Add a dark mode")
        XCTAssertEqual(field.value as? String, "Add a dark mode")

        element(app, "intake-composer-expand").click()
        let expanded = element(app, "intake-intent-expanded-field")
        XCTAssertTrue(expanded.waitForExistence(timeout: 5), "the expanded editor never appeared")
        XCTAssertEqual(expanded.value as? String, "Add a dark mode", "expanding lost the draft")
        XCTAssertFalse(field.exists, "two editors are live on one draft")
        XCTAssertTrue(element(app, "intake-composer-placeholder").exists, "the list shows no placeholder while expanded")

        expanded.click()
        expanded.typeText(" and a light one")
        element(app, "intake-composer-collapse").click()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the list's composer did not come back")
        XCTAssertEqual(field.value as? String, "Add a dark mode and a light one", "collapsing lost the typed text")
        XCTAssertFalse(expanded.exists, "the expanded editor is still on screen")
    }
}
