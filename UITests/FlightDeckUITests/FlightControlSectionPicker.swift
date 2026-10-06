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
        segment.click()
    }
}
