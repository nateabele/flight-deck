import AppKit
import Combine
import IntakeKit

/// File ▸ New … Session: one row per agent in the current project's order, a submenu of account
/// rows for an agent with two or more logins, and ⌘N / ⇧⌘N / ⌥⇧⌘N on the first three
/// (`NewSessionAffordance`). Pure, so the rules are testable without a menu.
enum NewSessionMenuModel {
    indirect enum Row: Equatable {
        /// `account` nil: the project's resolved default, as a bare ⌘N always used.
        case item(title: String, agent: AgentID, account: UUID?, checked: Bool, chord: NSEvent.ModifierFlags?)
        case submenu(title: String, rows: [Row])
    }

    /// The rows for `project` (nil before any project exists: the global order, no accounts) —
    /// the same derivation `SessionCommands` made in SwiftUI before it moved here.
    @MainActor
    static func rows(project: String?, preferences: PreferencesStore) -> [Row] {
        let agents = project.map(preferences.agentOrder(forProject:)) ?? preferences.preferences.agents
        // `reduce`, not `Dictionary(uniqueKeysWithValues:)`: nothing enforces one row per
        // `AgentID`, and a duplicate must not crash the menu — last position wins.
        let slotByAgent = NewSessionAffordance.slots(for: agents).reduce(into: [AgentID: NewSessionAffordance.Slot]()) {
            $0[$1.agent] = $1
        }
        let entries: [NewSessionAffordance.MenuEntry] = project.map { project in
            NewSessionAffordance.menu(agents: agents, preferences: preferences.preferences,
                                      resolved: preferences.resolvedAccounts(for: agents, project: project))
        } ?? []
        let entryByAgent = entries.reduce(into: [AgentID: NewSessionAffordance.MenuEntry]()) { $0[$1.agent] = $1 }
        // Which account row wears which chord — shared with the sidebar's dropdown.
        let chords = NewSessionAffordance.chords(for: entries, agents: agents)

        return agents.map { settings in
            if let entry = entryByAgent[settings.id], case .submenu(let agent, let rows) = entry {
                return .submenu(title: "New \(agent.displayName) Session", rows: rows.compactMap { row in
                    guard case .agent(let rowAgent, let account, let isResolved) = row else { return nil }
                    let name = preferences.account(id: account)?.displayName ?? rowAgent.displayName
                    return .item(title: name, agent: rowAgent, account: account, checked: isResolved, chord: chords[account])
                })
            }
            if let slot = slotByAgent[settings.id] {
                return .item(title: slot.label, agent: settings.id, account: nil, checked: false, chord: slot.modifiers)
            }
            return .item(title: "New \(settings.id.displayName) Session", agent: settings.id, account: nil, checked: false, chord: nil)
        }
    }
}

/// Keeps File ▸ New … Session current, as AppKit items above Add Project… (`AppKitMenuSlot`).
///
/// **Why not SwiftUI.** The rows follow the current project, and the `Commands` that drew them
/// observed it: every switch between two projects' tabs re-evaluated it, and SwiftUI reconciled
/// the whole main menu, removing the Tools menu each time (11 removals in 10 switches, measured
/// 2026-10-09 against the real `SessionCommands`). These items are rewritten in place when the
/// project or the agent settings change — before the next ⌘N can be pressed, so the chord always
/// launches the current project's agent (the bug `CurrentProjectObserver` was written for) —
/// and SwiftUI never sees it.
@MainActor
final class NewSessionMenuController: NSObject {
    private let store: SessionStore
    private let preferences: PreferencesStore
    private let currentProject: CurrentProjectObserver
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var rows: [NewSessionMenuModel.Row] = []
    private let slot = AppKitMenuSlot(path: ["File"]) { others in
        others.firstIndex { $0.title == "Add Project…" } ?? 0
    }

    init(store: SessionStore, preferences: PreferencesStore) {
        self.store = store
        self.preferences = preferences
        currentProject = CurrentProjectObserver(store: store)
        super.init()
        rebuild()
        // `objectWillChange` fires before the change lands, so the read waits a turn — the
        // reason `CurrentProjectObserver` debounces too.
        preferences.objectWillChange
            .debounce(for: .zero, scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        currentProject.$path
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
            .store(in: &subscriptions)
    }

    func install(in mainMenu: NSMenu) { slot.install(in: mainMenu) }

    /// The items, in order, as they are in the File menu.
    var items: [NSMenuItem] { slot.items }

    /// Rewrites the items only when the rows changed: an unrelated preference edit leaves them.
    func rebuild() {
        let next = NewSessionMenuModel.rows(project: currentProject.path, preferences: preferences)
        guard next != rows || slot.items.isEmpty else { return }
        rows = next
        slot.setItems(next.map(menuItem))
    }

    private func menuItem(_ row: NewSessionMenuModel.Row) -> NSMenuItem {
        switch row {
        case .submenu(let title, let rows):
            // A submenu-bearing item cannot carry a key equivalent that fires while the menu is
            // closed, so the chord sits on one of its leaves (`NewSessionAffordance.shortcutLeaf`);
            // AppKit's key-equivalent matching recurses into submenus, so it still fires.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            for row in rows { submenu.addItem(menuItem(row)) }
            item.submenu = submenu
            return item
        case .item(let title, let agent, let account, let checked, let chord):
            let item = NSMenuItem(title: title, action: #selector(create(_:)), keyEquivalent: chord == nil ? "" : "n")
            item.keyEquivalentModifierMask = chord ?? []
            item.state = checked ? .on : .off
            item.representedObject = Target(agent: agent, account: account)
            item.target = self
            return item
        }
    }

    private final class Target {
        let agent: AgentID
        let account: UUID?
        init(agent: AgentID, account: UUID?) { self.agent = agent; self.account = account }
    }

    @objc private func create(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? Target else { return }
        let store = store
        Task { await store.createFromMenu(agent: target.agent, account: target.account) }
    }
}
