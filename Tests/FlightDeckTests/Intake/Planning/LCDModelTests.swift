import XCTest
import IntakeKit
@testable import FlightDeck

/// The control bar's LCD (spec §4): which cells it shows, what each says in every tape state,
/// and the order they leave as the bar narrows — pinned here so none of it has to be found
/// out by resizing a window.
final class LCDModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func intake(_ preset: Preset) throws -> Intake {
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        intake.roundConfig = try XCTUnwrap(PresetExpansion.config(for: preset, available: .defaults))
        intake.exchanges = [TriageExchange(questions: ["Q?"], answers: ["A"])]
        return intake
    }

    private func cp(_ id: Int, _ stage: Stage, _ round: Int = 0, major: Bool, at seconds: TimeInterval,
                    added: Int = 0, removed: Int = 0) -> Checkpoint {
        Checkpoint(id: id, parent: id > 1 ? id - 1 : nil, stage: stage, round: round, major: major,
                   createdAt: t0.addingTimeInterval(seconds),
                   record: RoundRecord(linesAdded: added, linesRemoved: removed))
    }

    /// Feature plan after Refine 1: the draft wrote the plan from nothing (+400), then synthesis
    /// and Refine 1 changed it by +42 −17 between them.
    private func afterR1(_ status: RunnerStatus) -> Tape {
        Tape(checkpoints: [
            cp(1, .draft, major: true, at: 0, added: 400),
            cp(2, .synthesis, major: true, at: 180, added: 12, removed: 7),
            cp(3, .refine, 1, major: false, at: 468, added: 30, removed: 10),
        ], status: status)
    }

    private func seat(_ id: String, _ glyph: SeatRowModel.Glyph, cost: Double? = nil) -> SeatRowModel {
        SeatRowModel(id: id, glyph: glyph, role: "reviewer", identity: "claude · opus · high", headline: nil,
                     action: nil, footprint: [], footprintAll: [], steps: nil, contextFraction: nil, elapsed: 0,
                     exception: nil, result: nil, cost: cost)
    }

    private let converging = ConvergenceCellModel(word: "CONVERGING ↘", latest: 14, spark: [41, 14], tone: .normal)

    private func lcd(_ intake: Intake, _ tape: Tape, seats: [SeatRowModel] = [], convergence: ConvergenceCellModel? = nil,
                     preview: PlayMode? = nil, now: TimeInterval) throws -> LCDModel {
        let config = try XCTUnwrap(intake.roundConfig)
        let date = t0.addingTimeInterval(now)
        let board = BoardModel(intake: intake, tape: tape, config: config, now: date, selected: nil, preview: preview)
        return LCDModel(tape: tape, config: config, board: board, seats: seats, convergence: convergence,
                        preview: preview, now: date)
    }

    private func cell(_ model: LCDModel, _ kind: LCDCell.Kind) throws -> LCDCell {
        try XCTUnwrap(model.cells.first { $0.kind == kind }, "no \(kind) cell")
    }

    // MARK: - Values

    /// Refine 2 running for 4:15 with one of its four seats back: every cell in its place, the
    /// bill counting only the seat that finished — a running seat's cost is not a bill yet.
    func testCellsForRunningRefine() throws {
        var tape = afterR1(.running)
        tape.target = .nextMajor
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        tape.roundStartedAt = t0.addingTimeInterval(468)
        let seats = [seat("a", .done, cost: 0.61), seat("b", .running, cost: 9.99), seat("c", .running), seat("d", .queued)]
        let model = try lcd(try intake(.featurePlan), tape, seats: seats, convergence: converging, now: 468 + 255)

        XCTAssertEqual(model.cells.map(\.kind), [.round, .elapsed, .seatsDone, .soFar, .billed, .convergence, .stopsAt])
        let round = try cell(model, .round)
        XCTAssertEqual([round.value, round.shortValue, round.caption], ["REFINE 2", "RF2", "running · of 3"])
        XCTAssertEqual(try cell(model, .elapsed).value, "4:15")
        XCTAssertEqual(try cell(model, .elapsed).caption, "elapsed")
        XCTAssertEqual(try cell(model, .seatsDone).value, "1/4")
        XCTAssertEqual(try cell(model, .soFar).value, "+42 −17", "the draft wrote the plan; it didn't change it")
        XCTAssertEqual(try cell(model, .billed).value, "$0.61")
        let conv = try cell(model, .convergence)
        XCTAssertEqual([conv.value, conv.shortValue, conv.caption], ["CONVERGING ↘", "↘ 14", "14 changes"])
        let stop = try cell(model, .stopsAt)
        XCTAssertEqual([stop.value, stop.shortValue, stop.caption], ["Refine 3", "RF3", "stops at · next major"])
        XCTAssertEqual(stop.tone, .accent)
        XCTAssertEqual(model.stopMode, .nextMajor)
        XCTAssertEqual(Set(model.cells.filter { $0.kind != .stopsAt }.map(\.tone)), [.normal],
                       "a healthy run has no exception colour")
    }

    /// No seats yet and nothing billed: dashes, never a made-up zero.
    func testNothingKnownReadsAsADash() throws {
        let model = try lcd(try intake(.featurePlan), afterR1(.paused), now: 600)
        XCTAssertEqual(try cell(model, .seatsDone).value, "—")
        XCTAssertEqual(try cell(model, .billed).value, "—")
        XCTAssertFalse(model.cells.contains { $0.kind == .convergence }, "no convergence series, no cell")
    }

    // MARK: - States

    /// PAUSED is a caption, not a colour (nothing is wrong); FAILED turns the round red and puts
    /// the diagnosis where SO FAR was; REVIEW turns the round amber, "ready for you".
    func testPausedFailedReviewTones() throws {
        let feature = try intake(.featurePlan)

        let paused = try lcd(feature, afterR1(.paused), now: 600)
        XCTAssertEqual(try cell(paused, .round).value, "REFINE 1")
        XCTAssertEqual(try cell(paused, .round).caption, "paused · of 3")
        XCTAssertEqual(try cell(paused, .elapsed).caption, "paused")
        XCTAssertEqual(try cell(paused, .elapsed).value, "2:12", "since Refine 1 landed")
        XCTAssertFalse(paused.cells.contains { $0.tone == .red || $0.tone == .amber })

        var failedTape = afterR1(.failed)
        failedTape.roundStartedAt = t0.addingTimeInterval(500)
        failedTape.failedAt = t0.addingTimeInterval(530)
        failedTape.pauseDiagnosis = Diagnosis(category: .rateLimited, detail: "429 from codex", action: "Wait")
        let failed = try lcd(feature, failedTape, now: 600)
        let round = try cell(failed, .round)
        XCTAssertEqual([round.value, round.caption], ["REFINE 2", "failed · of 3"])
        XCTAssertEqual(round.tone, .red)
        let diagnosis = try cell(failed, .soFar)
        XCTAssertEqual([diagnosis.value, diagnosis.shortValue, diagnosis.caption], ["429 from codex", "RATE LIMIT", "failed"])
        XCTAssertEqual(diagnosis.tone, .red)
        XCTAssertEqual(try cell(failed, .elapsed).caption, "halted")
        XCTAssertEqual(try cell(failed, .elapsed).tone, .normal, "only the relevant cells recolour")

        var reviewTape = afterR1(.reachedReview)
        reviewTape.status = .reachedReview
        let review = try lcd(feature, reviewTape, now: 600)
        let reviewRound = try cell(review, .round)
        XCTAssertEqual([reviewRound.value, reviewRound.caption], ["REVIEW", "ready for you"])
        XCTAssertEqual(reviewRound.tone, .amber)
        XCTAssertFalse(review.cells.contains { $0.kind == .stopsAt }, "ROUND already says ready for you; nothing is left to stop at")
        XCTAssertNil(review.stopMode)
        XCTAssertEqual(try cell(review, .elapsed).caption, "total")
        XCTAssertEqual(Set(review.cells.filter { $0.kind != .round }.map(\.tone)), [.normal])
    }

    /// Hovering a play button: the stop cell says WOULD STOP and where that button would land,
    /// in plain white rather than the accent it has when it states the live target.
    func testWouldStopWhenPreviewing() throws {
        let feature = try intake(.featurePlan)
        let plain = try cell(try lcd(feature, afterR1(.paused), now: 600), .stopsAt)
        XCTAssertEqual([plain.value, plain.caption], ["Refine 3", "stops at · next major"], "the config's default play")

        let hovered = try lcd(feature, afterR1(.paused), preview: .toReview, now: 600)
        let stop = try cell(hovered, .stopsAt)
        XCTAssertEqual([stop.value, stop.shortValue, stop.caption], ["Review", "REV", "would stop · to review"])
        XCTAssertEqual(stop.tone, .normal)
        XCTAssertEqual(hovered.stopMode, .toReview)

        let step = try cell(try lcd(feature, afterR1(.paused), preview: .step, now: 600), .stopsAt)
        XCTAssertEqual([step.value, step.caption], ["Refine 2", "would stop · step"])
    }

    /// A state word is never cut short ("CONV", "DIVE" read as different words): squeezed, the
    /// cell falls back to its arrow and count, and the whole word stays the flap card's text and
    /// the accessibility label (`SplitFlapText` keys both on `value`).
    func testConvergenceWordIsWholeOrReplacedByArrowAndCount() throws {
        let words: [(String, Int, String)] = [("CONVERGING ↘", 5, "↘ 5"), ("PLATEAU →", 13, "→ 13"),
                                              ("DIVERGING ↗", 29, "↗ 29"), ("TOO EARLY", 41, "41")]
        for (word, latest, short) in words {
            let cellModel = ConvergenceCellModel(word: word, latest: latest, spark: [41, Double(latest)], tone: .normal)
            let model = try lcd(try intake(.featurePlan), afterR1(.paused), convergence: cellModel, now: 600)
            let conv = try cell(model, .convergence)
            XCTAssertEqual(conv.value, word)
            XCTAssertEqual(conv.shortValue, short)
        }
    }

    /// Squeezing the compact CONVERGENCE cell gives up the sparkline before anything else: its
    /// narrowest width still holds the whole word, just no line.
    @MainActor
    func testSqueezedConvergenceDropsTheSparklineBeforeTheWord() throws {
        let model = try lcd(try intake(.featurePlan), afterR1(.paused), convergence: converging, now: 600)
        let conv = try cell(model, .convergence)
        let wordOnly = LCDMetrics.wordWidth(conv)
        XCTAssertLessThan(wordOnly, LCDMetrics.cellWidth(conv), "the full cell includes the sparkline")
        XCTAssertLessThan(LCDMetrics.minWidth(conv), wordOnly, "past the word, it falls back to arrow and count")
        let compact = model.visible(width: 0, cellWidth: LCDMetrics.cellWidth)
        let full = compact.map(LCDMetrics.cellWidth).reduce(0, +)
        // Room for everything but the sparkline: the word must survive.
        let widths = LCDMetrics.widths(compact, available: full - (LCDMetrics.cellWidth(conv) - wordOnly) + CGFloat(compact.count - 1))
        let convWidth = try XCTUnwrap(zip(compact, widths).first { $0.0.kind == .convergence }?.1)
        XCTAssertGreaterThanOrEqual(convWidth, wordOnly - 0.5)
        XCTAssertLessThan(convWidth, LCDMetrics.cellWidth(conv))
    }

    // MARK: - Hover

    /// Hovering a play button previews its stop — unless the button is dark, when there is no
    /// stop to preview; leaving clears only the preview that button set.
    func testHoverPreviewOnlyForEnabledButtons() {
        XCTAssertEqual(ControlBar.hoverPreview(mode: .step, inside: true, enabled: true, current: nil), .step)
        XCTAssertNil(ControlBar.hoverPreview(mode: .step, inside: true, enabled: false, current: nil))
        XCTAssertNil(ControlBar.hoverPreview(mode: .step, inside: true, enabled: false, current: .step),
                     "a button that went dark under the pointer stops previewing")
        XCTAssertNil(ControlBar.hoverPreview(mode: .step, inside: false, enabled: true, current: .step))
        XCTAssertEqual(ControlBar.hoverPreview(mode: .step, inside: false, enabled: true, current: .toReview), .toReview,
                       "leaving one button doesn't clear another's preview")
    }

    // MARK: - Width (Review Focus 1)

    /// A 20+-round run after extends, narrowing: BILLED leaves first, then SO FAR, then STOPS AT
    /// (the board repeats it) — and what stays keeps its order.
    func testCellsDropInOrderAsWidthShrinks() throws {
        var tape = afterR1(.running)
        tape.extraRefinement = 4
        tape.extraPolish = 5
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        tape.roundStartedAt = t0.addingTimeInterval(468)
        let model = try lcd(try intake(.fullPlan), tape, seats: [seat("a", .done, cost: 1)], convergence: converging, now: 700)
        XCTAssertGreaterThanOrEqual(BoardModel(intake: try intake(.fullPlan), tape: tape, config: try XCTUnwrap(try intake(.fullPlan).roundConfig),
                                               now: t0, selected: nil, preview: nil).slots.count, 20)
        let width: (LCDCell) -> CGFloat = { _ in 100 }

        XCTAssertEqual(model.visible(width: 700, cellWidth: width).map(\.kind),
                       [.round, .elapsed, .seatsDone, .soFar, .billed, .convergence, .stopsAt])
        XCTAssertEqual(model.visible(width: 699, cellWidth: width).map(\.kind),
                       [.round, .elapsed, .seatsDone, .soFar, .convergence, .stopsAt])
        XCTAssertEqual(model.visible(width: 599, cellWidth: width).map(\.kind),
                       [.round, .elapsed, .seatsDone, .convergence, .stopsAt])
        XCTAssertEqual(model.visible(width: 499, cellWidth: width).map(\.kind),
                       [.round, .elapsed, .seatsDone, .convergence])
        XCTAssertEqual(LCDModel.dropOrder, [.billed, .soFar, .stopsAt])

        // Uneven widths: a wide cell leaving can save a narrower one that would otherwise go.
        let uneven: (LCDCell) -> CGFloat = { $0.kind == .billed ? 300 : 50 }
        XCTAssertEqual(model.visible(width: 400, cellWidth: uneven).count, 6, "dropping BILLED alone was enough")
    }

    /// The narrow pane's compact bar: ROUND, ELAPSED and CONVERGENCE, however little room is left.
    func testCompactSetAtNarrowWidth() throws {
        var tape = afterR1(.running)
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        let model = try lcd(try intake(.featurePlan), tape, convergence: converging, now: 700)
        let width: (LCDCell) -> CGFloat = { _ in 100 }
        XCTAssertEqual(model.visible(width: 320, cellWidth: width).map(\.kind), [.round, .elapsed, .convergence])
        XCTAssertEqual(model.visible(width: 10, cellWidth: width).map(\.kind), [.round, .elapsed, .convergence],
                       "past the compact set, cells abbreviate rather than leave")
        XCTAssertTrue(LCDModel.isCompact(model.visible(width: 320, cellWidth: width)))
        XCTAssertFalse(LCDModel.isCompact(model.cells))
    }

    // MARK: - Flaps

    /// The LCD's text values are flap surfaces (and so seeded by the service); its clocks and
    /// counters never are — a ticking value would flap every second.
    func testFlapTextsAreTheTextValuesOnly() throws {
        var tape = afterR1(.running)
        tape.target = .nextMajor
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        let model = try lcd(try intake(.featurePlan), tape, convergence: converging, now: 700)
        XCTAssertEqual(model.flapTexts, ["lcd.round": "REFINE 2", "lcd.stopsAt": "Refine 3", "lcd.convergence": "CONVERGING ↘"])
    }

    // MARK: - Halts

    /// "Pausing…"/"Stopping…" hold only until the runner acknowledges the command; a pause
    /// sent to a tape with no runner has nothing to wait for.
    func testHaltLabelUntilAcked() {
        var tape = Tape(status: .running, ackedCommandSeq: 3)
        XCTAssertEqual(HaltRequest(kind: .pause, seq: 4).label(for: tape), "Pausing…")
        XCTAssertEqual(HaltRequest(kind: .stop, seq: 4).label(for: tape), "Stopping…")
        tape.ackedCommandSeq = 4
        XCTAssertNil(HaltRequest(kind: .pause, seq: 4).label(for: tape))
        let idle = Tape(status: .paused, ackedCommandSeq: 3)
        XCTAssertNil(HaltRequest(kind: .pause, seq: 4).label(for: idle), "no runner reads a pause until the next play")
        XCTAssertEqual(HaltRequest(kind: .stop, seq: 4).label(for: idle), "Stopping…", "a runner is started to consume a stop")
    }

    /// VoiceOver reads the value first, then what it is, in words: "running · of 4: REFINE 2"
    /// put the caption's fragments ahead of the thing they describe, and "paused: —" read a
    /// dash aloud.
    func testAccessibilityLabelReadsValueFirstInWords() {
        let round = LCDCell(kind: .round, value: "REFINE 2", shortValue: "RF2", caption: "running · of 4", tone: .normal)
        XCTAssertEqual(round.accessibilityLabel, "REFINE 2, running, of 4")
        let empty = LCDCell(kind: .elapsed, value: "—", shortValue: "—", caption: "paused", tone: .normal)
        XCTAssertEqual(empty.accessibilityLabel, "none, paused")
    }
}
