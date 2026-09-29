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
            PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true),
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: true, crossCheck: true),
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
            PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true),
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: false),
            PlannedRound(stage: .refine, round: 4, major: false),
            PlannedRound(stage: .refine, round: 5, major: true, crossCheck: true),
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
            PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true),
            PlannedRound(stage: .refine, round: 2, major: false),
            PlannedRound(stage: .refine, round: 3, major: false),
            PlannedRound(stage: .refine, round: 4, major: true, crossCheck: true),
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
            PlannedRound(stage: .refine, round: 4, major: true, crossCheck: true),
        ])
    }

    // MARK: - trim

    /// Runs `count` planned rounds onto `tape`, as the runner would.
    private func run(_ count: Int, _ tape: inout Tape, _ cfg: RoundConfig) {
        for _ in 0..<count {
            guard let round = TapePlanner.next(after: tape, config: cfg) else { return }
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, parent: tape.head?.id, stage: round.stage,
                                               round: round.round, major: round.major, createdAt: Date()))
        }
    }

    /// The rounds `tape` still plans to run from here, in order.
    private func remaining(_ tape: Tape, _ cfg: RoundConfig) -> [PlannedRound] {
        var scratch = tape
        scratch.roundInProgress = nil
        var rounds: [PlannedRound] = []
        while let round = TapePlanner.next(after: scratch, config: cfg) {
            rounds.append(round)
            scratch.checkpoints.append(Checkpoint(id: scratch.checkpoints.count + 1, stage: round.stage, round: round.round,
                                                  major: round.major, createdAt: Date()))
        }
        return rounds
    }

    func testTrimRemovesUnrunRoundsAndMovesTheMajorToTheNewLastRound() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults)) // refinementCap 3
        var tape = Tape()
        run(3, &tape, cfg) // draft, synthesis, refine 1
        TapePlanner.apply(.trim(.refine, by: 1), to: &tape, config: cfg)
        XCTAssertEqual(tape.extraRefinement, -1)
        XCTAssertEqual(remaining(tape, cfg).filter { $0.stage == .refine },
                       [PlannedRound(stage: .refine, round: 2, major: true, crossCheck: true)])
    }

    /// A trim can't take back work: the stage never plans fewer rounds than already landed plus
    /// the one in flight — trimming to exactly that ends the stage after the current round.
    func testTrimIsClampedToLandedRoundsPlusTheOneInFlight() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults)) // refinementCap 5
        var tape = Tape()
        run(3, &tape, cfg) // draft, synthesis, refine 1
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        TapePlanner.apply(.trim(.refine, by: 10), to: &tape, config: cfg)
        XCTAssertEqual(cfg.refinementCap + tape.extraRefinement, 2, "refine 1 landed, refine 2 is in flight")

        // The round in flight lands; the stage is over and the sequence moves on to Encode.
        tape.roundInProgress = nil
        run(1, &tape, cfg)
        XCTAssertEqual(tape.head?.round, 2)
        XCTAssertEqual(TapePlanner.next(after: tape, config: cfg), PlannedRound(stage: .encode, round: 0, major: true))
        XCTAssertEqual(TapePlanner.planned(stage: .refine, round: 2, tape: tape, config: cfg)?.major, true,
                       "the in-flight round is the stage's last, so its checkpoint is the major one")

        // Idempotent under a re-read: the same trim again (or another) removes nothing more.
        TapePlanner.apply(.trim(.refine, by: 1), to: &tape, config: cfg)
        XCTAssertEqual(cfg.refinementCap + tape.extraRefinement, 2)
    }

    func testTrimRefineToZeroBeforeItStartsSkipsTheStage() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var tape = Tape()
        run(1, &tape, cfg) // draft
        TapePlanner.apply(.trim(.refine, by: 3), to: &tape, config: cfg)
        XCTAssertEqual(remaining(tape, cfg).map(\.stage), [.synthesis, .encode, .polish, .polish])
        // + brings a round back.
        TapePlanner.apply(.extend(.refine, by: 1), to: &tape)
        XCTAssertEqual(remaining(tape, cfg).filter { $0.stage == .refine },
                       [PlannedRound(stage: .refine, round: 1, major: true, crossCheck: true)])
    }

    func testTrimPolishToZeroMovesOnToFreshEyesOrReview() throws {
        let full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        var tape = Tape()
        TapePlanner.apply(.trim(.polish, by: 6), to: &tape, config: full)
        XCTAssertEqual(remaining(tape, full).suffix(3).map(\.stage), [.encode, .freshEyes, .dedup])

        let feature = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var short = Tape()
        TapePlanner.apply(.trim(.polish, by: 2), to: &short, config: feature)
        XCTAssertEqual(remaining(short, feature).last, PlannedRound(stage: .encode, round: 0, major: true),
                       "no polish and no fresh eyes: encode is the last round before review")
    }

    func testTrimIgnoresOtherStagesAndAMissingConfig() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var tape = Tape()
        TapePlanner.apply(.trim(.encode, by: 1), to: &tape, config: cfg)
        TapePlanner.apply(.trim(.refine, by: 1), to: &tape)
        TapePlanner.apply(.trim(.refine, by: -2), to: &tape, config: cfg)
        XCTAssertEqual(tape.extraRefinement, 0)
        XCTAssertEqual(tape.extraPolish, 0)
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

    // MARK: - Cross-check flags (coverage spec §3)

    private func refineFlags(_ config: RoundConfig, extra: Int = 0) -> [Int: Bool] {
        let rounds = walk(config, extraRefinement: extra).rounds.filter { $0.stage == .refine }
        return Dictionary(uniqueKeysWithValues: rounds.map { ($0.round, $0.crossCheck) })
    }

    func testCrossCheckPolicies() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(refineFlags(cfg), [1: true, 2: false, 3: true])
        cfg.crossCheck = .every
        XCTAssertEqual(refineFlags(cfg), [1: true, 2: true, 3: true])
        cfg.crossCheck = .off
        XCTAssertEqual(refineFlags(cfg), [1: false, 2: false, 3: false])
        cfg.crossCheck = nil
        XCTAssertEqual(refineFlags(cfg), [1: false, 2: false, 3: false])
        cfg.crossCheck = .firstAndLast; cfg.refinementCap = 1
        XCTAssertEqual(refineFlags(cfg), [1: true])
    }

    /// Extend moves "last": the new last round cross-checks (spec §3), and the old last does not.
    func testExtendMovesTheLastCrossCheck() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(refineFlags(cfg, extra: 1), [1: true, 2: false, 3: false, 4: true])
        XCTAssertEqual(refineFlags(cfg, extra: -1), [1: true, 2: true])
    }

    /// A round already started keeps the flag it started with: `roundInProgress` is persisted
    /// (Review Focus 5). An extend landing mid-round flags the NEW last round too.
    func testExtendMidRoundKeepsTheRunningRoundsFlag() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var tape = walk(cfg).tape
        tape.checkpoints.removeAll { $0.stage == .refine && $0.round == 3 || [.encode, .polish].contains($0.stage) }
        let running = try XCTUnwrap(TapePlanner.next(after: tape, config: cfg))
        XCTAssertEqual(running.round, 3); XCTAssertTrue(running.crossCheck)
        tape.roundInProgress = running
        tape.extraRefinement = 1
        let data = try IntakeJSON.encoder.encode(tape)
        XCTAssertEqual(try IntakeJSON.decoder.decode(Tape.self, from: data).roundInProgress?.crossCheck, true)
        tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: .refine, round: 3, major: false, createdAt: Date()))
        XCTAssertEqual(TapePlanner.next(after: tape, config: cfg)?.crossCheck, true)
    }

    func testOldPlannedRoundDecodesWithoutCrossCheck() throws {
        let old = #"{"stage":"refine","round":2,"major":false}"#
        XCTAssertFalse(try IntakeJSON.decoder.decode(PlannedRound.self, from: Data(old.utf8)).crossCheck)
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

    /// Fresh eyes and dedup are seated by the polisher. Planned without one (a Sketch with the
    /// toggle on), the tape ran to encode and then paused on "no polisher" — a pause a
    /// `.shaping` intake can't act on, since its config is fixed once shaping starts.
    func testFreshEyesAndDedupSkippedWithNoPolisher() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        XCTAssertNil(cfg.polisher)
        cfg.freshEyesAndDedup = true
        let (rounds, _) = walk(cfg)
        XCTAssertEqual(rounds.last, PlannedRound(stage: .encode, round: 0, major: true))
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
        XCTAssertEqual(tape.pendingNotes.map(\.note), ["watch the schema", "and the fallback"])
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
