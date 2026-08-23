import AppKit

/// Which window is the session window — the one holding the sidebar and the terminal.
///
/// Exists for ⌘W. That chord is bound to "Close Session" in the File menu rather than left to
/// AppKit's `performClose:` (see `SessionCommands` for why the responder-chain route does not
/// work from a focused sidebar), and a main-menu key equivalent is offered to the menu *before*
/// the responder chain — so the item answered ⌘W no matter which window had focus. With
/// Settings open and focused, ⌘W closed the session behind it.
///
/// The test is the window's identifier. SwiftUI stamps a `Window(id:)` scene's id onto its
/// `NSWindow`, so the session window carries `RootWindow.id`; the Settings scene's window
/// carries SwiftUI's own `com_apple_SwiftUI_Settings_window`, and an `NSOpenPanel` (Add
/// Project, in-process because the app is unsandboxed) carries none. Only the first is a
/// window where closing a *session* is what ⌘W should mean.
///
/// Deliberately identifies the session window rather than listing the windows to exclude:
/// `RootWindow.id` is this app's own value and cannot change without this file's test failing,
/// where SwiftUI's private Settings identifier could change in any macOS release.
@MainActor
enum SessionWindow {
    /// The identifier form, which is what the tests exercise: constructing real `NSWindow`s to
    /// check a string comparison would test AppKit rather than this rule.
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
}
