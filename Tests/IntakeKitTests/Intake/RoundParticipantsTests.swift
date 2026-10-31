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

    // MARK: - Rotations

    private func rotating(cross: ModelChoice? = nil, policy: CrossCheckPolicy? = nil) -> RoundConfig {
        var cfg = config(policy, cap: 5, crossReviewer: cross)
        cfg.reviewer = Slot(codex); cfg.integrator = claude; cfg.polisher = claude
        cfg.reviewers = [Slot(codex, fallback: claude), Slot(claude, fallback: codex)]
        cfg.integrators = [claude, codex]
        cfg.polishers = [claude, gemini, codex]
        return cfg
    }

    private func agents(_ stage: Stage, rotation: Int, role: String, _ cfg: RoundConfig) -> AgentID? {
        let round = PlannedRound(stage: stage, round: 0, major: false, rotation: rotation)
        return RoundParticipants.of(round, config: cfg).first { $0.role == role }?.slot?.choice.agent
    }

    /// Refine round k runs entry (k-1) mod n of the reviewer and integrator rotations.
    func testRefineRoundsTakeTheirRotationEntry() {
        let cfg = rotating()
        let rounds = TapePlanner.plannedRounds(config: cfg, tape: .empty).filter { $0.stage == .refine }
        XCTAssertEqual(rounds.map { RoundParticipants.of($0, config: cfg).first { $0.role == "reviewer" }?.slot?.choice.agent },
                       [.codex, .claude, .codex, .claude, .codex])
        XCTAssertEqual(rounds.map { RoundParticipants.of($0, config: cfg).first { $0.role == "integrator" }?.slot?.choice.agent },
                       [.claude, .codex, .claude, .codex, .claude])
        XCTAssertEqual(RoundParticipants.of(rounds[1], config: cfg).first { $0.role == "reviewer" }?.slot?.fallback?.agent, .codex)
    }

    /// Polish 1...M are entries 0...M-1; fresh eyes is M and dedup M+1; synthesis keeps the first integrator.
    func testPolishStageWalksThePolishersRotation() {
        let cfg = rotating()
        let polish = TapePlanner.plannedRounds(config: cfg, tape: .empty).filter { [.polish, .freshEyes, .dedup].contains($0.stage) }
        XCTAssertEqual(polish.count, 4)
        XCTAssertEqual(polish.map { RoundParticipants.of($0, config: cfg).first!.slot?.choice.agent }, [.claude, .gemini, .codex, .claude])
        XCTAssertEqual(agents(.synthesis, rotation: 0, role: "integrator", cfg), .claude)
        XCTAssertEqual(agents(.polish, rotation: 4, role: "polisher", cfg), .gemini)
    }

    /// A role with no rotation is the same agent every round.
    func testNoRotationIsTheSingleAgentEveryRound() {
        var cfg = rotating()
        cfg.reviewers = nil; cfg.integrators = nil; cfg.polishers = nil
        for k in 0..<7 {
            XCTAssertEqual(agents(.refine, rotation: k, role: "reviewer", cfg), .codex)
            XCTAssertEqual(agents(.refine, rotation: k, role: "integrator", cfg), .claude)
            XCTAssertEqual(agents(.polish, rotation: k, role: "polisher", cfg), .claude)
        }
    }

    /// A round whose reviewer is the cross-reviewer's own family cross-checks against the first other
    /// family in the reviewer rotation instead, so the rounds the policy marks still cross-check with
    /// two families; the planner, the participants and the engine's accessor agree.
    func testARotatingReviewerNeverCrossChecksAgainstItsOwnFamily() {
        let cfg = rotating(cross: claude, policy: .every)
        XCTAssertEqual(RoundParticipants.crossCheckRounds(of: 5, config: cfg), [1, 2, 3, 4, 5])
        let planned = TapePlanner.plannedRounds(config: cfg, tape: .empty).filter { $0.stage == .refine }
        XCTAssertEqual(planned.filter(\.crossCheck).map(\.round), [1, 2, 3, 4, 5])
        for round in planned {
            let seats = RoundParticipants.of(round, config: cfg)
            XCTAssertEqual(seats.map(\.role), ["reviewer", "crossReviewer", "integrator"])
            XCTAssertNotEqual(seats[0].slot?.choice.agent, seats[1].slot?.choice.agent, "refine \(round.round)")
            XCTAssertEqual(seats[1].slot, cfg.crossReviewer(rotation: round.rotation))
        }
        XCTAssertEqual(cfg.crossReviewer(rotation: 0)?.choice.agent, .claude)
        XCTAssertEqual(cfg.crossReviewer(rotation: 1)?.choice.agent, .codex)
        XCTAssertNil(cfg.crossReviewer(rotation: 1)?.fallback)
        // Another family cross-checks every round as configured.
        let gem = rotating(cross: gemini, policy: .every)
        XCTAssertEqual(RoundParticipants.crossCheckRounds(of: 5, config: gem), [1, 2, 3, 4, 5])
        XCTAssertEqual(gem.crossReviewer(rotation: 1)?.choice.agent, .gemini)
        // Only one family in the whole rotation: nothing to cross-check with.
        var same = cfg
        same.reviewers = nil; same.reviewer = Slot(claude)
        XCTAssertEqual(RoundParticipants.crossCheckRounds(of: 5, config: same), [])
        XCTAssertFalse(same.crossChecks)
    }
}
