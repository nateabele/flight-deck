import SwiftUI

/// File-menu items for session creation. Both stay enabled in every state: a disabled
/// `NSMenuItem` does not fire its key equivalent, and ⌘N specifically must work when there
/// are no sessions (it reroutes to Add Project).
struct SessionCommands: Commands {
    // Plain `let`, not `@ObservedObject`: no published property is read here, so observing
    // would invalidate and rebuild the menu on every unrelated `SessionStore` mutation —
    // including `applyExternalTitle` firing from the transcript watcher's 500ms poll —
    // potentially while the menu is open. The actions below close over the same
    // reference-type instance either way.
    let store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { store.createFromMenu() }
                .keyboardShortcut("n", modifiers: .command)

            Button("Add Project…") { store.addProjectFromMenu() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}
