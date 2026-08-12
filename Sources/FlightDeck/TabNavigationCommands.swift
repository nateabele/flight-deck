import SwiftUI

/// Window-menu items for moving between sessions.
///
/// **Why these shortcuts reach this menu at all.** AppKit runs a view's
/// `performKeyEquivalent(with:)` *before* the main menu, and `Ghostty.SurfaceView` claims
/// everything libghostty treats as a binding — ⌘⇧[ and ⌘⇧] among them, since libghostty's
/// macOS defaults bind them to `previous_tab`/`next_tab`. Both are registered `consumed`-only
/// (not `performable`, not `all`), which is precisely the shape `MenuKeyEquivalents` offers to
/// the menu before letting the terminal have it. Until now libghostty claimed the keys and the
/// resulting action went nowhere; these items are where it lands.
struct TabNavigationCommands: Commands {
    // Plain `let`, not `@ObservedObject`, for the same reason as `SessionCommands`: no
    // published property is read here, so observing would invalidate and rebuild the menu on
    // every unrelated `SessionStore` mutation — including `applyExternalTitle` firing from the
    // transcript watcher's 500ms poll, potentially while the menu is open.
    let store: SessionStore

    var body: some Commands {
        // Both items stay enabled in every state: a disabled `NSMenuItem` does not fire its
        // key equivalent, so validating them would also silently disable the shortcuts. With
        // fewer than two sessions the action is a no-op, which says the same thing more
        // cheaply — see `SessionStore.cycleSelection(forward:)`.
        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { store.selectPreviousSession() }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Show Next Tab") { store.selectNextSession() }
                .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()
        }
    }
}
