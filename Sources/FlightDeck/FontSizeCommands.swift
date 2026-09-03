import SwiftUI

/// View-menu items for terminal text size: bigger, smaller, actual size.
///
/// **Why these shortcuts reach this menu at all.** In `vendor/ghostty/src/config/Config.zig`
/// (~L6465-6490) the font-size bindings (`increase_font_size`, `decrease_font_size`,
/// `reset_font_size`) are registered with `set.put`, not `set.putFlags` — so they end up
/// `consumed` but NOT `performable`. That is exactly the shape `MenuKeyEquivalents
/// .shouldOfferToMenu` hands to the main menu before the terminal gets the key, which is why
/// ⇧⌘=, ⇧⌘- and ⌘0 work here with no `GhosttyDefaults.conf` unbind. Contrast with ⌘K and
/// ⌘⇧T, which libghostty registers `performable` and which therefore do need an unbind to
/// keep the terminal from claiming them first.
///
/// **Why no `.disabled(...)`.** A disabled `NSMenuItem` does not fire its key equivalent, so
/// validating here would silently kill the shortcut too — the same rule `EditCommands` and
/// `TabNavigationCommands` document.
///
/// **Why the size is set absolutely, not by increment.** libghostty has no font-size getter
/// and no `increase_font_size`/`decrease_font_size` *action* wired here — only
/// `set_font_size:<points>`, an absolute set. So this file owns the current number
/// (`Preferences.terminalFontSize`), steps it with `TerminalFontSize`, and pushes the result
/// to every surface via `SessionStore.applyTerminalFontSize`. Counting increments instead
/// would let a surface's on-screen size and the stored preference drift apart the moment one
/// changed without the other — an absolute set makes that desync impossible.
struct FontSizeCommands: Commands {
    let store: SessionStore
    @ObservedObject var preferences: PreferencesStore

    var body: some Commands {
        // `.toolbar` is the group SwiftUI places in the View menu.
        CommandGroup(after: .toolbar) {
            Button("Bigger") {
                let current = TerminalFontSize.resolved(
                    preferences.preferences.terminalFontSize, default: store.defaultFontSize
                )
                let bigger = TerminalFontSize.bigger(current)
                preferences.preferences.terminalFontSize = bigger
                store.applyTerminalFontSize(bigger)
            }
            .keyboardShortcut("=", modifiers: [.command, .shift])

            Button("Smaller") {
                let current = TerminalFontSize.resolved(
                    preferences.preferences.terminalFontSize, default: store.defaultFontSize
                )
                let smaller = TerminalFontSize.smaller(current)
                preferences.preferences.terminalFontSize = smaller
                store.applyTerminalFontSize(smaller)
            }
            .keyboardShortcut("-", modifiers: [.command, .shift])

            Button("Actual Size") {
                preferences.preferences.terminalFontSize = nil
                store.applyTerminalFontSize(store.defaultFontSize)
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
        }
    }
}
