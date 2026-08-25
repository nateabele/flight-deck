import AppKit

/// Which window is the session window — the one holding the sidebar and the terminal.
///
/// Two features need that answer, and both were burned by asking it a different way.
///
/// **⌘W.** That chord is bound to "Close Session" in the File menu rather than left to AppKit's
/// `performClose:` (see `SessionCommands` for why the responder-chain route does not work from a
/// focused sidebar), and a main-menu key equivalent is offered to the menu *before* the
/// responder chain — so the item answered ⌘W no matter which window had focus. With Settings
/// open and focused, ⌘W closed the session behind it.
///
/// **The passive input monitors.** `SidebarInputMonitor` and `ToolOverlayInputMonitor` see every
/// event in the process, so each must prove which window it is looking at before acting. Both
/// used to do that by latching `NSApp.keyWindow ?? NSApp.mainWindow` once at startup and
/// comparing later events against it. That is unsound, and the failure is not rare:
/// **both properties are nil for as long as the app is inactive**, even for a window that is
/// fully on screen (`SessionWindowTests` measures this). An app launched in the background —
/// which `scripts/swap-release.sh` does every release, relaunching detached from a terminal that
/// keeps focus — therefore resolved nothing inside the latch's 2-second retry budget, gave up
/// permanently, and ran with double-click-to-rename, Return-to-rename and the tool cluster's
/// fade-in silently dead for the life of the process. Asking per event has no such window of
/// failure, and no state to be stale.
///
/// The test is the window's identifier. SwiftUI stamps a `Window(id:)` scene's id onto its
/// `NSWindow`, so the session window carries `RootWindow.id`; the Settings scene's window
/// carries SwiftUI's own `com_apple_SwiftUI_Settings_window`, and an `NSOpenPanel` (Add
/// Project, in-process because the app is unsandboxed) carries none.
///
/// Deliberately identifies the session window rather than listing the windows to exclude:
/// `RootWindow.id` is this app's own value and cannot change without this file's test failing,
/// where SwiftUI's private Settings identifier could change in any macOS release.
@MainActor
enum SessionWindow {
    /// The identifier form, which is what most of the tests exercise: constructing real
    /// `NSWindow`s to check a string comparison would test AppKit rather than this rule.
    static func isSessionWindow(identifier: String?) -> Bool {
        identifier == RootWindow.id
    }

    static func isSessionWindow(_ window: NSWindow?) -> Bool {
        isSessionWindow(identifier: window?.identifier?.rawValue)
    }

    /// Whether the window with keyboard focus is the session window.
    ///
    /// A nil key window answers false, and that is the safe direction: with no focused window
    /// there is no session in front of the user to close, and the ⌘W caller falls through to
    /// `performClose(nil)`, which no-ops on nil.
    static var isKey: Bool { isSessionWindow(NSApp.keyWindow) }

    /// The view a mouse event landed on, or nil when it did not land in the session window.
    ///
    /// This is the entire scope check for the passive monitors. It exists as one function so
    /// the two of them cannot drift apart, and so neither can quietly reintroduce a captured
    /// window: there is nothing here to capture. Events from Settings and from `NSOpenPanel`
    /// answer nil, because neither window carries `RootWindow.id`.
    static func hitView(for event: NSEvent) -> NSView? {
        hitView(inWindow: event.window, at: event.locationInWindow)
    }

    /// The parameterized form, so the rule can be tested without synthesizing an `NSEvent` —
    /// which would need a window on screen and an app AppKit will route events to, i.e. exactly
    /// the conditions this rule exists to stop depending on.
    static func hitView(inWindow window: NSWindow?, at location: NSPoint) -> NSView? {
        guard let window, isSessionWindow(window), let content = window.contentView else { return nil }
        // `NSView.hitTest(_:)` takes a point in the RECEIVER'S SUPERVIEW coordinates; for a
        // window's `contentView` that is already `locationInWindow`, so no conversion.
        return content.hitTest(location)
    }
}
