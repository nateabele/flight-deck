import SwiftUI

/// Edit-menu items that SwiftUI does not provide.
///
/// **What SwiftUI already gives us, and why it wasn't enough.** The default Edit menu has
/// Cut/Copy/Paste/Select All wired to the first responder, and `Ghostty.SurfaceView` implements
/// `copy(_:)`/`paste(_:)`/`selectAll(_:)`. Those items were never the problem — they fired
/// correctly into libghostty, which then dropped the request because the runtime's clipboard
/// callbacks were empty stubs. That is fixed in `GhosttyApp`; these items add the *entries*
/// SwiftUI has no concept of.
///
/// **Why `nil` targets.** Each button forwards to the first responder via `NSApp.sendAction`,
/// so the item works against whichever surface is focused without this file knowing about the
/// session store. That mirrors how the stock Cut/Copy/Paste items behave.
///
/// **Why no `.disabled(...)`.** A disabled `NSMenuItem` does not fire its key equivalent, so
/// validating here would silently kill the shortcut too. `Ghostty.SurfaceView.validateMenuItem`
/// is where enablement belongs, and it already handles these selectors.
struct EditCommands: Commands {
    var body: some Commands {
        // `.pasteboard` is the group holding Cut/Copy/Paste, so these land directly beneath
        // them rather than in a menu of their own.
        CommandGroup(after: .pasteboard) {
            Button("Paste as Plain Text") {
                send(#selector(Ghostty.SurfaceView.pasteAsPlainText(_:)))
            }
            .keyboardShortcut("v", modifiers: [.command, .shift, .option])

            Button("Paste Selection") {
                send(#selector(Ghostty.SurfaceView.pasteSelection(_:)))
            }

            Divider()

            Button("Find…") { send(#selector(Ghostty.SurfaceView.find(_:))) }
                .keyboardShortcut("f", modifiers: .command)

            Button("Find Next") { send(#selector(Ghostty.SurfaceView.findNext(_:))) }
                .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") { send(#selector(Ghostty.SurfaceView.findPrevious(_:))) }
                .keyboardShortcut("g", modifiers: [.command, .shift])

            Button("Use Selection for Find") {
                send(#selector(Ghostty.SurfaceView.selectionForFind(_:)))
            }
            .keyboardShortcut("e", modifiers: .command)
        }
    }

    private func send(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}
