import SwiftUI

/// File-menu items for session creation and renaming. All stay enabled in every state: a
/// disabled `NSMenuItem` does not fire its key equivalent, ⌘N specifically must work when
/// there are no sessions (it reroutes to Add Project), and Rename Session needs its shortcut
/// live so it can guard on the current selection internally (see the comment below).
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

        // Separate group from `.newItem`: renaming isn't a creation command, and this
        // keeps it visually adjacent rather than crowding the New/Add Project block.
        CommandGroup(after: .newItem) {
            // Stays enabled, guarded internally instead of `.disabled(store.selectedSessionID
            // == nil)`: `store` here is a plain `let`, not `@ObservedObject` (see the type's
            // doc comment), so a `.disabled` condition would be evaluated once at menu build
            // time and never refresh as the selection changes — the item would freeze in
            // whatever state existed when the menu was constructed. Guarding in the action
            // keeps the item live and correct without requiring observation.
            Button("Rename Session") {
                guard let id = store.selectedSessionID else { return }
                store.renameRequest = id
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
