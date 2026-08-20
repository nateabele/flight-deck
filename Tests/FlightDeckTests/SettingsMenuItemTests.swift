import AppKit
import XCTest
@testable import FlightDeck

/// Locating SwiftUI's own Settings item, which is the only reliable way to open the Settings
/// scene from AppKit code.
///
/// The bug these exist to prevent, observed in the running app: "Configure Tools…" called
/// `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`, which **returned
/// true** — something in the responder chain claims that selector — while no window ever
/// appeared. Because it reported success, the `showPreferencesWindow:` fallback never ran
/// either. A menu item that silently does nothing is exactly what that fallback was meant to
/// prevent, and it failed to, because "did a responder accept this?" is not the same question
/// as "did Settings open?".
@MainActor
final class SettingsMenuItemTests: XCTestCase {
    /// Mirrors what SwiftUI installs: a ⌘, item whose action is a private selector on a
    /// private target. Neither name is ours to depend on, which is the point.
    private func swiftUIStyleAppMenu(title: String = "Settings…") -> NSMenu {
        let appMenu = NSMenu(title: "Flight Deck")
        appMenu.addItem(withTitle: "About Flight Deck", action: nil, keyEquivalent: "")
        let settings = NSMenuItem(
            title: title, action: Selector(("menuAction:")), keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        appMenu.addItem(settings)
        appMenu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "q")
        return appMenu
    }

    func testFindsTheSettingsItemByItsKeyEquivalent() {
        let item = SettingsMenuItem.locate(in: swiftUIStyleAppMenu())
        XCTAssertEqual(item?.title, "Settings…")
    }

    func testMatchesOnTheChordRatherThanTheTitle() {
        // The title is localized and macOS 13 renamed it from "Preferences…" to "Settings…".
        // ⌘, is the part that has not moved, so that is what we match on.
        let item = SettingsMenuItem.locate(in: swiftUIStyleAppMenu(title: "Einstellungen…"))
        XCTAssertEqual(item?.title, "Einstellungen…")
    }

    func testIgnoresACommaItemThatHasNoAction() {
        // A separator or a disabled placeholder must not be mistaken for the real thing —
        // sending a nil action would be a silent no-op, the very failure being fixed.
        let appMenu = NSMenu(title: "Flight Deck")
        let inert = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        inert.keyEquivalentModifierMask = [.command]
        appMenu.addItem(inert)
        XCTAssertNil(SettingsMenuItem.locate(in: appMenu))
    }

    func testIgnoresACommaItemThatIsNotCommandChorded() {
        let appMenu = NSMenu(title: "Flight Deck")
        let wrong = NSMenuItem(title: "Something", action: Selector(("menuAction:")), keyEquivalent: ",")
        wrong.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(wrong)
        XCTAssertNil(SettingsMenuItem.locate(in: appMenu))
    }

    func testReturnsNilWhenThereIsNoSettingsItem() {
        let appMenu = NSMenu(title: "Flight Deck")
        appMenu.addItem(withTitle: "About", action: nil, keyEquivalent: "")
        XCTAssertNil(SettingsMenuItem.locate(in: appMenu))
    }
}
