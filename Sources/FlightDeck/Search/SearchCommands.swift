import SwiftUI

extension Notification.Name {
    /// Posted by the ⌘K menu item. `AppDelegate` owns the panel, and a `Commands` struct
    /// has no route to it — the same shape `SessionCommands` uses for window-level actions.
    static let flightDeckOpenSearch = Notification.Name("flightDeckOpenSearch")
}

/// The ⌘K menu item.
///
/// In the File menu's `.textEditing` group rather than a menu of its own: it is a find, and
/// this is where a find belongs. It carries no `.disabled(...)` — a disabled `NSMenuItem`
/// does not fire its key equivalent, which would silently kill the shortcut, exactly as
/// `EditCommands` documents.
struct SearchCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search…") {
                NotificationCenter.default.post(name: .flightDeckOpenSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}
