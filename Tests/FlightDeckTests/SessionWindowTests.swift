import AppKit
import XCTest
@testable import FlightDeck

/// Which window ⌘W — and each passive input monitor — is talking to.
///
/// The first bug these exist to prevent: "Close Session" binds ⌘W in the File menu, and a
/// main-menu key equivalent is offered to the menu *before* the responder chain — so with the
/// Settings window open and focused, ⌘W closed the session behind it rather than the window in
/// front of it. `SessionCommands` now falls through to `performClose(nil)` for any window that
/// is not the session window.
///
/// The second: `SidebarInputMonitor` and `ToolOverlayInputMonitor` each used to latch
/// `NSApp.keyWindow ?? NSApp.mainWindow` once at startup and compare later events against it.
/// Launched in the background — every `scripts/swap-release.sh` relaunch — that resolved
/// nothing, and both monitors ran dead for the life of the process: no double-click-to-rename,
/// no Return-to-rename, no tool-cluster fade-in. They ask `SessionWindow` per event now.
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

    // MARK: - Scoping events without depending on activation

    /// The measurement the whole redesign rests on, run in the condition that broke it: this
    /// test bundle's process is never activated, exactly like an app relaunched behind a
    /// terminal. Both properties the old latch read are nil here — for a window that is on
    /// screen, not merely for no window at all — so a one-shot capture had nothing to capture
    /// and no later chance to try again. `SessionWindow` reads an identifier instead, which is
    /// present whether or not anything has focus.
    ///
    /// Skipped rather than failed when the process *is* active (a developer running this from
    /// a foreground Xcode session), because then the precondition simply does not hold.
    func testWindowScopingSurvivesAnAppThatWasNeverActivated() throws {
        let app = NSApplication.shared
        try XCTSkipIf(app.isActive, "precondition is an inactive process; nothing to measure")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(RootWindow.id)
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // The old source of truth, in the condition that killed it.
        XCTAssertTrue(window.isVisible, "the window is on screen; only activation is missing")
        XCTAssertNil(app.keyWindow, "an inactive app has no key window, on screen or not")
        XCTAssertNil(app.mainWindow, "and no main window either — this is what was latched")

        // The new one, unaffected.
        XCTAssertTrue(SessionWindow.isSessionWindow(window))
    }

    func testHitViewFindsTheViewUnderAPointInTheSessionWindow() {
        let (window, child) = Self.makeWindow(identifier: RootWindow.id)
        let point = child.convert(NSPoint(x: 10, y: 10), to: nil)

        XCTAssertIdentical(
            SessionWindow.hitView(inWindow: window, at: point), child,
            "a point over the child view must resolve to it"
        )
    }

    func testHitViewIgnoresEventsInTheSettingsWindow() {
        // Settings ▸ Projects is a second SwiftUI `List`, so without this the sidebar monitor
        // would map a Settings row index onto `sidebarRows` and rename an unrelated session.
        let (window, child) = Self.makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        let point = child.convert(NSPoint(x: 10, y: 10), to: nil)

        XCTAssertNil(SessionWindow.hitView(inWindow: window, at: point))
    }

    func testHitViewIgnoresEventsInAnUnidentifiedWindow() {
        // `NSOpenPanel` — "Add Project", in-process because the app is unsandboxed — is
        // table-backed and carries no identifier at all.
        let (window, child) = Self.makeWindow(identifier: nil)
        let point = child.convert(NSPoint(x: 10, y: 10), to: nil)

        XCTAssertNil(SessionWindow.hitView(inWindow: window, at: point))
    }

    func testHitViewAnswersNilForNoWindow() {
        // A synthesized or already-dispatched event can carry no window; the monitors must
        // treat that as out of scope rather than crash or act.
        XCTAssertNil(SessionWindow.hitView(inWindow: nil, at: .zero))
    }

    func testHitViewAnswersNilForAPointOutsideEveryView() {
        let (window, _) = Self.makeWindow(identifier: RootWindow.id)

        XCTAssertNil(
            SessionWindow.hitView(inWindow: window, at: NSPoint(x: 5000, y: 5000)),
            "off the content view entirely, so there is nothing to act on"
        )
    }

    /// A window with one child view inset from the origin, so a hit on the child is
    /// distinguishable from a hit on the content view and from a miss.
    private static func makeWindow(identifier: String?) -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let child = NSView(frame: NSRect(x: 50, y: 50, width: 100, height: 100))
        content.addSubview(child)
        window.contentView = content
        return (window, child)
    }
}
