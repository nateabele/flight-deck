import IntakeKit
import XCTest
@testable import FlightDeck

/// What the Rounds editor may still change once shaping has started (`ShapingEdit`): which
/// agents already ran, how a cap edit folds into the tape's extend/trim counter, and the
/// refusals the service applies to a config that changes what already ran.
final class ShapingEditTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")

    private var config: RoundConfig { PresetExpansion.config(for: .featurePlan, available: .defaults)! }

    private func tape(_ stages: [(Stage, Int)], extraRefinement: Int = 0, extraPolish: Int = 0) -> Tape {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let checkpoints = stages.enumerated().map { i, s in
            Checkpoint(id: i + 1, stage: s.0, round: s.1, major: false, createdAt: at)
        }
        return Tape(checkpoints: checkpoints, status: .paused, extraRefinement: extraRefinement, extraPolish: extraPolish)
    }

    // MARK: Which agents already ran

    func testNothingIsLockedBeforeTheFirstRoundLands() {
        let edit = ShapingEdit(tape: tape([]))
        XCTAssertTrue(edit.doneStages.isEmpty)
        XCTAssertFalse(edit.isLocked(.drafter(0)))
        XCTAssertFalse(edit.refineDone)
        XCTAssertFalse(edit.polishDone)
    }

    /// A stop in the middle of the draft writes no checkpoint, so the drafters run again and can
    /// still change.
    func testDraftersLockOnlyOnceTheDraftCheckpointExists() {
        var stopped = tape([])
        stopped.status = .stopped
        XCTAssertFalse(ShapingEdit(tape: stopped).isLocked(.drafter(0)))
        let edit = ShapingEdit(tape: tape([(.draft, 0)]))
        XCTAssertEqual(edit.doneStages, [.draft])
        XCTAssertTrue(edit.isLocked(.drafter(0)))
        XCTAssertTrue(edit.isLocked(.drafter(7)), "every drafter ran in the one draft round")
        XCTAssertFalse(edit.isLocked(.synthesizer))
        XCTAssertFalse(edit.isLocked(.reviewer))
    }

    func testSynthesizerLocksAfterSynthesisAndTheReviewersStayOpenThroughRefine() {
        let edit = ShapingEdit(tape: tape([(.draft, 0), (.synthesis, 0), (.refine, 1)]))
        XCTAssertTrue(edit.isLocked(.drafter(0)))
        XCTAssertTrue(edit.isLocked(.synthesizer))
        // Refine can still run more rounds (its cap sizes it), so its agents are not done.
        for open: SlotKeyPath in [.reviewer, .crossReviewer, .integrator, .encoder, .polisher] {
            XCTAssertFalse(edit.isLocked(open), "\(open)")
        }
        XCTAssertFalse(edit.refineDone)
    }

    /// Refine's last planned round having run is not the end of refine: a raised cap (or +)
    /// adds rounds to it. It is over once a later stage has run.
    func testRefineIsDoneOnlyOnceALaterStageRan() {
        XCTAssertFalse(ShapingEdit(tape: tape([(.draft, 0), (.refine, 1), (.refine, 2), (.refine, 3)])).refineDone)
        let edit = ShapingEdit(tape: tape([(.draft, 0), (.refine, 1), (.encode, 0)]))
        XCTAssertTrue(edit.refineDone)
        for done: SlotKeyPath in [.reviewer, .crossReviewer, .integrator, .encoder] {
            XCTAssertTrue(edit.isLocked(done), "\(done)")
        }
        XCTAssertFalse(edit.isLocked(.polisher))
        XCTAssertFalse(edit.polishDone)
    }

    /// The polisher seats polish, fresh eyes and dedup, so it stays open until all three ran.
    func testThePolisherStaysOpenUntilItsLastStageRan() {
        let afterFreshEyes = ShapingEdit(tape: tape([(.draft, 0), (.encode, 0), (.polish, 1), (.freshEyes, 0)]))
        XCTAssertTrue(afterFreshEyes.polishDone)
        XCTAssertTrue(afterFreshEyes.freshEyesDone)
        XCTAssertFalse(afterFreshEyes.isLocked(.polisher), "dedup still runs on the polisher's agent")
        XCTAssertTrue(ShapingEdit(tape: tape([(.draft, 0), (.encode, 0), (.freshEyes, 0), (.dedup, 0)])).isLocked(.polisher))
    }

    // MARK: Caps against the extend/trim counter

    /// The editor shows and edits the rounds the stage will run — the cap plus the tape's
    /// extend/trim counter — and saves the cap that gives that total, leaving the counter alone.
    /// A total of 5 over a + already pressed once (extra 1) saves cap 4, so the planner runs 5,
    /// not 6: the + is not applied twice.
    func testATotalEditSavesTheCapThatGivesItAndLeavesTheCounterAlone() {
        let edit = ShapingEdit(tape: tape([(.draft, 0), (.refine, 1)], extraRefinement: 1))
        XCTAssertEqual(edit.refinementTotal(config), 4, "cap 3 + one extend")
        let saved = edit.settingRefinementTotal(config, to: 5)
        XCTAssertEqual(saved.refinementCap, 4)
        XCTAssertTrue(saved.customized)
        XCTAssertEqual(ShapingEdit(tape: tape([(.draft, 0), (.refine, 1)], extraRefinement: 1)).refinementTotal(saved), 5)
        let planned = TapePlanner.upcoming(after: tape([(.draft, 0), (.refine, 1)], extraRefinement: 1), config: saved)
        XCTAssertEqual(planned.filter { $0.stage == .refine }.map(\.round), [2, 3, 4, 5])
    }

    /// A trim leaves the counter negative; the total still reads as what will run.
    func testATrimmedStageReadsItsTrimmedTotal() {
        let edit = ShapingEdit(tape: tape([(.draft, 0)], extraPolish: -1))
        XCTAssertEqual(edit.polishTotal(config), 1, "cap 2, trimmed once")
        XCTAssertEqual(edit.settingPolishTotal(config, to: 3).polishCap, 4)
    }

    /// Never below the rounds already run (the head would fall out of the planned sequence, and
    /// the planner fails safe to review), and never so low the cap would go negative.
    func testTheTotalNeverDropsBelowTheRoundsRunOrBelowTheExtends() {
        let ran = ShapingEdit(tape: tape([(.draft, 0), (.refine, 1), (.refine, 2)]))
        XCTAssertEqual(ran.refinementFloor, 2)
        XCTAssertEqual(ran.settingRefinementTotal(config, to: 0).refinementCap, 2)
        let extended = ShapingEdit(tape: tape([(.draft, 0)], extraRefinement: 2))
        XCTAssertEqual(extended.refinementFloor, 2)
        XCTAssertEqual(extended.settingRefinementTotal(config, to: 1).refinementCap, 0)
    }

    // MARK: Refusals

    func testChangingTheReviewerAfterTheDraftIsAccepted() {
        let edit = ShapingEdit(tape: tape([(.draft, 0), (.synthesis, 0)]))
        var edited = config
        edited.reviewer = Slot(grok)
        edited.polishCap = 4
        edited.defaultPlay = .step
        XCTAssertNil(edit.refusal(from: config, to: edited))
    }

    func testChangingAnAgentWhoseStageRanIsRefused() {
        let edit = ShapingEdit(tape: tape([(.draft, 0), (.synthesis, 0)]))
        var drafter = config
        drafter.drafters[0] = Slot(grok)
        XCTAssertEqual(edit.refusal(from: config, to: drafter), "The drafter already ran, so it can't change.")
        var added = config
        added.drafters.append(Slot(codex))
        XCTAssertEqual(edit.refusal(from: config, to: added), "The drafter already ran, so it can't change.")
        var synthesizer = config
        synthesizer.synthesizer = Slot(grok)
        XCTAssertEqual(edit.refusal(from: config, to: synthesizer), "The synthesizer already ran, so it can't change.")
    }

    func testACapForAStageThatRanIsRefused() {
        let edit = ShapingEdit(tape: tape([(.draft, 0), (.refine, 1), (.encode, 0)]))
        var edited = config
        edited.refinementCap = 5
        XCTAssertEqual(edit.refusal(from: config, to: edited), "Refinement already ran, so its rounds can't change.")
        var below = config
        below.refinementCap = 0
        XCTAssertEqual(ShapingEdit(tape: tape([(.draft, 0), (.refine, 1), (.refine, 2)])).refusal(from: config, to: below),
                       "Refinement has already run 2 rounds.")
    }

    func testAnUnchangedConfigIsNeverRefused() {
        XCTAssertNil(ShapingEdit(tape: tape([(.draft, 0), (.encode, 0), (.freshEyes, 0), (.dedup, 0)])).refusal(from: config, to: config))
    }
}
