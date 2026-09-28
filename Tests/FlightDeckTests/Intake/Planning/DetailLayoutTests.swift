import IntakeKit
import XCTest
@testable import FlightDeck

/// The detail pane's document (spec §3): which parts it shows in each state, the trailing
/// action's title, what the inspector hosts, and where Back goes. All pure, so the layout is
/// pinned here rather than by a picture.
final class DetailLayoutTests: XCTestCase {
    func testSectionsPerState() {
        typealias S = DetailLayout.Section
        let expected: [IntakeState: [S]] = [
            .triaging: [.header, .clarifications, .liveCard, .actionBar],
            .needsAnswers: [.header, .clarifications, .stageBody, .actionBar],
            .awaitingChoice: [.header, .clarifications, .stageBody, .actionBar],
            .parked: [.header, .clarifications, .stageBody, .actionBar],
            // Shaping is the only state with a plan to read and shape; its action bar is Discard
            // alone — the transport is its primary.
            .shaping: [.header, .clarifications, .liveCard, .plan, .actionBar],
            // From review on, the plan stays in the document, read-only: the final plan is what
            // the tasks were written from.
            .review: [.header, .clarifications, .stageBody, .plan, .actionBar],
            // Releasing has nothing to press and can't be discarded mid-write: no action bar.
            .releasing: [.header, .clarifications, .stageBody, .plan],
            .released: [.header, .clarifications, .stageBody, .plan, .actionBar],
            .partiallyReleased: [.header, .clarifications, .stageBody, .plan, .actionBar],
            .failed: [.header, .clarifications, .stageBody, .actionBar],
            .interrupted: [.header, .clarifications, .stageBody, .actionBar],
            .discarded: [.header, .clarifications],
        ]
        for (state, sections) in expected {
            XCTAssertEqual(DetailLayout.sections(for: state, hasClarifications: true), sections, "\(state)")
            XCTAssertEqual(DetailLayout.sections(for: state, hasClarifications: false),
                           sections.filter { $0 != .clarifications }, "\(state) without answered rounds")
        }
    }

    /// The trailing default per state (spec §3.1), title-cased. Triage and shaping have nothing
    /// to press — triage is running, shaping's transport is its primary — and a released intake's
    /// way off the list is its primary, Dismiss.
    func testPrimaryActionTitles() {
        let expected: [IntakeState: String?] = [
            .needsAnswers: "Send Answers", .awaitingChoice: "Continue", .parked: "Continue",
            .review: "Review Tasks…", .released: "Dismiss", .partiallyReleased: "Dismiss",
            .failed: "Retry", .interrupted: "Retry",
            .triaging: nil, .shaping: nil, .releasing: nil, .discarded: nil,
        ]
        for (state, title) in expected {
            XCTAssertEqual(DetailLayout.primaryAction(for: state, preset: .bead), title, "\(state)")
        }
        XCTAssertEqual(DetailLayout.primaryAction(for: .awaitingChoice, preset: .featurePlan), "Start Planning")
        XCTAssertEqual(DetailLayout.primaryAction(for: .parked, preset: .sketch), "Start Planning")
    }

    /// Discard stays leading and confirmed in every state that can still be thrown away. A
    /// released intake no longer carries a second Dismiss there: it is the primary now.
    func testCloseActionIsDiscardUntilReleased() {
        let expected: [IntakeState: String?] = [
            .triaging: "Discard", .needsAnswers: "Discard", .awaitingChoice: "Discard", .parked: "Discard",
            .shaping: "Discard", .review: "Discard", .failed: "Discard", .interrupted: "Discard",
            .released: nil, .partiallyReleased: nil, .releasing: nil, .discarded: nil,
        ]
        for (state, label) in expected {
            XCTAssertEqual(DetailLayout.closeAction(for: state), label, "\(state)")
        }
    }

    func testSummaryLine() throws {
        var config = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        let drafter = try XCTUnwrap(config.drafters.first)
        config.drafters = Array(repeating: drafter, count: 4)
        config.refinementCap = 5
        config.polishCap = 6
        config.customized = true
        XCTAssertEqual(RoundConfigEditor.summary(preset: .fullPlan, config: config),
                       "Full plan · 4 drafters · refine ×5 · polish ×6 · customized")

        // Rounds the planner would never run are never promised: no reviewer means no refine,
        // no polisher means no polish (`TapePlanner.sequence`).
        config.drafters = [drafter]
        config.reviewer = nil
        config.polisher = nil
        config.customized = false
        XCTAssertEqual(RoundConfigEditor.summary(preset: .sketch, config: config), "Sketch · 1 drafter")
    }

    func testInspectorHostsTheRoundsEditorOrTheSeat() {
        typealias I = DetailLayout.InspectorContent
        XCTAssertEqual(DetailLayout.inspector(for: .awaitingChoice, preset: .fullPlan), I.roundsEditor)
        XCTAssertEqual(DetailLayout.inspector(for: .parked, preset: .sketch), I.roundsEditor)
        // A single task runs no rounds, so there is nothing to configure.
        XCTAssertEqual(DetailLayout.inspector(for: .awaitingChoice, preset: .bead), I.nothing)
        XCTAssertEqual(DetailLayout.inspector(for: .shaping, preset: .fullPlan), I.seat)
        XCTAssertEqual(DetailLayout.inspector(for: .review, preset: .fullPlan), I.nothing)
    }

    /// Spec §7.3: the notes rail is the inspector while the plan is focused — only while
    /// shaping, the one state with a plan to annotate.
    func testInspectorHostsTheNotesRailWhileThePlanIsFocused() {
        typealias I = DetailLayout.InspectorContent
        XCTAssertEqual(DetailLayout.inspector(for: .shaping, preset: .fullPlan, planFocused: true), I.notesRail)
        XCTAssertEqual(DetailLayout.inspector(for: .shaping, preset: .fullPlan, planFocused: false), I.seat)
        XCTAssertEqual(DetailLayout.inspector(for: .awaitingChoice, preset: .fullPlan, planFocused: true), I.roundsEditor)
        XCTAssertEqual(DetailLayout.inspector(for: .review, preset: .fullPlan, planFocused: true), I.nothing)
    }

    /// Back is navigation in the plan viewer, never a tape command (the `ControlBar.onBack`
    /// contract): one checkpoint earlier than the one shown, and nowhere from the first.
    func testBackSelectsThePreviousCheckpoint() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t0, record: RoundRecord()),
            Checkpoint(id: 2, stage: .synthesis, round: 0, major: true, createdAt: t0, record: RoundRecord()),
            Checkpoint(id: 5, stage: .refine, round: 1, major: false, createdAt: t0, record: RoundRecord()),
        ])
        XCTAssertEqual(DetailLayout.previousCheckpoint(before: 5, in: tape), 2)
        XCTAssertEqual(DetailLayout.previousCheckpoint(before: 2, in: tape), 1)
        XCTAssertNil(DetailLayout.previousCheckpoint(before: 1, in: tape))
        XCTAssertNil(DetailLayout.previousCheckpoint(before: nil, in: tape))
        XCTAssertNil(DetailLayout.previousCheckpoint(before: 9, in: tape), "a checkpoint not on the tape")
        XCTAssertNil(DetailLayout.previousCheckpoint(before: nil, in: .empty))
    }

    /// The control bar and board pin once their top edge scrolls above where the pinned copy
    /// sits, and let go the moment it is back — so the hand-over never moves the bar.
    func testPinsOnceTheBarScrollsOut() {
        XCTAssertEqual(DetailLayout.pinnedInset, 8)
        XCTAssertFalse(DetailLayout.pinsBar(barTop: 120))
        XCTAssertFalse(DetailLayout.pinsBar(barTop: 8))
        XCTAssertTrue(DetailLayout.pinsBar(barTop: 7.5))
        XCTAssertTrue(DetailLayout.pinsBar(barTop: -300))
        XCTAssertFalse(DetailLayout.pinsBar(barTop: nil), "no bar on screen, nothing to pin")
    }

    /// The room the plan leaves for the pinned block is the bar and the board WITHOUT the
    /// heatmap: the pinned copy never carries it (a heatmap cell's jump pinned the block, and the
    /// opaque map then sat over the very section it had jumped to).
    func testPinnedBlockHeightLeavesTheHeatmapOut() {
        XCTAssertEqual(DetailLayout.pinnedBlockHeight(bar: 78, board: 400, heatmap: 220), 8 + 78 + 12 + 180 + 10)
        XCTAssertEqual(DetailLayout.pinnedBlockHeight(bar: 78, board: 180, heatmap: 0), 8 + 78 + 12 + 180 + 10)
        XCTAssertNil(DetailLayout.pinnedBlockHeight(bar: 0, board: 0, heatmap: 0), "not measured yet")
    }

    /// Shaping's plan is the live, editable one; from review on it is the final plan, read-only
    /// — edits after encode would change nothing that is written.
    func testPlanIsFinalFromReviewOn() {
        for state in [IntakeState.review, .releasing, .released, .partiallyReleased] {
            XCTAssertTrue(DetailLayout.planIsFinal(for: state), "\(state)")
            XCTAssertEqual(DetailLayout.planTitle(for: state), "Final plan")
        }
        XCTAssertFalse(DetailLayout.planIsFinal(for: .shaping))
        XCTAssertEqual(DetailLayout.planTitle(for: .shaping), "Plan")
    }

    /// Return presses the primary everywhere except where it would hide trouble: a partial
    /// release's Dismiss must be clicked, not taken by a stray Return. Send Answers is ⌘↩,
    /// since Return belongs to the multi-line answers.
    func testPrimaryKey() {
        XCTAssertEqual(DetailLayout.primaryKey(for: .needsAnswers), .commandReturn)
        XCTAssertEqual(DetailLayout.primaryKey(for: .partiallyReleased), DetailLayout.PrimaryKey.none)
        for state in [IntakeState.awaitingChoice, .parked, .review, .released, .failed, .interrupted] {
            XCTAssertEqual(DetailLayout.primaryKey(for: state), .defaultAction, "\(state)")
        }
    }

    /// The review body's summary: what will be written, in tasks, never the store's own word.
    func testReviewCounts() {
        let pre = Precondition(status: "open", assignee: nil)
        let ops: [ChangeOp] = [
            .createBead(NewBead(tempId: "a", title: "A", description: "")),
            .createBead(NewBead(tempId: "b", title: "B", description: "")),
            .followUp(tempId: "c", of: "fd-1", title: "C", description: "", pre: pre),
            .editBead(id: "fd-2", set: FieldSet(title: "x"), pre: pre, delivery: nil),
            .reopen(id: "fd-3", reason: "r", pre: pre),
            .addEdge(from: .new("a"), to: .new("b"), kind: .blocks),
        ]
        XCTAssertEqual(DetailLayout.reviewCounts(ops), "3 new tasks · 2 edits · 1 dependency")
        XCTAssertEqual(DetailLayout.reviewCounts([ops[3]]), "1 edit")
        XCTAssertEqual(DetailLayout.reviewCounts([]), "Nothing to write")
    }

    /// Drift since triage, as the review sheet will ask about it.
    func testDriftLine() {
        let drifted = OpDrift.drifted(reason: "status changed", suggested: nil)
        XCTAssertEqual(DetailLayout.driftLine([.holds, .holds], confirmed: [], dropped: []),
                       "Nothing has changed in the task graph since triage.")
        XCTAssertEqual(DetailLayout.driftLine([drifted, .holds, drifted], confirmed: [], dropped: []),
                       "2 tasks changed since triage — confirm or drop them in the review.")
        XCTAssertEqual(DetailLayout.driftLine([drifted, .holds], confirmed: [0], dropped: []),
                       "1 task changed since triage, already confirmed.")
        XCTAssertEqual(DetailLayout.driftLine([.impossible(reason: "gone"), .holds], confirmed: [], dropped: []),
                       "1 change can't be written: its task no longer exists.")
    }

    /// A wheel over the pinned block scrolls the document it covers; a sideways one is the
    /// board's tape; anything off the block is left to whatever is under it.
    func testWheelOverThePinnedBlockGoesToTheDocument() {
        XCTAssertTrue(WheelRouting.toDocument(overBlock: true, deltaX: 0, deltaY: -12))
        XCTAssertTrue(WheelRouting.toDocument(overBlock: true, deltaX: 2, deltaY: 9))
        XCTAssertTrue(WheelRouting.toDocument(overBlock: true, deltaX: 0, deltaY: 0), "a gesture's end reaches the document too")
        XCTAssertFalse(WheelRouting.toDocument(overBlock: true, deltaX: -14, deltaY: 3), "the tape scrolls sideways")
        XCTAssertFalse(WheelRouting.toDocument(overBlock: false, deltaX: 0, deltaY: -12))
    }

    /// The Run menu's value compares on the intake and the lit buttons, so republishing it on
    /// every render of the pane is no change at all; the closure is never compared.
    @MainActor
    func testPlanningActionsCompareOnIntakeAndEnabledButtons() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(PlanningActions(enabled: [.step, .stop], intakeID: a) { _ in },
                       PlanningActions(enabled: [.stop, .step], intakeID: a) { _ in XCTFail("never called") })
        XCTAssertNotEqual(PlanningActions(enabled: [.step], intakeID: a) { _ in }, PlanningActions(enabled: [.step], intakeID: b) { _ in })
        XCTAssertNotEqual(PlanningActions(enabled: [.step], intakeID: a) { _ in }, PlanningActions(enabled: [.pause], intakeID: a) { _ in })
    }

    /// The section heatmap is reachable from the Run menu (spec §14: every interaction by
    /// keyboard — it opened only from a click on the CONVERGENCE cell). The menu's item title
    /// and enablement follow the value, so whether a heatmap exists and whether it is open are
    /// part of it; the toggle closure is not.
    @MainActor
    func testPlanningActionsCarryTheHeatmapToggle() {
        let a = UUID()
        var toggled = 0
        var actions = PlanningActions(enabled: [.step], intakeID: a) { _ in }
        let none = actions
        actions.heatmap = PlanningActions.HeatmapToggle(open: false) { toggled += 1 }
        XCTAssertNotEqual(actions, none, "gaining a heatmap enables the menu item")
        var open = actions
        open.heatmap = PlanningActions.HeatmapToggle(open: true) { XCTFail("never called") }
        XCTAssertNotEqual(actions, open, "Show becomes Hide")
        XCTAssertEqual(actions, { var same = actions; same.heatmap = .init(open: false) {}; return same }())
        actions.heatmap?.toggle()
        XCTAssertEqual(toggled, 1)
        XCTAssertEqual(PlanningCommands.heatmapTitle(open: false), "Show Section Heatmap")
        XCTAssertEqual(PlanningCommands.heatmapTitle(open: true), "Hide Section Heatmap")
    }
}
