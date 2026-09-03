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
/// **Why `nil` targets.** Each button forwards to the first responder via `NSApp.sendAction`,
/// so the item acts on whichever surface is focused without this file knowing about the
/// session store. That mirrors `EditCommands` and `TabNavigationCommands`.
///
/// **Why no `.disabled(...)`.** A disabled `NSMenuItem` does not fire its key equivalent, so
/// validating here would silently kill the shortcut too — the same rule `EditCommands` and
/// `TabNavigationCommands` document.
struct FontSizeCommands: Commands {
    var body: some Commands {
        // `.toolbar` is the group SwiftUI places in the View menu.
        CommandGroup(after: .toolbar) {
            Button("Bigger") {
                send(#selector(Ghostty.SurfaceView.increaseFontSize(_:)))
            }
            .keyboardShortcut("=", modifiers: [.command, .shift])

            Button("Smaller") {
                send(#selector(Ghostty.SurfaceView.decreaseFontSize(_:)))
            }
            .keyboardShortcut("-", modifiers: [.command, .shift])

            Button("Actual Size") {
                send(#selector(Ghostty.SurfaceView.resetFontSize(_:)))
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
        }
    }

    private func send(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
