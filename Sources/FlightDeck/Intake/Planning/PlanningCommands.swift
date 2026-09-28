import IntakeKit
import SwiftUI

/// What the shaping live card can do right now: which transport buttons are lit (from
/// `ShapingModel.enabled`) and how to press one. The control bar's keys and the Run menu both
/// go through this, so a chord can never do something the button beside it wouldn't.
///
/// Equatable on the intake and the lit buttons, never the closure: published as a scene value,
/// a value SwiftUI can't compare is a new value on every render of the pane, and each one
/// re-evaluated the Run menu's commands.
struct PlanningActions: Equatable {
    var enabled: Set<TransportButton>
    /// The intake the actions press for; nil for a bar with nothing behind it.
    var intakeID: UUID?
    var perform: (TransportButton) -> Void

    init(enabled: Set<TransportButton>, intakeID: UUID? = nil, perform: @escaping (TransportButton) -> Void) {
        self.enabled = enabled
        self.intakeID = intakeID
        self.perform = perform
    }

    static func == (a: PlanningActions, b: PlanningActions) -> Bool {
        a.intakeID == b.intakeID && a.enabled == b.enabled
    }

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
        return PlanningActions(enabled: enabled, intakeID: id) { button in
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
    /// Published scene-wide by the intake detail pane while it shows a shaping run
    /// (`.focusedSceneValue(\.planningActions, …)`), so the Run menu acts on the run on screen
    /// — nothing in the pane takes focus on a click — and on nothing once the window shows
    /// anything else.
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
