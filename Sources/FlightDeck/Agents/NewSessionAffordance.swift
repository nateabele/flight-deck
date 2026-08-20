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
}
