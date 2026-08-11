import SwiftUI

/// File-menu items for session creation. Both stay enabled in every state: a disabled
/// `NSMenuItem` does not fire its key equivalent, and ⌘N specifically must work when there
/// are no sessions (it reroutes to Add Project).
struct SessionCommands: Commands {
    @ObservedObject var store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { store.createFromMenu() }
                .keyboardShortcut("n", modifiers: .command)

            Button("Add Project…") { store.addProjectFromMenu() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}
