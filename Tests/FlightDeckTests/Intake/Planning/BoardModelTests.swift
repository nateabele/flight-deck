import XCTest
import IntakeKit
@testable import FlightDeck

final class BoardModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func intake(_ preset: Preset, answered: Int = 1) throws -> Intake {
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        intake.roundConfig = try XCTUnwrap(PresetExpansion.config(for: preset, available: .defaults))
        intake.exchanges = (0..<answered).map { TriageExchange(questions: ["Q\($0)?"], answers: ["A\($0)"]) }
        return intake
    }

    /// Checkpoint `id` landing `at` seconds after `t0`.
    private func cp(_ id: Int, _ stage: Stage, _ round: Int = 0, major: Bool, at seconds: TimeInterval,
                    _ record: RoundRecord = RoundRecord()) -> Checkpoint {
        Checkpoint(id: id, parent: id > 1 ? id - 1 : nil, stage: stage, round: round, major: major,
                   createdAt: t0.addingTimeInterval(seconds), record: record)
    }

    /// Feature plan paused after Refine 1: draft at 0, synthesis at 180, refine 1 at 468.
    private func pausedAfterR1(status: RunnerStatus = .paused) -> Tape {
        Tape(checkpoints: [
            cp(1, .draft, major: true, at: 0),
            cp(2, .synthesis, major: true, at: 180),
            cp(3, .refine, 1, major: false, at: 468),
        ], status: status)
    }

    private func board(_ intake: Intake, _ tape: Tape, now: TimeInterval = 600, selected: Int? = nil,
                       preview: PlayMode? = nil) throws -> BoardModel {
        BoardModel(intake: intake, tape: tape, config: try XCTUnwrap(intake.roundConfig),
                   now: t0.addingTimeInterval(now), selected: selected, preview: preview)
    }

    // MARK: - Slots

    /// The whole route, departure to arrival: the code table is fixed so the board reads the same
    /// on every intake, and the majors are exactly where ⏭ can stop.
    func testFullPlanSlotsAndCodes() throws {
        let model = try board(try intake(.fullPlan, answered: 2), .empty)
        XCTAssertEqual(model.slots.map(\.code), [
            "CLR1", "CLR2", "DRFT", "SYN", "RF1", "RF2", "RF3", "RF4", "RF5", "ENC",
            "PL1", "PL2", "PL3", "PL4", "PL5", "PL6", "FRSH", "DDUP", "REV",
        ])
        XCTAssertEqual(model.slots.map(\.name), [
            "Clarify 1", "Clarify 2", "Draft", "Synthesis", "Refine 1", "Refine 2", "Refine 3", "Refine 4",
            "Refine 5", "Encode", "Polish 1", "Polish 2", "Polish 3", "Polish 4", "Polish 5", "Polish 6",
            "Fresh eyes", "Dedup", "Review",
        ])
        XCTAssertEqual(model.slots.filter(\.major).map(\.code), ["DRFT", "SYN", "RF5", "ENC", "PL6", "DDUP", "REV"])
        XCTAssertEqual(model.slots.map(\.id).prefix(5), ["clarify-1", "clarify-2", "draft-0", "synthesis-0", "refine-1"])
        XCTAssertEqual(model.slots.last?.id, "review")
        XCTAssertEqual(model.slots.prefix(2).map(\.state), [.done, .done], "answered clarify rounds are behind us")
        XCTAssertEqual(Set(model.slots.dropFirst(2).map(\.state)), [.future])
        XCTAssertEqual(model.slots.prefix(2).map(\.duration), [nil, nil], "exchanges carry no timestamps")
        XCTAssertEqual(model.groups.map(\.name), ["CLARIFY", "REFINE", "POLISH"])
        XCTAssertEqual(model.groups.map(\.range), [0...1, 4...8, 10...15])
        XCTAssertEqual(model.groups.map(\.extendable), [nil, .refine, .polish])
        XCTAssertEqual(model.slots[4].group, "REFINE")
        XCTAssertNil(model.slots[2].group)
    }

    /// Sketch has no synthesizer and no polisher: the tape goes straight from Draft to refine,
    /// then Encode, then Review.
    func testSketchSlotsAndMajors() throws {
        let model = try board(try intake(.sketch, answered: 1), .empty)
        XCTAssertEqual(model.slots.map(\.code), ["CLR1", "DRFT", "RF1", "RF2", "ENC", "REV"])
        XCTAssertEqual(model.slots.filter(\.major).map(\.code), ["DRFT", "RF2", "ENC", "REV"])
        XCTAssertEqual(model.groups.map(\.name), ["CLARIFY", "REFINE"])
    }

    /// An exchange still waiting on answers isn't a finished Clarify round.
    func testUnansweredExchangeIsNotASlot() throws {
        var intake = try intake(.sketch, answered: 1)
        intake.exchanges.append(TriageExchange(questions: ["Still open?"]))
        XCTAssertEqual(try board(intake, .empty).slots.filter { $0.group == "CLARIFY" }.map(\.code), ["CLR1"])
    }

    func testLiveSlotAndDurations() throws {
        var tape = pausedAfterR1(status: .running)
        tape.checkpoints.append(cp(4, .refine, 2, major: false, at: 756))
        tape.roundInProgress = PlannedRound(stage: .refine, round: 3, major: true)
        tape.target = .review
        let model = try board(try intake(.featurePlan), tape, now: 900)
        let byCode = Dictionary(uniqueKeysWithValues: model.slots.map { ($0.code, $0) })

        // The first round has no earlier checkpoint to measure from — nil rather than a guess.
        XCTAssertNil(byCode["DRFT"]?.duration)
        XCTAssertEqual(byCode["SYN"]?.duration, 180)
        XCTAssertEqual(byCode["RF1"]?.duration, 288)
        XCTAssertEqual(byCode["RF2"]?.duration, 288)
        XCTAssertEqual(byCode["RF3"]?.state, .live)
        XCTAssertEqual(byCode["RF3"]?.duration, 144, "live: since the previous checkpoint landed")
        XCTAssertEqual(["ENC", "PL1", "PL2", "REV"].map { byCode[$0]?.state }, [.future, .future, .future, .future])
        XCTAssertEqual(["ENC", "PL1"].map { byCode[$0]?.duration }, [nil, nil])
        XCTAssertEqual(byCode["RF2"]?.checkpointID, 4)
        XCTAssertNil(byCode["RF3"]?.checkpointID)

        XCTAssertEqual(model.now.value, "Refine 3")
        XCTAssertEqual(model.nowChip, "ON COURSE")
        XCTAssertEqual(model.inTheAir.label, "IN THE AIR")
        XCTAssertEqual(model.inTheAir.value, "2:24", "the live round's own clock, not the run's 15:00 total")
        XCTAssertEqual(model.inTheAir.shortLabel, "IN AIR")
        XCTAssertEqual(model.now.detail, "Leg 6 of 10")
        XCTAssertEqual(model.now.shortDetail, "Leg 6/10")
        XCTAssertEqual(model.stopsAt.label, "STOPS AT")
        XCTAssertEqual(model.stopsAt.value, "Review", "a running tape stops where its target says")
    }

    func testPausedBoardFields() throws {
        var tape = pausedAfterR1()
        tape.pendingNotes = [.legacy("tighten scope", index: 0)]
        let model = try board(try intake(.featurePlan), tape, now: 600)
        XCTAssertEqual(model.now.value, "Refine 1")
        XCTAssertEqual(model.nowChip, "PAUSED")
        XCTAssertEqual(model.now.detail, "1 note will go to Refine 2")
        XCTAssertEqual(model.inTheAir.label, "PAUSED FOR")
        XCTAssertEqual(model.inTheAir.shortLabel, "PAUSED")
        XCTAssertEqual(model.inTheAir.value, "2:12")
        XCTAssertEqual(model.inTheAir.detail, "since Refine 1 landed")
        XCTAssertEqual(model.inTheAir.shortDetail, "since RF1")
        XCTAssertEqual(model.now.shortDetail, "1 note → RF2")
        XCTAssertEqual(model.stopsAt.shortLabel, "STOPS")
        XCTAssertEqual(model.stopsAt.detail, "major · next major")
        XCTAssertEqual(model.stopsAt.shortDetail, "major")
        XCTAssertEqual(model.callingAt.shortLabel, "CALLING")

        var idle = pausedAfterR1(status: .idle)
        idle.checkpoints.removeAll()
        XCTAssertEqual(try board(try intake(.featurePlan), idle).inTheAir.label, "PAUSED FOR")
        XCTAssertEqual(try board(try intake(.featurePlan), idle).inTheAir.value, "—")
    }

    /// The engine's round timestamps win over checkpoint gaps: a round that started long after
    /// the previous checkpoint (the tape sat paused) is timed from its own start.
    func testDurationsUseRecordedRoundStarts() throws {
        var tape = pausedAfterR1(status: .running)
        tape.checkpoints[0].startedAt = t0.addingTimeInterval(-240)   // Draft: 4:00, where the gap rule gave nothing
        tape.checkpoints[2].startedAt = t0.addingTimeInterval(400)    // Refine 1 started after a pause
        tape.checkpoints.append(cp(4, .refine, 2, major: false, at: 756))
        tape.roundInProgress = PlannedRound(stage: .refine, round: 3, major: true)
        tape.roundStartedAt = t0.addingTimeInterval(850)
        let byCode = Dictionary(uniqueKeysWithValues: try board(try intake(.featurePlan), tape, now: 900).slots.map { ($0.code, $0) })
        XCTAssertEqual(byCode["DRFT"]?.duration, 240)
        XCTAssertEqual(byCode["SYN"]?.duration, 180, "no startedAt: falls back to the gap since Draft")
        XCTAssertEqual(byCode["RF1"]?.duration, 68)
        XCTAssertEqual(byCode["RF2"]?.duration, 288, "no startedAt: falls back to the gap since Refine 1")
        XCTAssertEqual(byCode["RF3"]?.duration, 50, "live: since roundStartedAt, not since Refine 2 landed")
    }

    func testFailedRoundDurationAndHaltedFor() throws {
        var tape = pausedAfterR1(status: .failed)
        tape.roundStartedAt = t0.addingTimeInterval(500)
        tape.failedAt = t0.addingTimeInterval(530)
        let model = try board(try intake(.featurePlan), tape, now: 600)
        XCTAssertEqual(model.slots.first { $0.state == .failed }?.duration, 30)
        XCTAssertEqual(model.inTheAir.value, "1:10")
        XCTAssertEqual(model.inTheAir.detail, "since Refine 2 failed")
        XCTAssertEqual(model.inTheAir.shortLabel, "HALTED")
        XCTAssertEqual(model.inTheAir.shortDetail, "since RF2 failed")

        tape.failedAt = nil
        let old = try board(try intake(.featurePlan), tape, now: 600)
        XCTAssertNil(old.slots.first { $0.state == .failed }?.duration, "no failure time on record: no duration")
        XCTAssertEqual(old.inTheAir.value, "2:12")
        XCTAssertEqual(old.inTheAir.detail, "since Refine 1 landed")
    }

    func testFailedRoundIsRed() throws {
        var tape = pausedAfterR1(status: .failed)
        tape.pauseDiagnosis = Diagnosis(category: .rateLimited, detail: "429 from codex", action: "Wait")
        let model = try board(try intake(.featurePlan), tape)
        XCTAssertEqual(model.slots.filter { $0.state == .failed }.map(\.code), ["RF2"])
        XCTAssertEqual(model.slots.first { $0.code == "RF3" }?.state, .future)
        XCTAssertEqual(model.now.value, "Refine 2")
        XCTAssertEqual(model.nowChip, "FAILED")
        XCTAssertEqual(model.now.detail, "429 from codex")
        XCTAssertEqual(model.inTheAir.label, "HALTED FOR")
    }

    // MARK: - Stops

    func testStopTargetPerMode() throws {
        let model = try board(try intake(.featurePlan), pausedAfterR1())
        XCTAssertEqual(model.stopTarget(for: .step), "refine-2")
        XCTAssertEqual(model.stopTarget(for: .nextMajor), "refine-3")
        XCTAssertEqual(model.stopTarget(for: .toReview), "review")
        // No preview: STOPS AT follows the config's default play (feature plan: next major).
        XCTAssertEqual(model.stopsAt.label, "STOPS AT")
        XCTAssertEqual(model.stopsAt.value, "Refine 3")

        let hovering = try board(try intake(.featurePlan), pausedAfterR1(), preview: .step)
        XCTAssertEqual(hovering.stopsAt.label, "WOULD STOP")
        XCTAssertEqual(hovering.stopsAt.shortLabel, "WOULD")
        XCTAssertEqual(hovering.stopsAt.value, "Refine 2")

        var landed = pausedAfterR1(status: .reachedReview)
        landed.checkpoints += [
            cp(4, .refine, 2, major: false, at: 700), cp(5, .refine, 3, major: true, at: 800),
            cp(6, .encode, major: true, at: 900), cp(7, .polish, 1, major: false, at: 1000),
            cp(8, .polish, 2, major: true, at: 1100),
        ]
        let arrived = try board(try intake(.featurePlan), landed, now: 1200)
        XCTAssertNil(arrived.stopTarget(for: .toReview), "nothing left to run at review")
        XCTAssertEqual(arrived.slots.last?.state, .done)
        XCTAssertEqual(arrived.now.value, "Review")
        XCTAssertEqual(arrived.inTheAir.label, "TOTAL")
        XCTAssertEqual(arrived.stopsAt.value, "Review", "the run has arrived: it stops where it is")
        XCTAssertEqual(arrived.stopsAt.detail, "ready for you")
        XCTAssertEqual(arrived.inTheAir.shortLabel, "TOTAL")
        XCTAssertEqual(arrived.inTheAir.value, "18:20", "at review TOTAL stays the whole run: 180 + 288 + 232 + 4 × 100")
        XCTAssertEqual(arrived.stopsAt.shortDetail, "ready")
    }

    func testCallingAtListsRemainingMajors() throws {
        let model = try board(try intake(.fullPlan), pausedAfterR1(), preview: .step)
        // Step stops at RF2; the majors still to call at after it:
        XCTAssertEqual(model.callingAt.value, "5 · Refine 5 · Encode · Polish 6 · Dedup · Review")
        let nextMajor = try board(try intake(.fullPlan), pausedAfterR1(), preview: .nextMajor)
        XCTAssertEqual(nextMajor.callingAt.value, "4 · Encode · Polish 6 · Dedup · Review")
        let toReview = try board(try intake(.fullPlan), pausedAfterR1(), preview: .toReview)
        XCTAssertEqual(toReview.callingAt.value, "Release tasks · done")
        XCTAssertFalse(toReview.callingAt.value.lowercased().contains("bead"))
    }

    func testExtendMovesMajor() throws {
        var tape = pausedAfterR1()
        tape.extraRefinement = 1
        let model = try board(try intake(.featurePlan), tape)
        XCTAssertEqual(model.slots.filter { $0.group == "REFINE" }.map(\.code), ["RF1", "RF2", "RF3", "RF4"])
        XCTAssertEqual(model.slots.filter { $0.group == "REFINE" }.map(\.major), [false, false, false, true])
        XCTAssertEqual(model.stopTarget(for: .nextMajor), "refine-4")
        XCTAssertEqual(model.groups.first { $0.name == "REFINE" }?.extendable, .refine)

        // Once the head is past refine, + on that bracket would be a silent no-op.
        var encoded = pausedAfterR1()
        encoded.checkpoints += [cp(4, .refine, 2, major: false, at: 700), cp(5, .refine, 3, major: true, at: 800),
                                cp(6, .encode, major: true, at: 900)]
        let past = try board(try intake(.featurePlan), encoded)
        XCTAssertNil(past.groups.first { $0.name == "REFINE" }?.extendable)
        XCTAssertEqual(past.groups.first { $0.name == "POLISH" }?.extendable, .polish)
    }

    // MARK: - Selection and flags

    func testSelectedCheckpoint() throws {
        let model = try board(try intake(.featurePlan), pausedAfterR1(), selected: 2)
        XCTAssertEqual(model.slots.filter { $0.state == .selected }.map(\.code), ["SYN"])
        XCTAssertEqual(model.slots.first { $0.code == "DRFT" }?.state, .done)
        // A selection that isn't a checkpoint on the tape selects nothing.
        XCTAssertTrue(try board(try intake(.featurePlan), pausedAfterR1(), selected: 99).slots.allSatisfy { $0.state != .selected })
    }

    func testFlagsMarkAnnotatedRoundsAndPendingUnanchoredNotes() throws {
        var tape = pausedAfterR1()
        tape.checkpoints[2].record.annotations = [.legacy("more detail", index: 0)]
        let model = try board(try intake(.featurePlan), tape)
        XCTAssertEqual(model.slots.filter(\.flagged).map(\.code), ["RF1"])

        tape.pendingNotes = [.legacy("cut rollout", index: 0)]
        XCTAssertEqual(try board(try intake(.featurePlan), tape).slots.filter(\.flagged).map(\.code), ["RF1", "RF2"],
                       "an unanchored pending note has nowhere in the plan to show, so the round taking it is flagged")
    }

    // MARK: - Card and accessibility

    /// The hover card says what the round did, in the board's own words: under the full name
    /// (the part that flaps), its status and duration as static text.
    func testHoverCardDetail() throws {
        let tape = Tape(checkpoints: [cp(1, .draft, major: true, at: 0), cp(2, .synthesis, major: true, at: 182)],
                        status: .paused)
        let model = try board(try intake(.featurePlan), tape, now: 300)
        let syn = try XCTUnwrap(model.slots.first { $0.code == "SYN" })
        XCTAssertEqual(model.cardDetail(for: syn), "landed 3:02")
        let draft = try XCTUnwrap(model.slots.first { $0.code == "DRFT" })
        XCTAssertEqual(model.cardDetail(for: draft), "landed", "no honest duration: say nothing rather than 0:00")
        let rf1 = try XCTUnwrap(model.slots.first { $0.code == "RF1" })
        XCTAssertEqual(model.cardDetail(for: rf1), "scheduled")

        var running = tape
        running.status = .running
        running.roundStartedAt = t0.addingTimeInterval(200)
        let live = try board(try intake(.featurePlan), running, now: 272)
        XCTAssertEqual(live.cardDetail(for: try XCTUnwrap(live.slots.first { $0.state == .live })), "in the air 1:12")

        var failed = tape
        failed.status = .failed
        failed.roundStartedAt = t0.addingTimeInterval(200)
        failed.failedAt = t0.addingTimeInterval(230)
        let halted = try board(try intake(.featurePlan), failed)
        XCTAssertEqual(halted.cardDetail(for: try XCTUnwrap(halted.slots.first { $0.state == .failed })), "failed 0:30")
    }

    /// VoiceOver reads every slot in full words (spec §14) — never a code, never "4:48".
    func testAccessibilityLabelsAreFullWords() throws {
        var tape = pausedAfterR1()
        tape.checkpoints.append(cp(4, .refine, 2, major: false, at: 756))
        tape.checkpoints[2].record.annotations = [.legacy("more detail", index: 0)]
        let model = try board(try intake(.featurePlan), tape, now: 900, selected: 2)
        let byCode = Dictionary(uniqueKeysWithValues: model.slots.map { ($0.code, $0) })
        func spoken(_ code: String) throws -> String { model.accessibilityLabel(for: try XCTUnwrap(byCode[code])) }

        XCTAssertEqual(try spoken("RF2"), "Refine 2, landed, 4 minutes 48 seconds")
        XCTAssertEqual(try spoken("RF1"), "Refine 1, landed, 4 minutes 48 seconds, has notes")
        XCTAssertEqual(try spoken("SYN"), "Synthesis, landed, 3 minutes, major stop, selected")
        XCTAssertEqual(try spoken("DRFT"), "Draft, landed, major stop")
        XCTAssertEqual(try spoken("RF3"), "Refine 3, scheduled, major stop, stops here")
        XCTAssertEqual(try spoken("CLR1"), "Clarify 1, landed")
        XCTAssertEqual(BoardModel.spokenDuration(3723), "1 hour 2 minutes 3 seconds")
        XCTAssertEqual(BoardModel.spokenDuration(61), "1 minute 1 second")
        XCTAssertEqual(BoardModel.spokenDuration(0.4), "0 seconds")
        for slot in model.slots {
            let label = model.accessibilityLabel(for: slot)
            XCTAssertFalse(label.contains(slot.code), "\(label) speaks a code")
            XCTAssertNil(label.range(of: #"\d:\d"#, options: .regularExpression), "\(label) speaks a clock")
        }
    }

    // MARK: - Flap surfaces

    /// Clocks never flap (T5 ruling): IN THE AIR's value is a ticking duration, so its flap
    /// surface carries the LABEL, which changes only between IN THE AIR, PAUSED FOR and HALTED
    /// FOR. Keyed on the value, every tick would be new text and the seeding would be useless.
    /// Tape labels are seeded too, under the slot's bare id, so a slot scrolling into view
    /// doesn't flip in — only a slot that newly appears (an extend) does.
    func testFlapTextsKeyTheClockOnItsLabelAndSeedTapeLabels() throws {
        var tape = pausedAfterR1(status: .running)
        tape.roundStartedAt = t0.addingTimeInterval(470)
        let a = try board(try intake(.featurePlan), tape, now: 600)
        let b = try board(try intake(.featurePlan), tape, now: 601)
        XCTAssertNotEqual(a.inTheAir.value, b.inTheAir.value)
        XCTAssertEqual(a.flapTexts, b.flapTexts, "a clock tick is not new flap text")
        XCTAssertEqual(a.flapTexts["board.inTheAir"], "IN THE AIR")
        XCTAssertEqual(a.flapTexts["refine-2"], "Refine 2")
        XCTAssertEqual(a.flapTexts["card.refine-2"], "Refine 2")

        tape.status = .paused
        XCTAssertEqual(try board(try intake(.featurePlan), tape).flapTexts["board.inTheAir"], "PAUSED FOR")
    }

    /// The short form of each board value, for a field too narrow for the name.
    func testBoardValueCodes() throws {
        let model = try board(try intake(.fullPlan), pausedAfterR1(), preview: .step)
        XCTAssertEqual(model.now.valueCode, "RF1")
        XCTAssertEqual(model.stopsAt.valueCode, "RF2")
        XCTAssertEqual(model.stopSlotID, "refine-2")
        XCTAssertEqual(model.callingAt.valueCode, "5 · RF5 · ENC · PL6 · DDUP · REV")
        XCTAssertEqual(model.pausedAtSlotID, "refine-1")
        XCTAssertNil(try board(try intake(.fullPlan), pausedAfterR1(status: .running)).pausedAtSlotID)
    }

    // MARK: - Fit

    /// 22 slots in 600 pt: every label falls back to its code, the tape scrolls rather than
    /// squeezing slots under their code width, and no two labels overlap.
    func testNarrowTapeFallsBackToCodesWithoutOverlap() throws {
        let model = try board(try intake(.fullPlan, answered: 5), .empty)
        XCTAssertEqual(model.slots.count, 22)
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 7.8 }   // 13 pt mono advance
        let available: CGFloat = 600
        let widths = model.slotWidths(available: available, measure: measure)
        XCTAssertEqual(widths.count, 22)

        var x: CGFloat = 0
        var frames: [ClosedRange<CGFloat>] = []
        for (slot, width) in zip(model.slots, widths) {
            XCTAssertGreaterThanOrEqual(width, slot.codeWidth(measure: measure), slot.code)
            let label = LabelFit.choose(full: slot.name, code: slot.code, width: width, measure: measure)
            XCTAssertEqual(label, slot.code, "\(slot.name) at \(width) pt")
            let labelWidth = measure(label)
            let origin = x + (width - labelWidth) / 2
            frames.append(origin...(origin + labelWidth))
            x += width
        }
        let scroll = max(0, model.slots.reduce(0) { $0 + $1.codeWidth(measure: measure) } - available)
        XCTAssertLessThanOrEqual(widths.reduce(0, +), available + scroll + 0.001)
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThan(a.upperBound, b.lowerBound)
        }

        // Wide enough for every full name: slots get their full width and full names show.
        let wide = model.slotWidths(available: 4000, measure: measure)
        for (slot, width) in zip(model.slots, wide) {
            XCTAssertEqual(LabelFit.choose(full: slot.name, code: slot.code, width: width, measure: measure), slot.name)
        }
        XCTAssertEqual(wide.reduce(0, +), 4000, accuracy: 0.001)
    }

    /// Review Focus 1's other half: at round 18+ in a 600 pt pane the live slot is far off the
    /// tape's first screen, and the tape keeps it in view. The target is the model's, so this
    /// pins what the view scrolls to — the empty tape above has no live slot to follow.
    func testNarrowTapeFollowsTheLiveSlotLateInARun() throws {
        let stages: [(Stage, Int, Bool)] = [(.draft, 0, true), (.synthesis, 0, true)]
            + (1...5).map { (.refine, $0, $0 == 5) } + [(.encode, 0, true)] + (1...5).map { (.polish, $0, false) }
        var tape = Tape(checkpoints: stages.enumerated().map { n, s in cp(n + 1, s.0, s.1, major: s.2, at: TimeInterval(n) * 300) },
                        status: .running)
        tape.roundInProgress = PlannedRound(stage: .polish, round: 6, major: true)
        let model = try board(try intake(.fullPlan, answered: 5), tape, now: 4000)
        let live = try XCTUnwrap(model.slots.firstIndex { $0.state == .live })
        XCTAssertGreaterThanOrEqual(live, 18)
        XCTAssertEqual(model.followSlotID, model.slots[live].id)

        let measure: (String) -> CGFloat = { CGFloat($0.count) * 7.8 }
        let widths = model.slotWidths(available: 600, measure: measure)
        XCTAssertGreaterThan(widths.prefix(live).reduce(0, +), 600, "off the first screen: only following shows it")
        XCTAssertEqual(LabelFit.choose(full: model.slots[live].name, code: model.slots[live].code, width: widths[live],
                                       measure: measure), model.slots[live].code)

        // Paused, it follows where the run is held; with nothing landed, where play would stop.
        tape.status = .paused
        tape.roundInProgress = nil
        let paused = try board(try intake(.fullPlan, answered: 5), tape, now: 4000)
        XCTAssertEqual(paused.followSlotID, paused.pausedAtSlotID)
        let fresh = try board(try intake(.fullPlan, answered: 5), .empty)
        XCTAssertEqual(fresh.followSlotID, fresh.stopSlotID)
    }

    /// A bracket's title, longest first: the full title, then the group's code with its count
    /// ("RF 2 OF 3", "PL ×2"), then the group's name alone, then nothing — so a narrow bracket
    /// still says which cycle it is, where "2 OF 3" or "×2" alone said only how far. A one-round
    /// group has no count to give: "×1" told nobody anything.
    func testBracketTitleCandidates() throws {
        var tape = pausedAfterR1(status: .running)
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        let model = try board(try intake(.featurePlan, answered: 1), tape)
        let byName = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.name, $0) })
        let clarify = try XCTUnwrap(byName["CLARIFY"]), refine = try XCTUnwrap(byName["REFINE"])
        XCTAssertEqual(model.bracketTitles(clarify), ["CLARIFY", "CLR", ""], "one round: never ×1")
        let rounds = refine.range.count
        XCTAssertEqual(model.bracketTitles(refine), ["REFINE 2 OF \(rounds)", "RF 2 OF \(rounds)", "REFINE", ""])

        let idle = try board(try intake(.featurePlan, answered: 2), pausedAfterR1())
        let polish = try XCTUnwrap(idle.groups.first { $0.name == "POLISH" })
        XCTAssertEqual(idle.bracketTitles(polish), ["POLISH ×\(polish.range.count)", "PL ×\(polish.range.count)", "POLISH", ""])
        let twoClarify = try XCTUnwrap(idle.groups.first { $0.name == "CLARIFY" })
        XCTAssertEqual(idle.bracketTitles(twoClarify), ["CLARIFY ×2", "CLR ×2", "CLARIFY", ""])
    }

    /// The first candidate that fits the room before the + handle.
    func testBracketTitleFitsTheFirstCandidateThatFits() {
        let candidates = ["REFINE 2 OF 3", "RF 2 OF 3", "REFINE", ""]
        XCTAssertEqual(DeparturesBoard.fittedBracketTitle(candidates, width: 400), "REFINE 2 OF 3")
        XCTAssertEqual(DeparturesBoard.fittedBracketTitle(candidates, width: 90), "RF 2 OF 3")
        XCTAssertEqual(DeparturesBoard.fittedBracketTitle(candidates, width: 60), "REFINE")
        XCTAssertEqual(DeparturesBoard.fittedBracketTitle(candidates, width: 5), "")
    }
}
