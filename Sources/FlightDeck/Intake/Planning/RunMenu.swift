import IntakeKit
import SwiftUI

/// What the shaping live card can do right now: which transport buttons are lit (from
/// `TransportRules`, via `ShapingModel.transport`) and how to press one. The control bar's keys
/// and the Run menu both go through this, so a chord can never do something the button beside
/// it wouldn't.
///
/// Equatable on the intake and the lit buttons, never the closure, so two renders of the same
/// run compare equal.
struct PlanningActions: Equatable {
    var enabled: Set<TransportButton>
    /// The intake the actions press for; nil for a bar with nothing behind it.
    var intakeID: UUID?
    var perform: (TransportButton) -> Void
    /// The section heatmap's Run-menu toggle; nil while the run has no per-section numbers yet
    /// (the heatmap would open onto nothing).
    var heatmap: HeatmapToggle?

    /// Show or hide the heatmap under the board — the same toggle as a click on CONVERGENCE.
    struct HeatmapToggle {
        var open: Bool
        var toggle: () -> Void
    }

    init(enabled: Set<TransportButton>, intakeID: UUID? = nil, perform: @escaping (TransportButton) -> Void) {
        self.enabled = enabled
        self.intakeID = intakeID
        self.perform = perform
    }

    static func == (a: PlanningActions, b: PlanningActions) -> Bool {
        a.intakeID == b.intakeID && a.enabled == b.enabled && a.heatmap?.open == b.heatmap?.open
            && (a.heatmap == nil) == (b.heatmap == nil)
    }

    /// The live card's actions for intake `id`. Extend lengthens, and Trim shortens, the stage
    /// `TransportRules` picks by one round, and each is dark when the rule withholds it. `annotate`
    /// starts a note in the notes rail — on the plan's selection if there is one
    /// (`PlanNotesController.annotate`).
    ///
    /// Stop only ASKS (`confirmStop`): it discards the round in flight, work already paid for,
    /// and one ⌘. did that with no way back (spec §2: destructive actions are always confirmed).
    /// The caller's dialog sends the stop. Both the bar's key and the Run menu press this, so
    /// neither can skip the question. Pause loses nothing and still acts at once.
    @MainActor
    static func shaping(_ id: UUID, service: IntakeService, model: ShapingModel,
                        annotate: @escaping () -> Void, confirmStop: @escaping () -> Void) -> PlanningActions {
        let rules = model.transport
        let extendStage = rules.extendStage, trimStage = rules.trimStage
        return PlanningActions(enabled: rules.enabled, intakeID: id) { button in
            switch button {
            case .step: service.send(id, .step)
            case .nextMajor: service.send(id, .nextMajor)
            case .toReview: service.send(id, .toReview)
            case .pause: service.send(id, .pause)
            case .stop: confirmStop()
            case .extend: if let extendStage { service.send(id, .extend(extendStage, by: 1)) }
            case .trim: if let trimStage { service.send(id, .trim(trimStage, by: 1)) }
            case .annotate: annotate()
            }
        }
    }
}

extension PlanningActions {
    /// The Stop confirmation's message: what stopping throws away, named — the round in
    /// flight's work — and what it keeps.
    static func stopMessage(tape: Tape) -> String {
        let kept = "Every round that already landed stays in the plan."
        guard let round = tape.roundInProgress else { return "No round is running, so nothing will be discarded. \(kept)" }
        return "\(BoardModel.name(stage: round.stage, round: round.round))'s work so far will be discarded. \(kept)"
    }
}

/// The Run menu (spec §4): every transport command and round tool, with its chord — AppKit items
/// inside the constant `RunMenuShell`, acting on the shaping run in the key window
/// (`PaneMenus.planning`, fed by the detail pane's `PaneMenuAnchor`).
///
/// **Why not a SwiftUI `Commands` over a focused value,** which is what this was: the value
/// changed whenever a shaping plan came on or off screen and whenever the lit buttons changed
/// mid-run, and every change made SwiftUI reconcile the main menu, blinking the Tools menu out and
/// in (`AppKitMenuSlot`). Here the enabled state and the heatmap item's title are answered by
/// `validateMenuItem` when the menu opens or a chord is pressed, so nothing is ever rebuilt.
///
/// **The chords, checked against Ghostty.** `Ghostty.SurfaceView.performKeyEquivalent` runs
/// before the main menu and swallows any chord libghostty binds `performable`
/// (`MenuKeyEquivalents`). None of these is in libghostty's macOS defaults
/// (`vendor/ghostty/src/config/Config.zig`): ⌘' ⇧⌘' ⌥⌘' ⇧⌘. ⌘. and ⌥⌘A are unbound, and
/// ⌘= (`increase_font_size`) and ⌘- (`decrease_font_size`) are already unbound in
/// `GhosttyDefaults.conf`. An unbound chord falls through the surface to the menu. The spec's
/// ⇧⌘A for Annotate is taken in-app by File ▸ Add Project…, so Annotate is ⌥⌘A.
///
/// **Why these items DO disable,** unlike `EditCommands`/`SearchCommands`: a disabled item's
/// chord doesn't fire, and here that is the point — with no run on screen, or a button that's
/// dark on the bar, ⌘. must not stop anything.
@MainActor
final class RunMenuController: NSObject, NSMenuItemValidation {
    let items: [NSMenuItem]
    private let registry: PaneMenuRegistry<PlanningActions>
    /// The window the items act on; the key window, else the main one. A seam for tests.
    var window: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    private lazy var slot = AppKitMenuSlot(path: [RunMenuShell.title], hidesOthers: true, items: items)
    /// The heatmap toggle's item, whose title follows the heatmap.
    private let heatmapItem: NSMenuItem

    init(registry: PaneMenuRegistry<PlanningActions> = PaneMenus.planning) {
        self.registry = registry
        func item(_ title: String, _ button: TransportButton, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(RunMenuController.press(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.representedObject = button.menuTag
            return item
        }
        // No chord: ⌥⌘H is Hide Others and ⇧⌘H is taken in terminals; the item is how the
        // keyboard (and VoiceOver) reaches the heatmap at all, not a shortcut to it.
        heatmapItem = NSMenuItem(title: Self.heatmapTitle(open: false), action: #selector(RunMenuController.toggleHeatmap(_:)),
                                 keyEquivalent: "")
        items = [
            item("Step", .step, "'", [.command]),
            item("Next Major", .nextMajor, "'", [.command, .shift]),
            item("To Review", .toReview, "'", [.command, .option]),
            .separator(),
            // Stop takes ⌘., the Mac's "stop the operation" chord; Pause is its shifted neighbour.
            item("Pause", .pause, ".", [.command, .shift]),
            item("Stop", .stop, ".", [.command]),
            .separator(),
            item("Extend", .extend, "=", [.command]),
            // Extend's mirror, on the key beside it: takes back an unstarted round.
            item("Remove a Round", .trim, "-", [.command]),
            item("Annotate", .annotate, "a", [.command, .option]),
            .separator(),
            heatmapItem,
        ]
        super.init()
        for item in items where !item.isSeparatorItem { item.target = self }
    }

    /// Moves the items into the shell and keeps them there (`AppKitMenuSlot`).
    func install(in mainMenu: NSMenu) { slot.install(in: mainMenu) }

    /// The menu holding the items once installed.
    var menu: NSMenu? { slot.host }

    static func heatmapTitle(open: Bool) -> String { open ? "Hide Section Heatmap" : "Show Section Heatmap" }

    private var actions: PlanningActions? { registry.value(in: window()) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item === heatmapItem {
            item.title = Self.heatmapTitle(open: actions?.heatmap?.open ?? false)
            return actions?.heatmap != nil
        }
        guard let button = TransportButton(menuTag: item.representedObject) else { return true }
        return actions?.enabled.contains(button) ?? false
    }

    @objc private func press(_ sender: NSMenuItem) {
        guard let button = TransportButton(menuTag: sender.representedObject), let actions,
              actions.enabled.contains(button) else { return }
        actions.perform(button)
    }

    @objc private func toggleHeatmap(_ sender: NSMenuItem) {
        actions?.heatmap?.toggle()
    }
}

private extension TransportButton {
    /// Every case, so a menu item can carry its button as a plain tag.
    static let menuButtons = Array(allCases)

    var menuTag: Int { Self.menuButtons.firstIndex(of: self) ?? -1 }

    init?(menuTag: Any?) {
        guard let index = menuTag as? Int, Self.menuButtons.indices.contains(index) else { return nil }
        self = Self.menuButtons[index]
    }
}
