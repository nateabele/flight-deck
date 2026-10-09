import XCTest
import IntakeKit

/// `RoundParticipants` is the one answer to "who runs round k": the planner, the live seat rows,
/// the Rounds editor's timeline and the main view's round chips all read it. Pinned per policy ×
/// cap, and against the planner's own sequence, so the editor can never mark a cross-check round
/// the runner doesn't run.
final class RoundParticipantsTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")
    private let gemini = ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high")

    private func config(_ policy: CrossCheckPolicy?, cap: Int, crossReviewer: ModelChoice? = nil) -> RoundConfig {
        RoundConfig(drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)],
                    synthesizer: Slot(claude), reviewer: Slot(grok), integrator: claude, encoder: codex, polisher: gemini,
                    refinementCap: cap, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false,
                    crossReviewer: Slot(crossReviewer ?? gemini), crossCheck: policy)
    }

    func testCrossCheckRoundsForEveryPolicyAndCap() {
        let expected: [CrossCheckPolicy?: [Int: [Int]]] = [
            nil: [0: [], 1: [], 2: [], 3: [], 5: []],
            .off: [0: [], 1: [], 2: [], 3: [], 5: []],
            .firstAndLast: [0: [], 1: [1], 2: [1, 2], 3: [1, 3], 5: [1, 5]],
            .every: [0: [], 1: [1], 2: [1, 2], 3: [1, 2, 3], 5: [1, 2, 3, 4, 5]],
        ]
        for (policy, byCap) in expected {
            for (cap, rounds) in byCap {
                XCTAssertEqual(RoundParticipants.crossCheckRounds(of: cap, config: config(policy, cap: cap)), rounds,
                               "policy \(String(describing: policy)), cap \(cap)")
            }
        }
    }

    /// A same-family pairing can't cross-check anything, whatever the policy says.
    func testSameFamilyNeverCrossChecks() {
        for policy in CrossCheckPolicy.allCases {
            XCTAssertEqual(RoundParticipants.crossCheckRounds(of: 3, config: config(policy, cap: 3, crossReviewer: grok)), [])
        }
    }

    /// Out-of-range rounds are never cross-checks — a stray round index can't light a chip.
    func testOutOfRangeRoundIsNotACrossCheck() {
        let cfg = config(.every, cap: 3)
        XCTAssertFalse(RoundParticipants.crossChecks(round: 0, of: 3, config: cfg))
        XCTAssertFalse(RoundParticipants.crossChecks(round: 4, of: 3, config: cfg))
    }

    /// The planner's sequence marks exactly the rounds this function picks, for every policy and
    /// cap — the correspondence the editor's strip relies on.
    func testPlannerAgreesForEveryPolicyAndCap() {
        for policy in [nil] + CrossCheckPolicy.allCases.map(Optional.some) {
            for cap in 0...6 {
                let cfg = config(policy, cap: cap)
                let planned = TapePlanner.plannedRounds(config: cfg, tape: .empty)
                    .filter { $0.stage == .refine && $0.crossCheck }.map(\.round)
                XCTAssertEqual(planned, RoundParticipants.crossCheckRounds(of: cap, config: cfg),
                               "policy \(String(describing: policy)), cap \(cap)")
            }
        }
    }

    /// An extend moves "last": the tape's extra rounds count toward the total.
    func testExtendMovesTheLastCrossCheck() {
        var tape = Tape.empty
        tape.extraRefinement = 2
        let planned = TapePlanner.plannedRounds(config: config(.firstAndLast, cap: 3), tape: tape)
            .filter { $0.stage == .refine && $0.crossCheck }.map(\.round)
        XCTAssertEqual(planned, [1, 5])
    }

    func testParticipantsPerStage() {
        let cfg = config(.firstAndLast, cap: 3)
        func roles(_ stage: Stage, _ round: Int, cross: Bool = false) -> [String] {
            RoundParticipants.of(PlannedRound(stage: stage, round: round, major: false, crossCheck: cross), config: cfg).map(\.role)
        }
        XCTAssertEqual(roles(.draft, 0), ["drafter", "drafter"])
        XCTAssertEqual(RoundParticipants.of(PlannedRound(stage: .draft, round: 0, major: true), config: cfg).map(\.index), [0, 1])
        XCTAssertEqual(roles(.synthesis, 0), ["synthesizer", "integrator"])
        XCTAssertEqual(roles(.refine, 1, cross: true), ["reviewer", "crossReviewer", "integrator"])
        XCTAssertEqual(roles(.refine, 2), ["reviewer", "integrator"])
        XCTAssertEqual(roles(.encode, 0), ["encoder"])
        XCTAssertEqual(roles(.polish, 1), ["polisher"])
        XCTAssertEqual(roles(.dedup, 0), ["polisher"])
        let cross = RoundParticipants.of(PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true), config: cfg)
        XCTAssertEqual(cross.map { $0.slot?.choice.agent }, [.grok, .gemini, .claude])
    }
}
