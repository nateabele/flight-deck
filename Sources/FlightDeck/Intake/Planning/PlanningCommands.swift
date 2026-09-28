import IntakeKit
import SwiftUI

/// What the shaping live card can do right now: which transport buttons are lit (from
/// `ShapingModel.enabled`) and how to press one. The control bar's keys and the Run menu both
/// go through this, so a chord can never do something the button beside it wouldn't.
struct PlanningActions {
    var enabled: Set<TransportButton>
    var perform: (TransportButton) -> Void

    /// The live card's actions for intake `id`. Extend lengthens the current cycle by one
    /// round — the stage the tape is in when that stage can still grow, else the next one that
    /// can — and is withheld when nothing can (`TapePlanner` would ignore it). `annotate` starts a
    /// note in the notes rail — on the plan's selection if there is one (`PlanNotesController.annotate`).
    @MainActor
    static func shaping(_ id: UUID, service: IntakeService, model: ShapingModel,
                        annotate: @escaping () -> Void) -> PlanningActions {
        let current = model.tape.roundInProgress?.stage ?? model.tape.head?.stage
        let extendStage = model.extendStages.first { $0 == current } ?? model.extendStages.first
        var enabled = model.enabled
        if extendStage == nil { enabled.remove(.extend) }
        return PlanningActions(enabled: enabled) { button in
            switch button {
            case .step: service.send(id, .step)
            case .nextMajor: service.send(id, .nextMajor)
            case .toReview: service.send(id, .toReview)
            case .pause: service.send(id, .pause)
            case .stop: service.send(id, .stop)
            case .extend: if let extendStage { service.send(id, .extend(extendStage, by: 1)) }
            case .annotate: annotate()
            }
        }
    }
}

struct PlanningActionsKey: FocusedValueKey {
    typealias Value = PlanningActions
}

extension FocusedValues {
    /// Published by the shaping live card (`.focusedValue(\.planningActions, …)`) so the Run
    /// menu acts on the run the human is looking at, and on nothing while focus is elsewhere.
    var planningActions: PlanningActions? {
        get { self[PlanningActionsKey.self] }
        set { self[PlanningActionsKey.self] = newValue }
    }
}

/// The Run menu (spec §4): every transport command and round tool, with its chord.
///
/// **The chords, checked against Ghostty.** `Ghostty.SurfaceView.performKeyEquivalent` runs
/// before the main menu and swallows any chord libghostty binds `performable`
/// (`MenuKeyEquivalents`). None of these is in libghostty's macOS defaults
/// (`vendor/ghostty/src/config/Config.zig`): ⌘' ⇧⌘' ⌥⌘' ⇧⌘. ⌘. and ⌥⌘A are unbound, and
/// ⌘= (`increase_font_size`) is already unbound in `GhosttyDefaults.conf`. An unbound chord
/// falls through the surface to the menu. The spec's ⇧⌘A for Annotate is taken in-app by
/// File ▸ Add Project…, so Annotate is ⌥⌘A.
///
/// **Why these items DO disable,** unlike `EditCommands`/`SearchCommands`: a disabled item's
/// chord doesn't fire, and here that is the point — with no run in focus, or a button that's
/// dark on the bar, ⌘. must not stop anything.
struct PlanningCommands: Commands {
    @FocusedValue(\.planningActions) private var actions

    var body: some Commands {
        CommandMenu("Run") {
            item("Step", .step, "'", [.command])
            item("Next Major", .nextMajor, "'", [.command, .shift])
            item("To Review", .toReview, "'", [.command, .option])
            Divider()
            // Stop takes ⌘., the Mac's "stop the operation" chord; Pause is its shifted neighbour.
            item("Pause", .pause, ".", [.command, .shift])
            item("Stop", .stop, ".", [.command])
            Divider()
            item("Extend", .extend, "=", [.command])
            item("Annotate", .annotate, "a", [.command, .option])
        }
    }

    private func item(_ title: String, _ button: TransportButton, _ key: KeyEquivalent,
                      _ modifiers: EventModifiers) -> some View {
        Button(title) { actions?.perform(button) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!(actions?.enabled.contains(button) ?? false))
    }
}
