import AppKit
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

    /// The flat, single-item row for an agent with 0 or 1 accounts. `account` stays nil on
    /// the create call either way, so it resolves to the project's default — unchanged from
    /// before nested accounts existed. Carries its list-position shortcut only when one
    /// exists (`slots(for:)` caps at three agents).
    @ViewBuilder
    private func flatAgentRow(agent: AgentSettings, slot: NewSessionAffordance.Slot?) -> some View {
        if let slot {
            Button(slot.label) { Task { await store.createFromMenu(agent: agent.id) } }
                .keyboardShortcut("n", modifiers: NewSessionAffordance.eventModifiers(slot.modifiers))
        } else {
            Button("New \(agent.id.displayName) Session") {
                Task { await store.createFromMenu(agent: agent.id) }
            }
        }
    }

    /// One leaf inside a multi-account agent's submenu. `shortcutModifiers` is non-nil on
    /// at most one leaf per submenu — the one `NewSessionAffordance.shortcutLeaf` picked —
    /// everything else renders identically but un-chorded.
    @ViewBuilder
    private func accountMenuRow(
        agent: AgentID, account: UUID, isResolved: Bool, shortcutModifiers: NSEvent.ModifierFlags?
    ) -> some View {
        let name = preferences.account(id: account)?.displayName ?? agent.displayName
        if let shortcutModifiers {
            Button {
                Task { await store.createFromMenu(agent: agent, account: account) }
            } label: {
                if isResolved { Label(name, systemImage: "checkmark") } else { Text(name) }
            }
            .keyboardShortcut("n", modifiers: NewSessionAffordance.eventModifiers(shortcutModifiers))
        } else {
            Button {
                Task { await store.createFromMenu(agent: agent, account: account) }
            } label: {
                if isResolved { Label(name, systemImage: "checkmark") } else { Text(name) }
            }
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // One entry per agent, in agent order — never two items with the same title.
            // 0 or 1 accounts renders flat, exactly as before nested accounts existed; 2+
            // renders as a submenu of account rows instead of a second, duplicate item.
            //
            // A submenu-bearing `NSMenuItem` cannot itself carry a key equivalent that
            // fires while the menu is closed, so the shortcut for a nested agent moves
            // onto one of its leaves instead of vanishing: AppKit's key-equivalent
            // matching recurses into submenus, so a leaf's chord still fires without the
            // submenu ever opening. `NewSessionAffordance.shortcutLeaf` picks the resolved
            // leaf — the same one already wearing the checkmark — falling back to the
            // first leaf so the chord is never simply dropped.
            // Built with `reduce`, not `Dictionary(uniqueKeysWithValues:)`: the Agents list
            // is meant to hold one row per `AgentID`, but nothing enforces that here, and a
            // duplicate must not crash the menu — last position wins, same as any other
            // last-write lookup.
            let agents = agentsForCurrentProject
            let slotByAgent = NewSessionAffordance.slots(for: agents).reduce(into: [AgentID: NewSessionAffordance.Slot]()) {
                $0[$1.agent] = $1
            }
            let entries: [NewSessionAffordance.MenuEntry] = currentProject.path.map { project in
                NewSessionAffordance.menu(
                    agents: agents, preferences: preferences.preferences,
                    resolved: preferences.resolvedAccounts(for: agents, project: project)
                )
            } ?? []
            let entryByAgent = entries.reduce(into: [AgentID: NewSessionAffordance.MenuEntry]()) {
                $0[$1.agent] = $1
            }
            // Which account row wears which chord — shared with the sidebar's dropdown so both
            // menus place shortcuts by one rule instead of each re-deriving it.
            let chords = NewSessionAffordance.chords(for: entries, agents: agents)

            ForEach(Array(agents.enumerated()), id: \.offset) { _, settings in
                let slot = slotByAgent[settings.id]
                if let entry = entryByAgent[settings.id], case .submenu(let agent, let rows) = entry {
                    Menu("New \(agent.displayName) Session") {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            if case .agent(let rowAgent, let account, let isResolved) = row {
                                accountMenuRow(
                                    agent: rowAgent, account: account, isResolved: isResolved,
                                    shortcutModifiers: chords[account]
                                )
                            }
                        }
                    }
                } else {
                    flatAgentRow(agent: settings, slot: slot)
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

            // Stays enabled and guards internally, for the same reason as Rename Session
            // above: `store` is a plain `let`, so a `.disabled(...)` condition would be
            // evaluated once at menu build time and freeze there — and a disabled
            // `NSMenuItem` does not fire its key equivalent at all.
            // `reopenLastClosed` no-ops on an empty history, which is the whole guard.
            //
            // ⌘⇧T reaches this item only because `GhosttyDefaults.conf` unbinds it. Ghostty
            // binds it to `undo` on macOS and marks it `performable`, and the
            // `MenuKeyEquivalents` hand-off that saves ⌘⇧[ and ⌘⇧] deliberately does NOT
            // cover performable bindings — so while libghostty claimed this chord,
            // `Ghostty.SurfaceView.performKeyEquivalent` swallowed it and this item never
            // fired with a terminal focused. See that file's entry for the full reasoning;
            // moving the shortcut here without it is what breaks it.
            Button("Reopen Closed Session") { store.reopenLastClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])

            // ⌘W is bound here, to the store, rather than left to AppKit's `performClose:`.
            //
            // The responder-chain route only ever worked with focus inside the terminal:
            // `TerminalHostView` implements `performClose:` and sits below the terminal pane,
            // so a focused surface reaches it — but from a focused sidebar there is nothing
            // between the sidebar and the window, `NSWindow` implements `performClose:`
            // itself, and the window claimed the key. Since closing this app's only window
            // quits it, ⌘W in the sidebar was ⌘Q.
            //
            // This item sits in the File menu ahead of the Close item SwiftUI adds for the
            // `Window` scene, and `NSMenu.performKeyEquivalent` takes the first matching
            // enabled item it walks, so this one answers ⌘W from every focus state.
            // `closeSelectedSession` reporting false is the empty state — nothing to close —
            // where the key falls through to closing the window as it always did.
            //
            // Answering ⌘W from every focus state is what this item is for, but "every focus
            // state" used to include the *other* windows: a main-menu key equivalent is
            // offered to the menu before the responder chain, so with Settings open and
            // focused ⌘W closed the session behind it instead of the window in front of it.
            // `SessionWindow.isKey` is the guard, and the fallback is the same one the empty
            // state already used — close the focused window, which is what ⌘W means anywhere
            // but here.
            Button("Close Session") {
                guard SessionWindow.isKey else {
                    NSApp.keyWindow?.performClose(nil)
                    return
                }
                if !store.closeSelectedSession() { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}
