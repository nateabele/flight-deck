import XCTest

/// A menu shortcut works on its first press after a tab switch. ⌘N is an AppKit item inside
/// SwiftUI's File menu (`AppKitMenuSlot`), and SwiftUI rebuilt File during the key-equivalent
/// search that follows a tab switch, so the first press missed and beeped and the second worked:
/// 6 of 6 presses right after a row click missed on the UI-test Mac (2026-10-15). It must press
/// at once — after a pause SwiftUI has rebuilt and the slot has healed, and the press lands.
/// ⇧⌘] switches are kept as a contrast: they never missed.
final class FirstPressUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        dismissFlightDeckCrashReports()
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    func testCommandNWorksOnTheFirstPressAfterEachTabSwitch() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")
        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(waitFor(timeout: 10) { rows.count == 1 }, "seeded slate should hold one session")

        var misses: [String] = []
        func pressCommandN(_ label: String) {
            let before = rows.count
            app.typeKey("n", modifierFlags: .command)
            if !waitFor(timeout: 4, { rows.count == before + 1 }) {
                misses.append(label)
                // The second press, so the rest of the walk starts from the expected count.
                app.typeKey("n", modifierFlags: .command)
                _ = waitFor(timeout: 4) { rows.count == before + 1 }
            }
        }

        pressCommandN("launch")
        for i in 0..<6 {
            rows.element(boundBy: i % 2).click()
            pressCommandN("after clicking row \(i % 2) (round \(i))")
        }
        for i in 0..<4 {
            app.typeKey("]", modifierFlags: [.command, .shift])
            pressCommandN("after ⇧⌘] (round \(i))")
        }
        XCTAssertEqual(misses, [], "⌘N missed its first press: \(misses)")
    }
}
