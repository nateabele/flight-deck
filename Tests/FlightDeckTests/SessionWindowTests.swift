import AppKit
import XCTest
@testable import FlightDeck

/// Which window ⌘W is talking to.
///
/// The bug these exist to prevent: "Close Session" binds ⌘W in the File menu, and a main-menu
/// key equivalent is offered to the menu *before* the responder chain — so with the Settings
/// window open and focused, ⌘W closed the session behind it rather than the window in front
/// of it. `SessionCommands` now falls through to `performClose(nil)` for any window that is
/// not the session window.
///
/// The identifiers below are not invented: they were read off the running app. The session
/// window carries `RootWindow.id`, which SwiftUI stamps on from the `Window(id:)` scene, and
/// the Settings scene's window carries SwiftUI's own `com_apple_SwiftUI_Settings_window`.
@MainActor
final class SessionWindowTests: XCTestCase {
    func testTheSceneIdIsWhatIdentifiesTheSessionWindow() {
        // Both halves of the rule live in this app: `RootWindow` names the scene, SwiftUI
        // copies that onto the NSWindow, and `SessionWindow` reads it back. Renaming the scene
        // without this test would silently disable ⌘W's session close.
        XCTAssertEqual(RootWindow.id, "main")
        XCTAssertTrue(SessionWindow.isSessionWindow(identifier: RootWindow.id))
    }

    func testTheSettingsWindowIsNotTheSessionWindow() {
        XCTAssertFalse(SessionWindow.isSessionWindow(identifier: "com_apple_SwiftUI_Settings_window"))
    }

    func testAnUnidentifiedWindowIsNotTheSessionWindow() {
        // `NSOpenPanel` — "Add Project", in-process because the app is unsandboxed — is the
        // real case: it carries no identifier at all, and ⌘W there means "close the panel".
        XCTAssertFalse(SessionWindow.isSessionWindow(identifier: nil))
    }

    func testAWindowCarryingTheSceneIdIsRecognized() {
        // The `NSWindow` overload on top of the string rule, so the property lookup itself is
        // covered rather than assumed.
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(RootWindow.id)
        XCTAssertTrue(SessionWindow.isSessionWindow(window))

        window.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        XCTAssertFalse(SessionWindow.isSessionWindow(window))
    }

    func testANilWindowIsNotTheSessionWindow() {
        // What `isKey` answers when nothing has focus: false, so ⌘W falls through to
        // `performClose(nil)`, which no-ops.
        XCTAssertFalse(SessionWindow.isSessionWindow(nil))
    }
}
