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
            .review: [.header, .clarifications, .stageBody, .actionBar],
            // Releasing has nothing to press and can't be discarded mid-write: no action bar.
            .releasing: [.header, .clarifications, .stageBody],
            .released: [.header, .clarifications, .stageBody, .actionBar],
            .partiallyReleased: [.header, .clarifications, .stageBody, .actionBar],
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
}
