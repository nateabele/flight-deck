// Sources/FlightDeck/MenuKeyEquivalents.swift
import AppKit

/// Decides whether a Ghostty key binding should be offered to the app's menu before the
/// terminal swallows it, and performs that hand-off.
///
/// **Why this exists.** AppKit dispatches a key equivalent to the view hierarchy's
/// `performKeyEquivalent(with:)` *before* the main menu ever sees it. `Ghostty.SurfaceView`
/// returns `true` for anything libghostty considers a binding, and Ghostty's default config
/// binds a lot of ⌘-combinations — so without this hand-off, menu shortcuts (⌘Q among them)
/// are consumed by the terminal and the menu item never fires.
///
/// **Why it stays correct as the app grows.** Nothing here names a specific shortcut.
/// `NSMenu.performKeyEquivalent` walks the entire menu tree and honours item validation, so
/// any menu item or hotkey added later is covered with no change to this file.
enum MenuKeyEquivalents {
    /// Whether a binding with `bindingFlags` should be offered to the menu first.
    ///
    /// Three kinds of binding are deliberately withheld, matching upstream Ghostty
    /// (`AppDelegate.performGhosttyBindingMenuKeyEquivalent`):
    ///
    /// - **`all`** targets the responder chain that the menu itself dispatches through, so
    ///   routing it to the menu would double-dispatch it.
    /// - **`performable`** must reach the terminal even when a menu item shares the
    ///   shortcut — the menu would unconditionally consume it.
    /// - **unconsumed** bindings are meant to pass through to the terminal, so they were
    ///   never ours to intercept.
    ///
    /// A key sequence or key table in progress is also withheld: those are multi-stroke
    /// bindings mid-flight, and handing an intermediate stroke to the menu would break them.
    static func shouldOfferToMenu(
        bindingFlags: Ghostty.Input.BindingFlags,
        inKeySequence: Bool,
        inKeyTable: Bool
    ) -> Bool {
        guard !inKeySequence, !inKeyTable else { return false }
        guard bindingFlags.isDisjoint(with: [.all, .performable]) else { return false }
        return bindingFlags.contains(.consumed)
    }

    /// Offers `event` to the main menu. Returns true when a menu item claimed it, in which
    /// case the caller must not also send the key to the terminal.
    @MainActor
    static func perform(_ event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}
