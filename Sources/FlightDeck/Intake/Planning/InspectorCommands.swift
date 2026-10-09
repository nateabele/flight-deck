import SwiftUI

/// What View ▸ Inspector acts on: the plan on screen, its modes, and the one showing. Published
/// scene-wide by the intake detail pane, like `PlanningActions`, and nil whenever the window
/// shows anything else — so the items disable, and a disabled item's chord falls through.
///
/// Equatable on everything but the closure, for `PlanningActions`' reason: a value SwiftUI
/// can't compare is a new value on every render of the pane, re-evaluating the menu each time.
struct InspectorModeActions: Equatable {
    var intakeID: UUID
    var modes: [DetailLayout.InspectorMode]
    var mode: DetailLayout.InspectorMode
    /// Switches to the mode and opens the column.
    var select: (DetailLayout.InspectorMode) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.intakeID == b.intakeID && a.modes == b.modes && a.mode == b.mode
    }
}

struct InspectorModeActionsKey: FocusedValueKey {
    typealias Value = InspectorModeActions
}

extension FocusedValues {
    var inspectorModeActions: InspectorModeActions? {
        get { self[InspectorModeActionsKey.self] }
        set { self[InspectorModeActionsKey.self] = newValue }
    }
}

/// View ▸ Inspector ▸ Notes ⌥⌘1 / Rounds ⌥⌘2 — Xcode's inspector-tab chords, and the
/// Keynote/Pages place for them. Each item shows the column on its mode, checked while it is
/// the one showing; ⌥⌘I still only shows and hides the column.
///
/// **The chords, checked against Ghostty.** libghostty's macOS defaults
/// (`vendor/ghostty/src/config/Config.zig`) bind ⌘1–⌘8 (`goto_tab`) and ⌘9 (`last_tab`) with
/// `.super` alone, and nothing on ⌥⌘ plus a digit, so these fall through a focused surface to
/// the menu (`MenuKeyEquivalents`) with no unbind in `GhosttyDefaults.conf`. They also don't
/// reach a terminal at all while it has focus: no intake pane is on screen then, so the items
/// are disabled, and a disabled item never claims its key.
struct InspectorCommands: Commands {
    @FocusedValue(\.inspectorModeActions) private var actions

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Menu("Inspector") {
                ForEach(DetailLayout.InspectorMode.allCases, id: \.self) { mode in
                    Toggle(mode.title, isOn: Binding(get: { actions?.mode == mode }, set: { _ in actions?.select(mode) }))
                        .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: [.command, .option])
                        .disabled(!(actions?.modes.contains(mode) ?? false))
                }
            }
        }
    }
}
