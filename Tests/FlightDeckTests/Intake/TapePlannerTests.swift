import XCTest
import IntakeKit

final class TapePlannerTests: XCTestCase {
    private func checkpoint(id: Int = 1, stage: Stage = .draft, round: Int = 0, major: Bool) -> Checkpoint {
        Checkpoint(id: id, stage: stage, round: round, major: major, createdAt: Date())
    }

    /// Drives `TapePlanner.next` from an empty tape to release review, appending a checkpoint
    /// for each planned round exactly as the runner would. Returns the rounds in order plus
    /// the tape they leave behind, so a test can assert both the full sequence and that
    /// `next` returns nil (release review) right after it.
    private func walk(_ config: RoundConfig, extraRefinement: Int = 0, extraPolish: Int = 0) -> (rounds: [PlannedRound], tape: Tape) {
        var tape = Tape(extraRefinement: extraRefinement, extraPolish: extraPolish)
        var rounds: [PlannedRound] = []
        while let round = TapePlanner.next(after: tape, config: config) {
            rounds.append(round)
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, parent: tape.head?.id,
                                                stage: round.stage, round: round.round, major: round.major, createdAt: Date()))
        }
        return (rounds, tape)
    }

    // MARK: - Full sequences

    func testSketchSequence() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        let (rounds, tape) = walk(cfg)
        XCTAssertEqual(rounds, [
            PlannedRound(stage: .draft, round: 0, major: true),
            PlannedRound(stage: .refine, round: 1, major: false),
            PlannedRound(stage: .refine, round: 2, major: true),
            PlannedRound(stage: .encode, round: 0, major: true),
        ])
        XCTAssertNil(TapePlanner.next(after: tape, config: cfg))
    }

    func testFeaturePlanSequence() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        let (rounds, tape) = walk(cfg)
        XCTAssertEqual(rounds, [
            PlannedRound(stage: .draft, round: 0, major: true),
            PlannedRound(stage: .synthesis, round: 0, major: true),
            PlannedRound(stage: .refine, round: 1, major: false),
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: true),
            PlannedRound(stage: .encode, round: 0, major: true),
            PlannedRound(stage: .polish, round: 1, major: false),
            PlannedRound(stage: .polish, round: 2, major: true),
        ])
        XCTAssertNil(TapePlanner.next(after: tape, config: cfg))
    }

    func testFullPlanSequence() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        let (rounds, tape) = walk(cfg)
        XCTAssertEqual(rounds, [
            PlannedRound(stage: .draft, round: 0, major: true),
            PlannedRound(stage: .synthesis, round: 0, major: true),
            PlannedRound(stage: .refine, round: 1, major: false),
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: false),
            PlannedRound(stage: .refine, round: 4, major: false),
            PlannedRound(stage: .refine, round: 5, major: true),
            PlannedRound(stage: .encode, round: 0, major: true),
            PlannedRound(stage: .polish, round: 1, major: false),
            PlannedRound(stage: .polish, round: 2, major: false),
            PlannedRound(stage: .polish, round: 3, major: false),
            PlannedRound(stage: .polish, round: 4, major: false),
            PlannedRound(stage: .polish, round: 5, major: false),
            PlannedRound(stage: .polish, round: 6, major: true),
            PlannedRound(stage: .freshEyes, round: 0, major: false),
            PlannedRound(stage: .dedup, round: 0, major: true),
        ])
        XCTAssertNil(TapePlanner.next(after: tape, config: cfg))
    }

    // MARK: - extraRefinement / extraPolish

    func testExtraRefinementTurnsPreviousLastRoundMinorAndAddsANewMajorRound() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults)) // refinementCap 3
        let (rounds, _) = walk(cfg, extraRefinement: 1)
        let refineRounds = rounds.filter { $0.stage == .refine }
        XCTAssertEqual(refineRounds, [
            PlannedRound(stage: .refine, round: 1, major: false),
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: false),
            PlannedRound(stage: .refine, round: 4, major: true),
        ])
    }

    func testExtraPolishTurnsPreviousLastRoundMinorAndAddsANewMajorRound() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults)) // polishCap 2
        let (rounds, _) = walk(cfg, extraPolish: 1)
        let polishRounds = rounds.filter { $0.stage == .polish }
        XCTAssertEqual(polishRounds, [
            PlannedRound(stage: .polish, round: 1, major: false),
            PlannedRound(stage: .polish, round: 2, major: false),
            PlannedRound(stage: .polish, round: 3, major: true),
        ])
    }

    func testExtendRefineAfterEncodeAlreadyRanHasNoEffectOnPosition() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var tape = Tape()
        // Run the tape through draft, synth, r1, r2, r3(major), encode.
        for _ in 0..<6 {
            guard let round = TapePlanner.next(after: tape, config: cfg) else { break }
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: round.stage, round: round.round,
                                                major: round.major, createdAt: Date()))
        }
        XCTAssertEqual(tape.head?.stage, .encode)

        TapePlanner.apply(.extend(.refine, by: 1), to: &tape)
        XCTAssertEqual(tape.extraRefinement, 1)

        // The head is already past refine, so extending it does not send the sequence
        // backwards — the next round is still the first polish round, not another refine.
        XCTAssertEqual(TapePlanner.next(after: tape, config: cfg), PlannedRound(stage: .polish, round: 1, major: false))
    }

    func testExtendRefineWhileStillInRefineMovesMajorToNewLastRound() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults)) // refinementCap 3
        var tape = Tape()
        // Run through draft, synth, r1.
        for _ in 0..<3 {
            guard let round = TapePlanner.next(after: tape, config: cfg) else { break }
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: round.stage, round: round.round,
                                                major: round.major, createdAt: Date()))
        }
        XCTAssertEqual(tape.head?.stage, .refine)
        XCTAssertEqual(tape.head?.round, 1)

        TapePlanner.apply(.extend(.refine, by: 1), to: &tape)

        var refineRounds: [PlannedRound] = []
        while let round = TapePlanner.next(after: tape, config: cfg), round.stage == .refine {
            refineRounds.append(round)
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: round.stage, round: round.round,
                                                major: round.major, createdAt: Date()))
        }
        // Round 3 was the major checkpoint before the extend; after it, round 4 is.
        XCTAssertEqual(refineRounds, [
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: false),
            PlannedRound(stage: .refine, round: 4, major: true),
        ])
    }

    func testNextFailsSafeToReviewWhenHeadIsNoLongerInTheRebuiltSequence() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults)) // polishCap 2
        var tape = Tape()
        while let round = TapePlanner.next(after: tape, config: cfg) {
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: round.stage, round: round.round,
                                                major: round.major, createdAt: Date()))
        }
        XCTAssertEqual(tape.head?.stage, .polish)
        XCTAssertEqual(tape.head?.round, 2)

        // The config is edited out from under the in-progress tape — polishCap lowered below
        // the round the head already ran — so polish round 2 no longer appears anywhere in
        // the rebuilt sequence. There's no sound round to resume with, so `next` deliberately
        // fails safe to release review rather than guessing.
        cfg.polishCap = 1
        XCTAssertNil(TapePlanner.next(after: tape, config: cfg))
    }

    // MARK: - Skipped stages

    func testRefineSkippedWithNoReviewer() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        cfg.reviewer = nil
        let (rounds, _) = walk(cfg)
        XCTAssertFalse(rounds.contains { $0.stage == .refine })
    }

    func testRefineSkippedWhenCapTotalIsZero() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        cfg.refinementCap = 0
        let (rounds, _) = walk(cfg)
        XCTAssertFalse(rounds.contains { $0.stage == .refine })
    }

    func testPolishSkippedWithNoPolisher() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        cfg.polisher = nil
        let (rounds, _) = walk(cfg)
        XCTAssertFalse(rounds.contains { $0.stage == .polish })
    }

    func testFreshEyesAndDedupSkippedWhenFalse() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        let (rounds, _) = walk(cfg)
        XCTAssertFalse(rounds.contains { $0.stage == .freshEyes || $0.stage == .dedup })
    }

    // MARK: - satisfies

    func testSatisfiesNoneIsAlwaysTrue() {
        XCTAssertTrue(TapePlanner.satisfies(.none, after: checkpoint(major: false), nextRound: PlannedRound(stage: .refine, round: 1, major: false)))
        XCTAssertTrue(TapePlanner.satisfies(.none, after: checkpoint(major: true), nextRound: nil))
    }

    func testSatisfiesNextMinorIsAlwaysTrue() {
        XCTAssertTrue(TapePlanner.satisfies(.nextMinor, after: checkpoint(major: false), nextRound: PlannedRound(stage: .refine, round: 1, major: false)))
        XCTAssertTrue(TapePlanner.satisfies(.nextMinor, after: checkpoint(major: true), nextRound: nil))
    }

    func testSatisfiesNextMajorRequiresMajorCheckpoint() {
        XCTAssertFalse(TapePlanner.satisfies(.nextMajor, after: checkpoint(major: false), nextRound: PlannedRound(stage: .refine, round: 1, major: false)))
        XCTAssertTrue(TapePlanner.satisfies(.nextMajor, after: checkpoint(major: true), nextRound: PlannedRound(stage: .encode, round: 0, major: true)))
    }

    func testSatisfiesReviewRequiresNoNextRound() {
        XCTAssertFalse(TapePlanner.satisfies(.review, after: checkpoint(major: true), nextRound: PlannedRound(stage: .encode, round: 0, major: true)))
        XCTAssertTrue(TapePlanner.satisfies(.review, after: checkpoint(major: true), nextRound: nil))
    }

    // MARK: - apply

    func testApplyStepSetsNextMinorAndClearsTerminalStatus() {
        var tape = Tape(status: .paused)
        TapePlanner.apply(.step, to: &tape)
        XCTAssertEqual(tape.target, .nextMinor)
        XCTAssertEqual(tape.status, .idle)
    }

    func testApplyNextMajorSetsNextMajorAndClearsTerminalStatus() {
        var tape = Tape(status: .stopped)
        TapePlanner.apply(.nextMajor, to: &tape)
        XCTAssertEqual(tape.target, .nextMajor)
        XCTAssertEqual(tape.status, .idle)
    }

    func testApplyToReviewSetsReviewAndClearsTerminalStatus() {
        var tape = Tape(status: .failed)
        TapePlanner.apply(.toReview, to: &tape)
        XCTAssertEqual(tape.target, .review)
        XCTAssertEqual(tape.status, .idle)
    }

    func testApplyStepLeavesARunningStatusAlone() {
        var tape = Tape(status: .running)
        TapePlanner.apply(.step, to: &tape)
        XCTAssertEqual(tape.status, .running)
    }

    func testApplyPauseSetsTargetNoneAndLeavesStatus() {
        var tape = Tape(target: .review, status: .running)
        TapePlanner.apply(.pause, to: &tape)
        XCTAssertEqual(tape.target, .none)
        XCTAssertEqual(tape.status, .running)
    }

    func testApplyAnnotateAppends() {
        var tape = Tape()
        TapePlanner.apply(.annotate("watch the schema"), to: &tape)
        TapePlanner.apply(.annotate("and the fallback"), to: &tape)
        XCTAssertEqual(tape.pendingAnnotations, ["watch the schema", "and the fallback"])
    }

    func testApplyExtendRefineAddsToExtraRefinement() {
        var tape = Tape()
        TapePlanner.apply(.extend(.refine, by: 2), to: &tape)
        XCTAssertEqual(tape.extraRefinement, 2)
        XCTAssertEqual(tape.extraPolish, 0)
    }

    func testApplyExtendPolishAddsToExtraPolish() {
        var tape = Tape()
        TapePlanner.apply(.extend(.polish, by: 3), to: &tape)
        XCTAssertEqual(tape.extraPolish, 3)
        XCTAssertEqual(tape.extraRefinement, 0)
    }

    func testApplyExtendOtherStagesIsIgnored() {
        var tape = Tape()
        TapePlanner.apply(.extend(.draft, by: 1), to: &tape)
        TapePlanner.apply(.extend(.encode, by: 1), to: &tape)
        XCTAssertEqual(tape.extraRefinement, 0)
        XCTAssertEqual(tape.extraPolish, 0)
    }

    func testApplyStopIsANoOp() {
        var tape = Tape(target: .nextMajor, status: .running)
        TapePlanner.apply(.stop, to: &tape)
        XCTAssertEqual(tape.target, .nextMajor)
        XCTAssertEqual(tape.status, .running)
    }
}
