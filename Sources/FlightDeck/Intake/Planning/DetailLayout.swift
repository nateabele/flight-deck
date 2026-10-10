import CoreGraphics
import IntakeKit

/// The intake detail pane as one calm document (spec §3, Direction D), decided without SwiftUI:
/// which parts show in each state, the trailing action's title, what the inspector hosts, and
/// where the control bar's Back goes. `IntakeDetailView` only lays these out, so what a state
/// looks like is pinned by `DetailLayoutTests` rather than by a picture.
enum DetailLayout {
    /// The document's parts, top to bottom. `liveCard` is the running stage's card (triage's
    /// seat, or shaping's control bar, board and seats); `stageBody` is every other state's body
    /// in the same slot — a form, a choice, a summary — with nothing ticking.
    enum Section: Equatable { case header, clarifications, liveCard, stageBody, plan, actionBar }

    /// The inspector's two modes, chosen by the human with the segmented control in its header,
    /// ⌥⌘1/⌥⌘2 or View ▸ Inspector — never by focus. It used to switch on its own: the notes rail
    /// while the plan text had focus, the selected agent while one was selected, the Rounds
    /// editor otherwise, so a click into the plan to read it took the editor away mid-edit and the
    /// column read as two unrelated panels taking turns (the maintainer, 2026-10-09: "The sidebar is also
    /// for notes, which is confusing"). Remembered per plan (`IntakeService.inspectorMode`).
    enum InspectorMode: String, CaseIterable, Codable {
        case notes, rounds

        var title: String {
            switch self {
            case .notes: "Notes"
            case .rounds: "Rounds"
            }
        }

        var symbol: String {
            switch self {
            case .notes: "note.text"
            case .rounds: "person.2"
            }
        }

        /// The digit of its ⌥⌘ chord, in segment order — Xcode's inspector-tab chords.
        var shortcut: Character {
            switch self {
            case .notes: "1"
            case .rounds: "2"
            }
        }
    }

    /// What the trailing inspector shows (spec §3), decided from the mode the human chose.
    /// `seat` is the Rounds mode drilled in on an agent of the running round; `roundsRecord` the
    /// config that planned a plan past shaping, read-only.
    enum InspectorContent: Equatable { case roundsEditor, roundsRecord, seat, notesRail, empty(Placeholder) }

    /// An empty state: what the mode would show, and why it shows nothing yet.
    struct Placeholder: Equatable {
        let title: String
        let message: String

        static let noRounds = Placeholder(title: "No Rounds",
                                          message: "Rounds are set up once triage recommends a fidelity with planning rounds.")
        static let notesBeforePlanning = Placeholder(title: "No Notes",
                                                     message: "Notes go on the plan once planning starts. Select text in the plan to note on it.")
        static let notesSingleTask = Placeholder(title: "No Notes",
                                                 message: "A single task is written straight from triage, with no plan to note on.")
        static let notesFinal = Placeholder(title: "Plan Is Final",
                                            message: "Notes reach the plan while its rounds run. The final plan takes none.")
    }

    static func sections(for state: IntakeState, hasClarifications: Bool) -> [Section] {
        var out: [Section] = [.header]
        if hasClarifications { out.append(.clarifications) }
        switch state {
        case .triaging: out.append(.liveCard)
        case .shaping: out += [.liveCard, .plan]
        // The plan the tasks were written from stays readable under the review's summary.
        case .review, .releasing, .released, .partiallyReleased: out += [.stageBody, .plan]
        case .needsAnswers, .awaitingChoice, .parked, .failed, .interrupted:
            out.append(.stageBody)
        // Never listed (`intakes(forProject:)` filters it out); the arm exists for exhaustiveness.
        case .discarded: break
        }
        if primaryAction(for: state, preset: .bead) != nil || closeAction(for: state) != nil { out.append(.actionBar) }
        return out
    }

    /// The trailing default per state (spec §3.1), title-cased per the HIG. Nil where there is
    /// nothing to press: triage and release are running, and shaping's transport is its primary.
    ///
    /// Takes the chosen preset, not the tape the plan sketched: Continue vs Start Planning is the
    /// only title that varies, and it varies on whether the preset runs planning rounds.
    static func primaryAction(for state: IntakeState, preset: Preset) -> String? {
        switch state {
        case .needsAnswers: "Send Answers"
        case .awaitingChoice, .parked: preset == .bead ? "Continue" : "Start Planning"
        case .review: "Review Tasks…"
        // Nothing is thrown away — `discard` only hides it; its `ReleaseRecord` stays in
        // `intake.json` — so the way off the list is the primary, not a destructive Discard.
        case .released, .partiallyReleased: "Dismiss"
        case .failed, .interrupted: "Retry"
        case .triaging, .shaping, .releasing, .discarded: nil
        }
    }

    /// How the keyboard reaches the primary. Return everywhere it is safe; ⌘↩ for Send Answers,
    /// whose multi-line fields own Return; and none for a partial release, whose Dismiss would
    /// otherwise put a half-written release out of sight on a stray Return.
    enum PrimaryKey: Equatable { case defaultAction, commandReturn, none }

    static func primaryKey(for state: IntakeState) -> PrimaryKey {
        switch state {
        case .needsAnswers: .commandReturn
        case .partiallyReleased: .none
        default: .defaultAction
        }
    }

    /// From review on, the plan section shows the final plan, read-only: the change set was
    /// encoded from it, so an edit there would change nothing that gets written.
    static func planIsFinal(for state: IntakeState) -> Bool {
        switch state {
        case .review, .releasing, .released, .partiallyReleased: true
        default: false
        }
    }

    static func planTitle(for state: IntakeState) -> String { planIsFinal(for: state) ? "Final plan" : "Plan" }

    /// The review body's count of what will be written: "3 new tasks · 2 edits · 1 dependency".
    /// A follow-up is a new task (of an existing one); a reopen is an edit to one.
    static func reviewCounts(_ ops: [ChangeOp]) -> String {
        let counts = ReleaseCounts(ops)
        return counts.isEmpty ? "Nothing to write" : counts.phrase
    }

    /// Whether the graph moved since triage, as the review sheet will ask about it (`drift` is
    /// parallel to the change set's ops; `confirmed`/`dropped` are the intake's own choices).
    static func driftLine(_ drift: [OpDrift], confirmed: Set<Int>, dropped: Set<Int>) -> String {
        var open = 0, kept = 0, left = 0, gone = 0
        for (i, d) in drift.enumerated() {
            switch d {
            case .holds: break
            case .impossible: gone += 1
            case .drifted:
                if dropped.contains(i) { left += 1 } else if confirmed.contains(i) { kept += 1 } else { open += 1 }
            }
        }
        let tasks = { (n: Int) in n == 1 ? "1 task" : "\(n) tasks" }
        var lines: [String] = []
        if open > 0 { lines.append("\(tasks(open)) changed since triage — confirm or drop them in the review.") }
        if kept > 0 { lines.append("\(tasks(kept)) changed since triage, already confirmed.") }
        if left > 0 { lines.append("\(tasks(left)) changed since triage, already dropped.") }
        if gone > 0 {
            lines.append(gone == 1 ? "1 change can't be written: its task no longer exists."
                                   : "\(gone) changes can't be written: their tasks no longer exist.")
        }
        return lines.isEmpty ? "Nothing has changed in the task graph since triage." : lines.joined(separator: " ")
    }

    /// The destructive, confirmed Discard on the leading edge — every state that can still be
    /// thrown away. Nil for `.releasing` (`IntakeService.discard` refuses it: tasks half-written,
    /// no record yet), for released intakes (Dismiss is their primary) and for `.discarded`.
    static func closeAction(for state: IntakeState) -> String? {
        switch state {
        case .triaging, .needsAnswers, .awaitingChoice, .shaping, .parked, .review, .failed, .interrupted: "Discard"
        case .released, .partiallyReleased, .releasing, .discarded: nil
        }
    }

    /// The modes a plan offers, in segment order. A single task runs no rounds, so it has
    /// nothing for a Rounds mode to configure and offers Notes alone. `preset` is nil until a
    /// fidelity is in view (triage): both modes, each with its empty state, so the column doesn't
    /// lose a segment and grow it back as triage finishes.
    static func inspectorModes(preset: Preset?) -> [InspectorMode] {
        preset == .bead ? [.notes] : [.notes, .rounds]
    }

    /// The mode shown: the one last chosen for this plan while the plan still offers it, else
    /// Rounds where there are rounds — the editor was the inspector's resting state, and a plan
    /// waiting on its fidelity opens onto the one thing there is to change in it — else Notes.
    static func inspectorMode(stored: InspectorMode?, preset: Preset?) -> InspectorMode {
        let modes = inspectorModes(preset: preset)
        if let stored, modes.contains(stored) { return stored }
        return modes.contains(.rounds) ? .rounds : .notes
    }

    /// What `mode` hosts in `state`. Rounds: the editor while a fidelity is being chosen and
    /// while shaping — editable between rounds, read-only while one runs (`roundsEditing`) —
    /// drilled in on the selected agent of the round in flight; from review on, the config that
    /// planned it. Notes: the rail while shaping, the one state with a plan to note on; an empty
    /// state elsewhere. `seatSelected` is false whenever no round is in flight: a selection left
    /// over from the last round has nothing to show, and must not hide the editor once the run
    /// pauses. A mode the plan doesn't offer reads as Notes.
    static func inspector(for state: IntakeState, preset: Preset?, mode: InspectorMode, seatSelected: Bool = false,
                          hasRoundConfig: Bool = false) -> InspectorContent {
        switch inspectorModes(preset: preset).contains(mode) ? mode : .notes {
        case .notes:
            if preset == .bead { return .empty(.notesSingleTask) }
            switch state {
            case .shaping: return .notesRail
            case .review, .releasing, .released, .partiallyReleased, .discarded: return .empty(.notesFinal)
            case .triaging, .needsAnswers, .awaitingChoice, .parked, .failed, .interrupted: return .empty(.notesBeforePlanning)
            }
        case .rounds:
            switch state {
            case .awaitingChoice, .parked: return .roundsEditor
            case .shaping: return seatSelected ? .seat : .roundsEditor
            case .review, .releasing, .released, .partiallyReleased, .failed, .interrupted, .discarded:
                return hasRoundConfig ? .roundsRecord : .empty(.noRounds)
            case .triaging, .needsAnswers: return .empty(.noRounds)
            }
        }
    }

    /// Whether the Rounds editor takes edits. Before shaping it edits the config `beginShaping`
    /// will start with. While shaping, only when nothing runs the tape — no live runner, no play
    /// still starting, and a status that isn't running: the runner reads the config once per
    /// start, so an edit landing under a live one would change nothing it runs, and would be
    /// silently undone in effect. `IntakeService.saveRoundConfig` refuses on the same rule.
    enum RoundsEditing: Equatable { case editable, readOnly }

    static func roundsEditing(state: IntakeState, status: RunnerStatus, runnerLive: Bool, starting: Bool) -> RoundsEditing {
        switch state {
        case .awaitingChoice, .parked: .editable
        case .shaping:
            switch status {
            case .paused, .stopped, .failed, .idle: runnerLive || starting ? .readOnly : .editable
            case .running, .reachedReview: .readOnly
            }
        case .triaging, .needsAnswers, .review, .releasing, .released, .partiallyReleased, .failed, .interrupted,
             .discarded:
            .readOnly
        }
    }

    /// Where the control bar's Back goes: the checkpoint before the one the plan viewer shows.
    /// Nil at the first checkpoint and for one not on the tape — the key dims rather than doing
    /// nothing. Navigation only: the engine has no rewind (`ControlBar.onBack`).
    static func previousCheckpoint(before shown: Int?, in tape: Tape) -> Int? {
        guard let shown, let index = tape.checkpoints.firstIndex(where: { $0.id == shown }), index > 0 else { return nil }
        return tape.checkpoints[index - 1].id
    }

    /// How far below the toolbar the pinned bar sits, so its rounded top corners clear the edge.
    static let pinnedInset: CGFloat = 8

    /// Whether the control bar and board pin under the toolbar: once the bar's top edge (in the
    /// document viewport's coordinates) has scrolled above where the pinned copy sits. At exactly
    /// `pinnedInset` the real bar is where the pinned one would be, so the hand-over is seamless
    /// both ways — a threshold anywhere else shows the bar jump by the difference.
    static func pinsBar(barTop: CGFloat?) -> Bool {
        guard let barTop else { return false }
        return barTop < pinnedInset
    }

    /// The gap between the pinned bar and the board under it — the card's own spacing.
    static let pinnedGap: CGFloat = 12

    /// How tall the pinned block draws, from the card's measured bar and board; nil before the
    /// first measurement. The heatmap is left out: the pinned copy of the board never carries it
    /// — a heatmap cell's jump to the plan pinned the block, and the opaque map in the pinned
    /// copy then covered the very section it had jumped to.
    static func pinnedBlockHeight(bar: CGFloat, board: CGFloat, heatmap: CGFloat) -> CGFloat? {
        guard bar > 0 else { return nil }
        return pinnedInset + bar + pinnedGap + max(0, board - heatmap) + 10
    }
}
