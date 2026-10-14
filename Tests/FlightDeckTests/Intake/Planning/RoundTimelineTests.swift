import XCTest
import IntakeKit
@testable import FlightDeck

/// The Rounds editor's timeline: one row per stage, one chip per round the tape plans, each
/// marked done or live off the tape — and the chips the main view draws for the same rounds
/// coming out identical, which is what makes the two visibly correspond.
final class RoundTimelineTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")
    private let gemini = ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func config(_ policy: CrossCheckPolicy = .firstAndLast, refine: Int = 3, polish: Int = 2,
                        freshEyes: Bool = false) -> RoundConfig {
        RoundConfig(drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)],
                    synthesizer: Slot(claude), reviewer: Slot(grok), integrator: claude, encoder: codex, polisher: gemini,
                    refinementCap: refine, polishCap: polish, freshEyesAndDedup: freshEyes, defaultPlay: .nextMajor,
                    customized: false, crossReviewer: Slot(gemini), crossCheck: policy)
    }

    private func names(_ row: RoundTimeline.Row) -> [String] { row.chips.map(\.name) }

    // MARK: - Stages and chips

    func testOneRowPerStageWithNumberedChips() {
        let rows = RoundTimeline.rows(config: config(), tape: nil)
        XCTAssertEqual(rows.map(\.section), [.draft, .synthesis, .refine, .encode, .polish])
        XCTAssertEqual(rows.map(names), [["Draft"], ["Synthesis"], ["Refine 1", "Refine 2", "Refine 3"], ["Encode"],
                                          ["Polish 1", "Polish 2"]])
        XCTAssertTrue(rows.flatMap(\.chips).allSatisfy { $0.progress == .planned })
    }

    /// Each chip's stack is exactly who runs that round, cross-check rounds included and marked.
    func testChipAgentsPerStageAndCrossCheckPolicy() {
        for (policy, crossed) in [(CrossCheckPolicy.off, [Int]()), (.firstAndLast, [1, 3]), (.every, [1, 2, 3])] {
            let rows = RoundTimeline.rows(config: config(policy), tape: nil)
            let refine = rows.first { $0.section == .refine }!.chips
            XCTAssertEqual(refine.filter(\.crossCheck).map(\.key.round), crossed, "\(policy)")
            for chip in refine {
                XCTAssertEqual(chip.agents.map(\.role), chip.crossCheck ? ["reviewer", "crossReviewer", "integrator"]
                                                                        : ["reviewer", "integrator"])
            }
        }
        let rows = RoundTimeline.rows(config: config(), tape: nil)
        XCTAssertEqual(rows[0].chips[0].agents.map(\.choice.agent), [.codex, .claude], "Draft = the drafters")
        XCTAssertEqual(rows[1].chips[0].agents.map(\.role), ["synthesizer", "integrator"],
                       "the engine runs the integrator in synthesis too")
        XCTAssertEqual(rows[3].chips[0].agents.map(\.choice.agent), [.codex], "Encode = the encoder")
        XCTAssertEqual(rows[4].chips.map { $0.agents.map(\.choice.agent) }, [[.gemini], [.gemini]], "Polish = the polisher")
    }

    /// Changing a cap or the policy changes the strip: nothing about it is cached.
    func testCapAndPolicyChangesReshapeTheStrip() {
        let five = RoundTimeline.rows(config: config(refine: 5, polish: 0), tape: nil)
        XCTAssertEqual(five.first { $0.section == .refine }!.chips.filter(\.crossCheck).map(\.key.round), [1, 5])
        XCTAssertEqual(five.first { $0.section == .polish }!.chips, [], "a polish cap of 0 leaves the row, empty")
        let zero = RoundTimeline.rows(config: config(refine: 0), tape: nil)
        XCTAssertEqual(zero.first { $0.section == .refine }?.chips, [], "Refine keeps its row: the integrator is set there")
    }

    func testFreshEyesAndDedupJoinThePolishRow() {
        let rows = RoundTimeline.rows(config: config(polish: 1, freshEyes: true), tape: nil)
        XCTAssertEqual(names(rows.last!), ["Polish 1", "Fresh eyes", "Dedup"])
    }

    func testNoSynthesizerOrPolisherDropsTheirRows() {
        var cfg = config()
        cfg.synthesizer = nil
        cfg.polisher = nil
        XCTAssertEqual(RoundTimeline.rows(config: cfg, tape: nil).map(\.section), [.draft, .refine, .encode])
    }

    // MARK: - Done and live

    private func ran(_ id: Int, _ stage: Stage, _ round: Int, slots: [SlotOutcome] = []) -> Checkpoint {
        Checkpoint(id: id, stage: stage, round: round, major: false, createdAt: t0, record: RoundRecord(slots: slots))
    }

    func testRoundsOnTheTapeAreDoneAndTheRunningOneIsLive() {
        var tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0), ran(3, .refine, 1)])
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        let chips = RoundTimeline.rows(config: config(), tape: tape).flatMap(\.chips)
        XCTAssertEqual(chips.filter { $0.progress == .done }.map(\.name), ["Draft", "Synthesis", "Refine 1"])
        XCTAssertEqual(chips.filter { $0.progress == .live }.map(\.name), ["Refine 2"])
        XCTAssertEqual(chips.first { $0.name == "Refine 1" }?.checkpointID, 3)
    }

    /// A start a play just asked for is live before the runner writes `roundInProgress`, as the
    /// live card's header already shows it.
    func testAPendingStartIsLive() {
        let tape = Tape(checkpoints: [ran(1, .draft, 0)])
        let chips = RoundTimeline.rows(config: config(), tape: tape,
                                       starting: PlannedRound(stage: .synthesis, round: 0, major: true)).flatMap(\.chips)
        XCTAssertEqual(chips.first { $0.name == "Synthesis" }?.progress, .live)
    }

    /// A done chip shows who actually ran — a fallback's model — and is a cross-check if a
    /// cross-check agent was among them, whatever the config says now.
    func testDoneChipShowsWhoRan() {
        let fellBack = SlotOutcome(role: "reviewer", used: codex, requested: grok, status: .substituted)
        let crossed = SlotOutcome(role: "crossReviewer", used: gemini, requested: gemini, status: .ok)
        let integ = SlotOutcome(role: "integrator", used: claude, requested: claude, status: .ok)
        let tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0),
                                      ran(3, .refine, 1, slots: [fellBack, crossed, integ])])
        let chip = RoundTimeline.rows(config: config(.off), tape: tape).flatMap(\.chips).first { $0.name == "Refine 1" }!
        XCTAssertEqual(chip.agents.map(\.choice.agent), [.codex, .gemini, .claude])
        XCTAssertTrue(chip.crossCheck)
    }

    /// An extend lengthens the strip; the running round keeps the cross-check it started with.
    func testExtendAndInFlightCrossCheck() {
        var tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0)])
        tape.extraRefinement = 1
        tape.roundInProgress = PlannedRound(stage: .refine, round: 1, major: false, crossCheck: false)
        let refine = RoundTimeline.rows(config: config(), tape: tape).first { $0.section == .refine }!.chips
        XCTAssertEqual(refine.map(\.name), ["Refine 1", "Refine 2", "Refine 3", "Refine 4"])
        XCTAssertEqual(refine.filter(\.crossCheck).map(\.key.round), [4], "round 1 started without one")
    }

    /// A checkpoint the rebuilt sequence no longer plans still shows: it ran.
    func testARoundNoLongerPlannedStillShowsDone() {
        let tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0), ran(3, .refine, 1), ran(4, .refine, 2)])
        let refine = RoundTimeline.rows(config: config(refine: 1), tape: tape).first { $0.section == .refine }!.chips
        XCTAssertEqual(refine.map(\.name), ["Refine 1", "Refine 2"])
        XCTAssertTrue(refine.allSatisfy { $0.progress == .done })
    }

    // MARK: - Correspondence with the main view

    /// The main view's round cards and the inspector's chips are the same values: a card's chip
    /// is the row's chip for that round, field for field.
    func testMainCardChipsEqualTheInspectorChips() {
        let crossed = SlotOutcome(role: "crossReviewer", used: gemini, requested: gemini, status: .ok)
        let reviewer = SlotOutcome(role: "reviewer", used: grok, requested: grok, status: .ok)
        var tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0), ran(3, .refine, 1, slots: [reviewer, crossed])])
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        var intake = Intake(projectPath: "/tmp/p", intent: "x")
        intake.roundConfig = config()
        let cards = ShapingModel(intake: intake, tape: tape).roundCards
        let chips = RoundTimeline.rows(config: config(), tape: tape).flatMap(\.chips)
        for card in cards {
            XCTAssertEqual(card.chip, chips.first { $0.checkpointID == card.checkpointID }, card.name)
        }
        XCTAssertEqual(RoundTimeline.live(tape: tape, starting: nil, config: config()), chips.first { $0.progress == .live })
    }

    // MARK: - Selection

    func testDefaultSectionIsTheLiveOrNextStage() {
        var tape = Tape(checkpoints: [ran(1, .draft, 0)])
        XCTAssertEqual(RoundTimeline.defaultSection(RoundTimeline.rows(config: config(), tape: nil)), .draft)
        XCTAssertEqual(RoundTimeline.defaultSection(RoundTimeline.rows(config: config(), tape: tape)), .synthesis)
        tape.checkpoints.append(ran(2, .synthesis, 0))
        tape.roundInProgress = PlannedRound(stage: .refine, round: 1, major: false)
        XCTAssertEqual(RoundTimeline.defaultSection(RoundTimeline.rows(config: config(), tape: tape)), .refine)
    }

    func testSelectingAChipTogglesAndRevealsItsStage() {
        let key = RoundKey(stage: .refine, round: 2)
        let picked = RoundTimeline.select(nil, chip: key)
        XCTAssertEqual(picked, RoundTimeline.Selection(section: .refine, round: key))
        XCTAssertEqual(RoundTimeline.select(picked, chip: key), RoundTimeline.Selection(section: .refine, round: nil))
        XCTAssertEqual(RoundTimeline.select(picked, chip: RoundKey(stage: .polish, round: 1)).section, .polish)
        XCTAssertEqual(RoundTimeline.Selection.round(RoundKey(stage: .dedup, round: 0)).section, .polish)
    }

    /// Picking a chip in the inspector moves the main view to that round only if there is one
    /// to show: a done round's checkpoint (the head as "follow"), the live card, else nothing.
    func testMainTargetOfAPickedChip() {
        var tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0)])
        tape.roundInProgress = PlannedRound(stage: .refine, round: 1, major: false)
        let rows = RoundTimeline.rows(config: config(), tape: tape)
        XCTAssertEqual(RoundTimeline.mainTarget(for: RoundKey(stage: .draft, round: 0), rows: rows, tape: tape), .checkpoint(1))
        XCTAssertEqual(RoundTimeline.mainTarget(for: RoundKey(stage: .synthesis, round: 0), rows: rows, tape: tape),
                       .checkpoint(nil), "the head is shown by following it")
        XCTAssertEqual(RoundTimeline.mainTarget(for: RoundKey(stage: .refine, round: 1), rows: rows, tape: tape), .live)
        XCTAssertEqual(RoundTimeline.mainTarget(for: RoundKey(stage: .refine, round: 2), rows: rows, tape: tape), .none)
        XCTAssertEqual(RoundTimeline.key(checkpoint: 2, in: tape), RoundKey(stage: .synthesis, round: 0))
    }

    func testCaptionsSayTheEditAppliesToTheWholeStage() {
        XCTAssertEqual(RoundTimeline.caption(.refine), "Applies to every Refine round")
        XCTAssertEqual(RoundTimeline.caption(.polish), "Applies to every Polish round")
        XCTAssertEqual(RoundTimeline.caption(.draft), "Applies to the Draft round")
    }

    /// A round picked in the main view (its checkpoint, or nil = the head being followed) picks
    /// its chip in the inspector; a tape with nothing on it leaves the pick alone.
    func testMainViewPickSelectsTheInspectorChip() {
        let tape = Tape(checkpoints: [ran(1, .draft, 0), ran(2, .synthesis, 0), ran(3, .refine, 1)])
        XCTAssertEqual(RoundTimeline.selection(forPlanCheckpoint: 2, in: tape), .round(RoundKey(stage: .synthesis, round: 0)))
        XCTAssertEqual(RoundTimeline.selection(forPlanCheckpoint: nil, in: tape), .round(RoundKey(stage: .refine, round: 1)))
        XCTAssertNil(RoundTimeline.selection(forPlanCheckpoint: nil, in: .empty))
        // And back: the inspector's pick of the same round targets the same checkpoint.
        let rows = RoundTimeline.rows(config: config(), tape: tape)
        XCTAssertEqual(RoundTimeline.mainTarget(for: RoundKey(stage: .synthesis, round: 0), rows: rows, tape: tape), .checkpoint(2))
    }

    // MARK: - Rotations

    /// Each chip shows ITS round's agents: the rotation entry, not the role's first agent.
    func testChipsShowEachRoundsRotatedAgents() throws {
        var cfg = config(.off, refine: 4, polish: 2, freshEyes: true)
        cfg.reviewer = Slot(codex); cfg.polisher = claude
        cfg.reviewers = [Slot(codex), Slot(claude)]
        cfg.integrators = [claude, codex]
        cfg.polishers = [claude, gemini, codex]
        let rows = RoundTimeline.rows(config: cfg, tape: nil)
        let refine = rows.first { $0.section == .refine }!.chips
        XCTAssertEqual(refine.map { $0.agents.map(\.choice.agent) },
                       [[.codex, .claude], [.claude, .codex], [.codex, .claude], [.claude, .codex]])
        XCTAssertEqual(refine.map { $0.agents.map(\.role) }.first, ["reviewer", "integrator"])
        let polish = rows.first { $0.section == .polish }!.chips
        XCTAssertEqual(polish.map(\.name), ["Polish 1", "Polish 2", "Fresh eyes", "Dedup"])
        XCTAssertEqual(polish.map { $0.agents.map(\.choice.agent) }, [[.claude], [.gemini], [.codex], [.claude]])
        // The section heading's stack lists the whole rotation.
        XCTAssertEqual(AgentStackModel.section(.polish, config: cfg).map(\.choice.agent), [.claude, .gemini, .codex])
        XCTAssertEqual(AgentStackModel.section(.refine, config: cfg).map(\.role), ["reviewer", "reviewer", "integrator", "integrator"])
    }

    /// The live card's seat rows list the same agent the chip and the engine use.
    func testSeatRowsFollowTheRotation() {
        var cfg = config(.off)
        cfg.reviewer = Slot(codex)
        cfg.reviewers = [Slot(codex), Slot(claude)]
        cfg.integrators = [claude, codex]
        let round = TapePlanner.plannedRounds(config: cfg, tape: .empty).first { $0.stage == .refine && $0.round == 2 }!
        let seats = LiveSeats.expected(round, config: cfg)
        XCTAssertEqual(seats.map(\.base), ["refine-2-reviewer", "refine-2-integrator"])
        XCTAssertEqual(seats.map { $0.requested?.choice.agent }, [.claude, .codex])
    }
}
