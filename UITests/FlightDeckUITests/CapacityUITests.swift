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
            .matching(NSPredicate(format: "value BEGINSWITH %@", "\(label):")).firstMatch
    }

    /// The bar's whole string ("Work: 82 percent used, ..."), read only after the element is
    /// confirmed to exist so a missing bar is an assertion failure, not an aborted snapshot.
    private func barValue(_ label: String, in window: XCUIElement, tree: String) -> String {
        guard bar(label, in: window).waitForExistence(timeout: 10) else {
            attachTree(window, tree)
            XCTFail("no meter-bar whose value begins \"\(label):\" in \(tree)")
            return ""
        }
        return bar(label, in: window).value as? String ?? ""
    }

    /// The accessibility tree as text, so a failed lookup says what was actually exposed.
    private func attachTree(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(string: window.exists ? window.debugDescription : "window does not exist")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        continueAfterFailure = true
        dismissFlightDeckCrashReports()
        app.launch()
        app.activate()

        XCTContext.runActivity(named: "the pool popover draws one bar per account, with its state") { _ in
            let gallery = app.windows["Meter Gallery"]
            guard gallery.waitForExistence(timeout: 20) else {
                attachTree(app.windows.firstMatch, "gallery-tree")
                XCTFail("the gallery window did not open")
                return
            }
            let work = barValue("Work", in: gallery, tree: "gallery-tree")
            XCTAssertTrue(work.contains("82 percent used, past its soft limit"), work)
            XCTAssertEqual(barValue("Spare", in: gallery, tree: "gallery-tree"), "Spare: no reading")
            let codex = barValue("Codex", in: gallery, tree: "gallery-tree")
            XCTAssertTrue(codex.contains("past its hard limit"), codex)
            shoot(gallery, "pool-popover")
        }

        XCTContext.runActivity(named: "the row meter appears only past soft") { _ in
            let gallery = app.windows["Meter Gallery"]
            let meters = gallery.descendants(matching: .any).matching(identifier: "row-mini-meter")
            XCTAssertEqual(meters.count, 1, "the Codex row is past hard; the Spare row is unknown and draws nothing")
            shoot(gallery, "row-meter")
        }

        XCTContext.runActivity(named: "Settings → Capacity meters the default pools; pools are added in Accounts") { _ in
            app.typeKey(",", modifierFlags: .command)
            // No identifier on the tab itself (a container identifier would shadow its children),
            // so find the window by the "Agents" tab button, as the smoke tests do for "Agents".
            let prefs = app.windows.containing(.button, identifier: "Agents").firstMatch
            guard prefs.waitForExistence(timeout: 10) else {
                attachTree(app.windows.firstMatch, "settings-tree")
                XCTFail("Settings did not open")
                return
            }
            prefs.openFlightControlTab()
            prefs.selectFlightControlSection("fc-section-capacity")
            XCTAssertTrue(prefs.descendants(matching: .any).matching(identifier: "capacity-pool-meters").firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(text("Claude default", in: prefs).exists)
            XCTAssertTrue(text("Codex default", in: prefs).exists)
            if !bar("Work", in: prefs).waitForExistence(timeout: 5) { attachTree(prefs, "settings-tree") }
            XCTAssertTrue(bar("Work", in: prefs).exists, "the pane embeds the same bar the popover draws")
            shoot(prefs, "capacity-pane")

            // Disabled until a confirm surface exists: nothing can answer a confirmation, so
            // turning it on would park every over-limit agent on its exhausted account.
            let confirm = prefs.checkBoxes["capacity-confirm-handoffs"]
            XCTAssertEqual(confirm.value as? Int, 0, "Confirm hand-offs defaults off")
            XCTAssertFalse(confirm.isEnabled, "Confirm hand-offs cannot be turned on yet")
            XCTAssertTrue(prefs.descendants(matching: .any).matching(identifier: "capacity-confirm-unavailable").firstMatch.exists)

            // Pool editing moved to Settings → Accounts (unify brief R7); Capacity points there.
            prefs.descendants(matching: .any).matching(identifier: "capacity-open-accounts").firstMatch.click()
            let add = prefs.descendants(matching: .any).matching(identifier: "accounts-add").firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5), "the button switches to the Accounts tab")
            add.click()
            app.menuItems["Add Pool…"].click()
            let create = app.descendants(matching: .any).matching(identifier: "pool-add-confirm").firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 5))
            create.click()
            XCTAssertTrue(text("New Claude pool", in: prefs).waitForExistence(timeout: 5))
            shoot(prefs, "accounts-pool-added")
        }
    }
}
