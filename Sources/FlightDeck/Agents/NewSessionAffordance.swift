import AppKit
import SwiftUI

/// Maps the ordered agent list onto New Session shortcuts, labels and glyphs.
///
/// Pure so the binding rules are testable without a window: the interesting behaviour is
/// that ORDER decides the shortcut, and that has nothing to do with SwiftUI.
enum NewSessionAffordance {
    struct Slot: Equatable {
        let agent: AgentID
        let label: String
        let shortcutDisplay: String
        let modifiers: NSEvent.ModifierFlags
    }

    /// Escalating modifiers, in the order macOS conventionally stacks them. Beyond three
    /// agents there is no further shortcut: extra rows stay menu-reachable rather than
    /// inventing chords that collide with system shortcuts.
    private static let ladder: [NSEvent.ModifierFlags] = [
        [.command], [.command, .shift], [.command, .shift, .option],
    ]

    static func slots(for agents: [AgentSettings]) -> [Slot] {
        agents.enumerated().compactMap { index, settings in
            guard index < ladder.count else { return nil }
            let modifiers = ladder[index]
            return Slot(
                agent: settings.id,
                label: "New \(settings.id.displayName) Session",
                shortcutDisplay: display(modifiers),
                modifiers: modifiers
            )
        }
    }

    /// Which slot the currently-held modifiers would trigger.
    ///
    /// `.command` is ignored when matching: the user is holding ⇧ on the way to ⌘⇧N, and the
    /// button must already read "New Codex Session" at that moment — that live feedback is
    /// the point of the affordance.
    static func resolve(_ held: NSEvent.ModifierFlags, in agents: [AgentSettings]) -> Slot? {
        let all = slots(for: agents)
        let significant = held.intersection([.shift, .option])
        return all.first { $0.modifiers.intersection([.shift, .option]) == significant } ?? all.first
    }

    /// `.keyboardShortcut(_:modifiers:)` wants SwiftUI's `EventModifiers`, not the `NSEvent`
    /// flags `resolve`/`ModifierWatcher` work in — the two call sites (`SessionCommands`,
    /// `SessionSidebar`) both need this, so it lives on the type they both already import.
    static func eventModifiers(_ modifiers: NSEvent.ModifierFlags) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    private static func display(_ modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + "N"
    }

    /// One entry per agent, nesting its accounts only when it has more than one. The checkmark
    /// rides on `isResolved` so the menu shows what ⌘N would actually do in this project.
    ///
    /// Deliberately separate from `slots(for:)`: shortcuts bind to *agent* position, and never
    /// move when an account is merely chosen from here — choosing "Work" over the project's
    /// default is a mouse-only act, not a rebind. An agent absent from `accounts` entirely
    /// (nothing logged in yet) contributes no row at all, rather than a dead one nothing can
    /// launch.
    enum MenuEntry: Equatable {
        case agent(AgentID, account: UUID, isResolved: Bool)
        indirect case submenu(AgentID, [MenuEntry])

        /// Which agent this row (or submenu) belongs to, regardless of case — lets callers
        /// key a lookup by agent without re-deriving the switch themselves.
        var agent: AgentID {
            switch self {
            case .agent(let agent, _, _): return agent
            case .submenu(let agent, _): return agent
            }
        }
    }

    static func menu(
        agents: [AgentSettings], accounts: [AgentAccount], resolved: [AgentID: UUID]
    ) -> [MenuEntry] {
        agents.compactMap { settings in
            let mine = accounts.filter { $0.agent == settings.id }
            guard !mine.isEmpty else { return nil }
            let rows = mine.map {
                MenuEntry.agent(settings.id, account: $0.id, isResolved: resolved[settings.id] == $0.id)
            }
            return mine.count == 1 ? rows[0] : .submenu(settings.id, rows)
        }
    }

    /// Same as `menu(agents:accounts:resolved:)`, but reads `preferences.liveAccounts` itself
    /// rather than trusting the caller to pass the live list. The filtering has to live in the
    /// signature, not in a convention each call site remembers: a call site that passed the raw
    /// `accounts` array here would compile fine and would keep a removed login's row in the
    /// menu, letting it launch a tab keyed on an id the next launch purges. `SessionCommands`
    /// and `SessionSidebar` both call this instead of `menu(accounts:)` directly so that mistake
    /// can't happen at either site — or a future third one.
    static func menu(
        agents: [AgentSettings], preferences: Preferences, resolved: [AgentID: UUID]
    ) -> [MenuEntry] {
        menu(agents: agents, accounts: preferences.liveAccounts, resolved: resolved)
    }

    /// Which account, inside a multi-account submenu's rows, should carry the flat
    /// keyboard shortcut that used to sit on the agent's own (now-nested) menu item.
    ///
    /// The resolved row wins — the same one the checkmark already marks, so the chord and
    /// the visible default never disagree. If nothing is resolved (an unreachable state
    /// today, since `resolved` always names one account when any exist), the first row
    /// still gets it: an agent slot bound by `slots(for:)` must always answer somewhere,
    /// never go silently dead because nothing happened to be marked resolved.
    static func shortcutLeaf(in rows: [MenuEntry]) -> UUID? {
        for row in rows {
            if case .agent(_, let account, let isResolved) = row, isResolved {
                return account
            }
        }
        if case .agent(_, let account, _) = rows.first {
            return account
        }
        return nil
    }

    /// The chord each account row should display, keyed by account.
    ///
    /// Placement is not re-derived here: `slots(for:)` already decides which agents carry a
    /// chord at all (list position, capped at three), and `shortcutLeaf(in:)` already decides
    /// which leaf of a multi-account agent wears it. This pairs the two so the sidebar's
    /// dropdown and the File menu render the same chords from one rule instead of each
    /// keeping its own copy of the placement logic and drifting apart.
    ///
    /// An account absent from the result carries no chord: a leaf that is not the shortcut
    /// leaf, or any agent past the third. Built with `reduce` for the same reason
    /// `SessionCommands` does — nothing enforces one row per `AgentID`, and a duplicate must
    /// not crash the menu, so last position wins.
    static func chords(
        for entries: [MenuEntry], agents: [AgentSettings]
    ) -> [UUID: NSEvent.ModifierFlags] {
        let byAgent = slots(for: agents).reduce(into: [AgentID: NSEvent.ModifierFlags]()) {
            $0[$1.agent] = $1.modifiers
        }
        return entries.reduce(into: [UUID: NSEvent.ModifierFlags]()) { result, entry in
            guard let modifiers = byAgent[entry.agent] else { return }
            switch entry {
            case .agent(_, let account, _):
                result[account] = modifiers
            case .submenu(_, let rows):
                if let leaf = shortcutLeaf(in: rows) { result[leaf] = modifiers }
            }
        }
    }
}
