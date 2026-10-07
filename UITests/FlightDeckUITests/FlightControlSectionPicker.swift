import XCTest

/// Settings → Flight Control's sections are a native segmented control. Its segments are not
/// separate views, so they cannot carry accessibility identifiers the way the old section buttons
/// did; XCUITest sees the control (identifier `fc-section-picker`) and its segments by title.
/// Every UI test selects a section through here, by the identifier it always used, so a renamed
/// segment fails in one place (and `FlightControlTabTests` pins the titles headlessly).
extension XCUIElement {
    private static let flightControlSectionTitles = [
        "fc-section-routing": "Routing",
        "fc-section-kinds": "Task Kinds",
        "fc-section-index": "Capability Index",
        "fc-section-capacity": "Capacity",
    ]

    /// The section control itself, for waiting on the tab to open.
    var flightControlSectionPicker: XCUIElement {
        descendants(matching: .any).matching(identifier: "fc-section-picker").firstMatch
    }

    /// Apps that float a window over every other app without taking part in the test. XCUITest
    /// clicks by screen point, so a click under one of these lands in THAT window.
    ///
    /// The failure this names: on the UI-test Mac a Little Snitch connection alert ("Flight Deck
    /// wants to connect to api.anthropic.com", left up for a process that had already exited)
    /// sat over the Settings toolbar. Every click on the Flight Control tab hit the alert, the
    /// window stayed on Agents, and all six RoutingUITests plus Capacity failed with "the Flight
    /// Control tab did not open" — which read as an app regression for two merges. Worse, a
    /// click that lands on such an alert can answer it: a test must never press Allow or Deny on
    /// someone's firewall. So a covered element is reported and NOT clicked.
    private static let overlayAgents = [
        "at.obdev.littlesnitch.agent",      // Little Snitch connection alerts
        "com.apple.UserNotificationCenter", // system alerts
        "com.apple.SecurityAgent",          // authorization prompts
    ]

    /// Every overlay-agent window over this element's frame, described for a failure message.
    var windowsCoveringIt: [String] {
        let target = frame
        return Self.overlayAgents.flatMap { bundle -> [String] in
            let agent = XCUIApplication(bundleIdentifier: bundle)
            guard agent.state == .runningForeground || agent.state == .runningBackground else { return [] }
            return agent.windows.allElementsBoundByIndex
                .filter { $0.exists && $0.frame.intersects(target) }
                .map { "\(bundle) window \"\($0.title)\" at \($0.frame)" }
        }
    }

    /// Clicks this element unless another app's window covers it, in which case the test fails
    /// naming that window, with a screenshot of the whole screen (the window screenshot XCUITest
    /// takes of the app under test leaves the overlay out). See `overlayAgents`.
    @discardableResult
    func clickUnlessCovered(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let covering = windowsCoveringIt
        guard covering.isEmpty else {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "covered-\(what)"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "screen with \(what) covered") { $0.add(attachment) }
            XCTFail("\(what) is covered by another app's window, so a click would land there instead: "
                    + covering.joined(separator: "; ") + ". Dismiss it on the UI-test Mac and re-run.",
                    file: file, line: line)
            return false
        }
        click()
        return true
    }

    /// Settings → the Flight Control tab, from the Settings window (`self`), waiting for its
    /// section control. Every Flight Control UI class opens the tab through here.
    @discardableResult
    func openFlightControlTab(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let tab = buttons["Flight Control"]
        guard tab.waitForExistence(timeout: 5) else {
            XCTFail("Settings has no Flight Control tab", file: file, line: line)
            return false
        }
        guard tab.clickUnlessCovered("the Flight Control tab", file: file, line: line) else { return false }
        let opened = flightControlSectionPicker.waitForExistence(timeout: 5)
        XCTAssertTrue(opened, "the Flight Control tab did not open", file: file, line: line)
        return opened
    }

    func selectFlightControlSection(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let title = Self.flightControlSectionTitles[identifier] else {
            return XCTFail("unknown Flight Control section \(identifier)", file: file, line: line)
        }
        let picker = flightControlSectionPicker
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the Flight Control section control never appeared", file: file, line: line)
        // A macOS segmented control exposes its segments as radio buttons; the button and
        // any-type fallbacks cover an OS that reports them otherwise, so a release that changes
        // the role does not fail every Flight Control test at once.
        let candidates = [picker.radioButtons[title], picker.buttons[title],
                          picker.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", title, title)).firstMatch]
        guard let segment = candidates.first(where: { $0.exists }) else {
            let attachment = XCTAttachment(string: picker.debugDescription)
            attachment.name = "fc-section-picker-tree"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "section picker tree") { $0.add(attachment) }
            return XCTFail("no \"\(title)\" segment in the Flight Control section control", file: file, line: line)
        }
        segment.clickUnlessCovered("the \"\(title)\" section", file: file, line: line)
    }
}
