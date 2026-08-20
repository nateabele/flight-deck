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
    // `@ObservedObject`, unlike `store` above: this menu's items ARE built from
    // `preferences.agents` (by way of `agentOrder(forProject:)`, ordered for whichever project
    // `currentProject.path` names right now), so a reorder in the Agents tab has to rebuild it.
    // SwiftUI cannot vary a `.keyboardShortcut` at runtime, so each agent list position gets
    // its own statically-chorded item here — the *button* in the sidebar is the one that reads
    // live.
    @ObservedObject var preferences: PreferencesStore
    // Also `@ObservedObject`, for the project half of the same problem: `store` staying a
    // plain `let` above means nothing here would otherwise notice a project switch that
    // happens without a `preferences` change, and ⌘N's key equivalent closes over `slot.agent`
    // captured at the *last* `body` build — a stale build after such a switch would still fire
    // the previous project's agent. `CurrentProjectObserver` narrows observation to exactly
    // that one derived value, so a title edit, an unread flag, or the transcript watcher's poll
    // still rebuild nothing here. See its own doc comment for why plain `let store` cannot
    // simply widen to `@ObservedObject`.
    @ObservedObject private var currentProject: CurrentProjectObserver

    init(store: SessionStore, preferences: PreferencesStore) {
        self.store = store
        self.preferences = preferences
        _currentProject = ObservedObject(wrappedValue: CurrentProjectObserver(store: store))
    }

    private var agentsForCurrentProject: [AgentSettings] {
        guard let project = currentProject.path else { return preferences.preferences.agents }
        return preferences.agentOrder(forProject: project)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            ForEach(Array(NewSessionAffordance.slots(for: agentsForCurrentProject).enumerated()), id: \.offset) { _, slot in
                Button(slot.label) { Task { await store.createFromMenu(agent: slot.agent) } }
                    .keyboardShortcut("n", modifiers: NewSessionAffordance.eventModifiers(slot.modifiers))
            }

            // Mouse-only account submenus, alongside the shortcut items above rather than
            // replacing any of them: a submenu-bearing `NSMenuItem` cannot also carry a key
            // equivalent that fires directly, so an agent with more than one account gets a
            // second, un-chorded entry here purely to reach the non-default login. Flat
            // single-account rows are omitted — the shortcut item above already reaches them.
            if let project = currentProject.path {
                let agents = agentsForCurrentProject
                let entries = NewSessionAffordance.menu(
                    agents: agents, accounts: preferences.preferences.accounts,
                    resolved: preferences.resolvedAccounts(for: agents, project: project)
                )
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    if case .submenu(let agent, let rows) = entry {
                        Menu("New \(agent.displayName) Session") {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                if case .agent(let agent, let account, let isResolved) = row {
                                    Button {
                                        Task { await store.createFromMenu(agent: agent, account: account) }
                                    } label: {
                                        let name = preferences.account(id: account)?.displayName ?? agent.displayName
                                        if isResolved { Label(name, systemImage: "checkmark") } else { Text(name) }
                                    }
                                }
                            }
                        }
                    }
                }
            }

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
