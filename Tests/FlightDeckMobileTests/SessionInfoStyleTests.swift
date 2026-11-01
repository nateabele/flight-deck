import FleetKit
import XCTest
@testable import FlightDeckMobile

final class SessionInfoStyleTests: XCTestCase {
    func testTheSwitcherTypesTheCanonicalIdIntoTheTab() {
        XCTAssertEqual(SessionInfoStyle.switchCommand("6F9619FF-8B86-D011-B42D-00C04FC964FF"),
                       "/switch-account 6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }

    func testOnlyClaudeTabsOfferTheSwitcher() {
        XCTAssertTrue(SessionInfoStyle.canSwitch(agent: "claude"))
        XCTAssertFalse(SessionInfoStyle.canSwitch(agent: "codex"))
        XCTAssertFalse(SessionInfoStyle.canSwitch(agent: nil))
    }

    func testWindowsUseTheMacsShortLabels() {
        XCTAssertEqual(SessionInfoStyle.windowLabel("five_hour"), "5h")
        XCTAssertEqual(SessionInfoStyle.windowLabel("seven_day"), "wk")
        XCTAssertEqual(SessionInfoStyle.windowLabel("seven_day_opus"), "Opus wk")
        XCTAssertEqual(SessionInfoStyle.windowLabel("some_new_window"), "some new window")
        XCTAssertEqual(SessionInfoStyle.windowLabel("gemini-5h"), "5h")
        XCTAssertEqual(SessionInfoStyle.windowLabel("gemini-weekly"), "wk")
        XCTAssertEqual(SessionInfoStyle.windowLabel("rejected"), "Refused")
        XCTAssertEqual(SessionInfoStyle.windowLabel("retry-after"), "Retry")
        XCTAssertEqual(SessionInfoStyle.windowLabel("300m"), "5h")
        XCTAssertEqual(SessionInfoStyle.windowLabel("45m"), "45m")
        XCTAssertEqual(SessionInfoStyle.windowLabel("codex-limit:five_hour"), "5h")
    }

    func testResetTextIsRelativeWithinADayAndADayAndTimeBeyond() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SessionInfoStyle.resetText(now.addingTimeInterval(2 * 3600 + 14 * 60), now: now), "resets in 2h 14m")
        XCTAssertEqual(SessionInfoStyle.resetText(now.addingTimeInterval(59), now: now), "resets in 1m")
        XCTAssertEqual(SessionInfoStyle.resetText(now.addingTimeInterval(-5), now: now), "reset")
        XCTAssertNil(SessionInfoStyle.resetText(nil, now: now))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let text = SessionInfoStyle.resetText(now.addingTimeInterval(3 * 86_400), now: now, calendar: calendar,
                                              locale: Locale(identifier: "en_US_POSIX"))
        // The formatter puts a narrow no-break space before AM.
        XCTAssertEqual(text?.replacingOccurrences(of: "\u{202F}", with: " "), "resets Mon 8:00 AM")
    }

    func testContextNamesItsWindowSize() {
        let at = Date()
        XCTAssertEqual(SessionInfoStyle.contextText(WireContextUsage(usedPercent: 37.4, windowSize: 200_000, readAt: at)),
                       "37% used of 200K tokens")
        XCTAssertEqual(SessionInfoStyle.contextText(WireContextUsage(usedPercent: 5, windowSize: 1_000_000, readAt: at)),
                       "5% used of 1M tokens")
        XCTAssertEqual(SessionInfoStyle.contextText(WireContextUsage(usedPercent: 5, windowSize: nil, readAt: at)), "5% used")
    }

    func testAChoiceShowsEachWindowAndItsState() {
        let account = WireAccountChoice(
            id: "a", displayName: "Summer", email: nil, state: "overSoft", isCurrent: false,
            windows: [WireUsageWindow(name: "five_hour", utilization: 0.1, resetsAt: nil),
                      WireUsageWindow(name: "seven_day", utilization: 0.804, resetsAt: nil)])
        XCTAssertEqual(SessionInfoStyle.choiceDetail(account), "5h 10% · wk 80% · near limit")
        let unread = WireAccountChoice(id: "b", displayName: "Night", email: nil, state: "unknown", isCurrent: false)
        XCTAssertEqual(SessionInfoStyle.choiceDetail(unread), "no usage reading")
    }

    func testAnOlderMacIsToldToUpdate() {
        XCTAssertEqual(SessionInfoStyle.failureText(.server(code: "out_of_scope")),
                       "Update Flight Deck on your Mac to see accounts here.")
        XCTAssertEqual(SessionInfoStyle.failureText(.disconnected), "Not connected to your Mac.")
    }
}
