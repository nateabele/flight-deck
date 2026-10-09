import XCTest

extension XCTestCase {
    /// Closes macOS's "Flight Deck quit unexpectedly." dialog with Ignore, if one is up.
    ///
    /// The failure this prevents: when the app under test crashes, the crash reporter puts that
    /// dialog (a `com.apple.UserNotificationCenter` window, 260×300pt) at the top centre of the
    /// screen and leaves it there until someone answers it. On the UI-test Mac, 2026-10-09, a
    /// libghostty crash in one test left it over the main window and the Settings tab bar for
    /// every test after it. XCUITest flagged it as an unhandled interruption on each click near
    /// it, and nobody is at that Mac to close it, so every later run would have started covered.
    ///
    /// This answers only the crash report of the app under test. `clickUnlessCovered` refuses to
    /// click any other system or firewall alert, and that stays right: those are someone's
    /// decisions. Ignore here decides nothing. The crash report is already written to
    /// DiagnosticReports, and the test that crashed has already failed with its own message.
    /// Reopen would launch a second copy of the app, so it is never pressed.
    ///
    /// Call it before a launch. A screenshot of the dialog is attached first, so a run that
    /// started behind one says so.
    func dismissFlightDeckCrashReports() {
        let center = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        guard center.state == .runningForeground || center.state == .runningBackground else { return }
        let ours = NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
            "Flight Deck quit unexpectedly", "Flight Deck quit unexpectedly"
        )
        for dialog in center.dialogs.allElementsBoundByIndex where dialog.exists {
            guard dialog.staticTexts.matching(ours).firstMatch.exists else { continue }
            let ignore = dialog.buttons["Ignore"]
            guard ignore.exists else { continue }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "flight-deck-crash-report-dialog"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "closing a Flight Deck crash report left by an earlier test") {
                $0.add(attachment)
                ignore.click()
            }
        }
    }
}
