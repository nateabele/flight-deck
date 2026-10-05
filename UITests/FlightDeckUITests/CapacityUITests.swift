import XCTest

/// Flight Control's capacity surfaces in the real app, against fixture readings, with a
/// screenshot at each state (L3-U §8). The pool popover and the row meter are drawn in the
/// DEBUG "Meter Gallery" window because L3-S mounts them in the header and the row only at
/// integration; the Capacity pane is the real Settings tab.
///
/// Skipped unless `scripts/test-ui-capacity.sh` asks for it: a UI test takes the foreground, so
/// it never runs inside the smoke gate.
final class CapacityUITests: XCTestCase {
    private func environmentValue(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_\(name)"]
    }

    private func shoot(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// SwiftUI `Text` on macOS exposes its string as the element's `value` with an empty `label`,
    /// so a subscript lookup by label never matches; accept either.
    private func text(_ string: String, in window: XCUIElement) -> XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }

    private func bar(_ label: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "meter-bar")
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testMetersAndCapacityPane() throws {
        guard environmentValue("FLIGHTDECK_CAPACITY_UI") == "1" else {
            throw XCTSkip("FLIGHTDECK_CAPACITY_UI unset; run scripts/test-ui-capacity.sh")
        }
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
            "-FlightControlUsageFixture", "YES",
            "-FlightControlMeterGallery", "YES",
        ]
        app.launch()
        app.activate()

        XCTContext.runActivity(named: "the pool popover draws one bar per account, with its state") { _ in
            let gallery = app.windows["Meter Gallery"]
            XCTAssertTrue(gallery.waitForExistence(timeout: 20), "the gallery window did not open")
            XCTAssertTrue(bar("Work", in: gallery).waitForExistence(timeout: 10))
            XCTAssertTrue((bar("Work", in: gallery).value as? String ?? "").contains("82 percent used, past its soft limit"))
            XCTAssertEqual(bar("Spare", in: gallery).value as? String, "no reading")
            XCTAssertTrue((bar("Codex", in: gallery).value as? String ?? "").contains("past its hard limit"))
            shoot(gallery, "pool-popover")
        }

        XCTContext.runActivity(named: "the row meter appears only past soft") { _ in
            let gallery = app.windows["Meter Gallery"]
            let meters = gallery.descendants(matching: .any).matching(identifier: "row-mini-meter")
            XCTAssertEqual(meters.count, 1, "the Codex row is past hard; the Spare row is unknown and draws nothing")
            shoot(gallery, "row-meter")
        }

        XCTContext.runActivity(named: "Settings → Capacity lists the default pools and takes edits") { _ in
            app.typeKey(",", modifierFlags: .command)
            // No identifier on the tab itself (a container identifier would shadow its children),
            // so find the window by the tab button's "Capacity" title, as the smoke tests do for "Agents".
            let prefs = app.windows.containing(.button, identifier: "Capacity").firstMatch
            XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Settings did not open with a Capacity tab")
            prefs.buttons["Capacity"].click()
            XCTAssertTrue(prefs.descendants(matching: .any).matching(identifier: "capacity-pool-list").firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(text("Claude default", in: prefs).exists)
            XCTAssertTrue(text("Codex default", in: prefs).exists)
            XCTAssertTrue(bar("Work", in: prefs).exists, "the pane embeds the same bar the popover draws")
            shoot(prefs, "capacity-pane")

            let confirm = prefs.checkBoxes["capacity-confirm-handoffs"]
            XCTAssertEqual(confirm.value as? Int, 0, "Confirm hand-offs defaults off")
            confirm.click()
            XCTAssertEqual(confirm.value as? Int, 1)

            prefs.descendants(matching: .any).matching(identifier: "capacity-add-pool").firstMatch.click()
            app.menuItems["Claude pool"].click()
            XCTAssertTrue(text("New Claude pool", in: prefs).waitForExistence(timeout: 5))
            shoot(prefs, "capacity-pane-edited")
        }
    }
}
