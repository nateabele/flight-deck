import AppKit

/// Opens Preferences on the Tools pane — the action behind "Configure Tools…".
///
/// Extracted from `AppDelegate` so the Tools menu item and the overlay's ⌘-revealed sprocket
/// invoke one implementation rather than two that can drift. "Same thing as the menu item" is
/// a requirement here, not a coincidence, and the sequencing below is the reason it cannot
/// simply be re-typed at each call site.
@MainActor
enum ToolsPreferencesOpener {
    static func open(_ preferences: PreferencesStore?) {
        // Choose the pane BEFORE the window opens: on a first open the view is built from
        // this value, and on a later one the published change moves the live selection.
        // Setting it afterwards would flash the previous pane.
        preferences?.selectedTab = .tools

        // Drive SwiftUI's own Settings item rather than guessing a selector. See
        // `SettingsMenuItem`: `showSettingsWindow:` returns true on this macOS and opens
        // nothing, so a fallback guarded on its return value can never fire.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let item = SettingsMenuItem.locate(in: appMenu),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        // Only reached if SwiftUI's item is missing entirely — a shape this app has never
        // been observed in, but a wrong-looking window beats a dead menu item.
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
