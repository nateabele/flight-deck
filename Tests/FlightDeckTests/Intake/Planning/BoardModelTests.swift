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
        XCTAssertEqual(model.inTheAir.value, "15:00", "180 + 288 + 288 landed, plus 144 live")
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
        XCTAssertEqual(model.inTheAir.shortLabel, "PSD")
        XCTAssertEqual(model.inTheAir.value, "2:12")
        XCTAssertEqual(model.inTheAir.detail, "since Refine 1 landed")

        var idle = pausedAfterR1(status: .idle)
        idle.checkpoints.removeAll()
        XCTAssertEqual(try board(try intake(.featurePlan), idle).inTheAir.label, "PAUSED FOR")
        XCTAssertEqual(try board(try intake(.featurePlan), idle).inTheAir.value, "—")
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
    }

    func testCallingAtListsRemainingMajors() throws {
        let model = try board(try intake(.fullPlan), pausedAfterR1(), preview: .step)
        // Step stops at RF2; the majors still to call at after it:
        XCTAssertEqual(model.callingAt.value, "Refine 5 · Encode · Polish 6 · Dedup · Review")
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
            let label = choose(full: slot.name, code: slot.code, width: width, measure: measure)
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
            XCTAssertEqual(choose(full: slot.name, code: slot.code, width: width, measure: measure), slot.name)
        }
        XCTAssertEqual(wide.reduce(0, +), 4000, accuracy: 0.001)
    }

    /// Stand-in for Task 3's `LabelFit.choose`, same contract: full name when it fits with padding.
    private func choose(full: String, code: String, width: CGFloat, padding: CGFloat = 8,
                        measure: (String) -> CGFloat) -> String {
        measure(full) + padding <= width ? full : code
    }
}
