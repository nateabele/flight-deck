import IntakeKit
import XCTest
@testable import FlightDeck

/// What the CONVERGENCE cell, the section heatmap and the churn lane say for each verdict
/// (spec §8). Each fixture is a cycle assessed by the engine from hand-made points, so the
/// words here are the engine's verdict read through the UI's models — never a second opinion.
final class ConvergenceCellModelTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")

    private func point(_ round: Int, _ changes: Int, agree: Double? = nil, churn: [String: Int] = [:],
                       model: ModelChoice? = nil, checkpoint: Int? = nil) -> ConvergencePoint {
        ConvergencePoint(checkpoint: checkpoint ?? round + 2, stage: .refine, round: round, changeCount: changes,
                         linesChurned: churn.values.reduce(0, +), agreeRatio: agree, sectionChurn: churn,
                         reviewerModel: model ?? codex)
    }

    private func cycle(_ points: [ConvergencePoint]) -> ConvergenceCycle {
        ConvergenceSeries.assess(.refine, points)
    }

    func testConvergingWordAndSpark() throws {
        let c = cycle([point(1, 41, agree: 0.7, churn: ["## 1. Overview": 8, "## 2. Technicians": 20]),
                       point(2, 14, agree: 0.82, churn: ["## 2. Technicians": 6]),
                       point(3, 5, agree: 0.9, churn: ["## 4. Dispatch rules": 3])])
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [c]))
        XCTAssertEqual(cell.word, "CONVERGING ↘")
        XCTAssertEqual(cell.spark, [41, 14, 5])
        XCTAssertEqual(cell.latest, 5)
        XCTAssertEqual(cell.tone, .normal)
        XCTAssertEqual(cell.discontinuities, [])
        XCTAssertEqual(cell.detail, "5 changes · settled")
        XCTAssertEqual(cell.cardLines.first, "41 → 14 → 5 changes · agreement 70% → 90% · settled")
        // Two of the three sections the cycle touched have been still since R2 or earlier.
        XCTAssertEqual(cell.cardLines.dropFirst().first, "2 of 3 sections still since R2")
        XCTAssertEqual(cell.action, "Converged: ⏭ to encode")
        XCTAssertEqual(cell.actionHeadline, "Converged: ⏭ to encode")
        XCTAssertNil(cell.actionDetail)
    }

    func testPlateau() throws {
        let c = cycle([point(1, 38, agree: 0.72, churn: ["## 4. Dispatch rules": 12, "## 5. Mobile check-in": 6]),
                       point(2, 14, agree: 0.74, churn: ["## 4. Dispatch rules": 7, "## 5. Mobile check-in": 5]),
                       point(3, 12, agree: 0.73, churn: ["## 4. Dispatch rules": 6, "## 6. Notifications": 5, "## 5. Mobile check-in": 9]),
                       point(4, 13, agree: 0.72, churn: ["## 4. Dispatch rules": 3, "## 5. Mobile check-in": 4, "## 6. Notifications": 4,
                                                          "## 7. Testing": 3])])
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [c]))
        XCTAssertEqual(cell.word, "PLATEAU →")
        XCTAssertEqual(cell.tone, .normal, "a plateau is not an exception; colour is for diverging only")
        XCTAssertEqual(cell.latest, 13)
        XCTAssertEqual(cell.detail, "13 changes · flat")
        XCTAssertTrue(cell.action.hasPrefix("Plateau: consider annotating"), cell.action)
        XCTAssertEqual(cell.actionHeadline, "Plateau: consider annotating §4 or stopping")
        XCTAssertEqual(cell.actionDetail, "Another round is unlikely to change much.")
    }

    func testDivergingIsAmberAndNamesSection() throws {
        let hot = "## 4. Dispatch rules"
        let c = cycle([point(1, 36, agree: 0.76, churn: [hot: 10, "## 2. Technicians": 20]),
                       point(2, 15, agree: 0.8, churn: [hot: 6, "## 2. Technicians": 6]),
                       point(3, 22, agree: 0.57, churn: [hot: 14, "## 3. Jobs": 8]),
                       point(4, 29, agree: 0.48, churn: [hot: 22, "## 3. Jobs": 6])])
        guard case .diverging(.hotSection(hot)) = c.verdict else { return XCTFail("fixture should be hot on §4: \(c.verdict)") }
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [c]))
        XCTAssertEqual(cell.word, "DIVERGING ↗")
        XCTAssertEqual(cell.tone, .amber)
        XCTAssertEqual(cell.detail, "29 changes · §4 keeps changing")
        XCTAssertEqual(cell.actionHeadline, "Diverging: §4 keeps changing")
        XCTAssertEqual(cell.actionDetail, "Refining more will not settle it; decide §4 yourself.")
        XCTAssertEqual(cell.hotSection, hot)
    }

    func testTooEarly() throws {
        XCTAssertNil(ConvergenceCellModel(cycles: []), "no refine or polish cycle yet: no cell at all")
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [cycle([point(1, 41, agree: 0.7)])]))
        XCTAssertEqual(cell.word, "TOO EARLY")
        XCTAssertEqual(cell.tone, .normal)
        XCTAssertEqual(cell.spark, [41])
        XCTAssertEqual(cell.latest, 41)
        XCTAssertEqual(cell.detail, "41 changes · one round")
        XCTAssertEqual(cell.action, "")
        XCTAssertNil(cell.actionHeadline)
    }

    /// The cell describes the CURRENT cycle only: a finished refine cycle's numbers are a
    /// different unit from polish's ops changed and must not leak into the polish sparkline.
    func testCurrentCycleIsTheLastOne() throws {
        let refine = cycle([point(1, 41, agree: 0.7), point(2, 14, agree: 0.82), point(3, 5, agree: 0.9)])
        let polish = ConvergenceSeries.assess(.polish, [
            ConvergencePoint(checkpoint: 7, stage: .polish, round: 1, changeCount: 9, linesChurned: 0),
            ConvergencePoint(checkpoint: 8, stage: .polish, round: 2, changeCount: 12, linesChurned: 0),
        ])
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [refine, polish]))
        XCTAssertEqual(cell.spark, [9, 12])
        XCTAssertEqual(cell.stage, .polish)
    }

    /// Review Focus 5: a trend across a reviewer swap is not a trend. The card says where the
    /// model changed and that the trend restarts there, once, and the sparkline marks the point.
    func testModelChangeIsCalledOutOnTheCard() throws {
        let c = cycle([point(1, 38, agree: 0.72, model: codex),
                       point(2, 14, agree: 0.74, model: codex),
                       point(3, 12, agree: 0.73, model: claude),
                       point(4, 13, agree: 0.72, model: claude)])
        XCTAssertEqual(c.trend.restartRound, 3)
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [c]))
        XCTAssertEqual(cell.discontinuities, [2])
        XCTAssertTrue(cell.cardLines.contains("Reviewer changed at R3 (codex gpt-6-sol → claude opus); the trend restarts there"),
                      "\(cell.cardLines)")
        XCTAssertFalse(cell.cardLines[0].contains("changed at R3"), "the series line must not say it twice: \(cell.cardLines[0])")
        // The verdict word survives the swap: the cell still says what the restarted trend is
        // (judged from R3 on), and says it where the LCD reads it — never blank, never a
        // verdict carried over from the other reviewer's rounds.
        XCTAssertEqual(cell.word, "PLATEAU →", "R3–R4 alone are flat; R1–R2 under codex fell steeply")
        XCTAssertTrue(cell.detail.hasSuffix("flat"), cell.detail)
    }

    /// An extend adds rounds past the ones the plan asked for; the card says which round was the
    /// first extra one and the sparkline marks it.
    func testExtendIsADiscontinuity() throws {
        let c = cycle([point(1, 41, agree: 0.7), point(2, 14, agree: 0.82), point(3, 12, agree: 0.8), point(4, 11, agree: 0.8)])
        let cell = try XCTUnwrap(ConvergenceCellModel(cycles: [c], plannedRounds: 3))
        XCTAssertEqual(cell.discontinuities, [3])
        XCTAssertTrue(cell.cardLines.contains("R4 is an extra round, past the 3 planned"), "\(cell.cardLines)")
        XCTAssertEqual(try XCTUnwrap(ConvergenceCellModel(cycles: [c], plannedRounds: 4)).discontinuities, [])
    }

    func testHeatmapNormalizationAndHot() {
        let hot = "## 4. Dispatch rules"
        let c = cycle([point(1, 36, agree: 0.76, churn: [hot: 10, "## 2. Technicians": 20, "## 10. Rollout": 2]),
                       point(2, 15, agree: 0.8, churn: [hot: 6, "## 2. Technicians": 6]),
                       point(3, 22, agree: 0.57, churn: [hot: 14, "## 3. Jobs": 8]),
                       point(4, 29, agree: 0.48, churn: [hot: 40, "## 3. Jobs": 6])])
        let map = HeatmapModel(cycle: c)
        // Plan order by section number, not by dictionary order or by string ("10" after "4").
        XCTAssertEqual(map.sections, ["## 2. Technicians", "## 3. Jobs", hot, "## 10. Rollout"])
        XCTAssertEqual(map.labels, ["§2", "§3", "§4", "§10"])
        XCTAssertEqual(map.names, ["Technicians", "Jobs", "Dispatch rules", "Rollout"])
        XCTAssertEqual(map.rounds, ["R1", "R2", "R3", "R4"])
        XCTAssertEqual(map.checkpoints, [3, 4, 5, 6])
        XCTAssertEqual(map.counts, [36, 15, 22, 29])
        // Luminance is each cell over the cycle's largest cell, so the brightest cell is 1.
        XCTAssertEqual(map.cells[2], [0.25, 0.15, 0.35, 1.0])
        XCTAssertEqual(map.cells[0], [0.5, 0.15, 0, 0])
        XCTAssertEqual(map.lines[2], [10, 6, 14, 40])
        XCTAssertEqual(map.agree, [0.76, 0.8, 0.57, 0.48])
        XCTAssertEqual(map.hot, [hot])
        XCTAssertEqual(map.title, "SECTION CHURN · REFINE ×4")
        XCTAssertEqual(map.row(of: hot), 2)
    }

    func testHeatmapWithNoChurnIsEmptyButKeepsRounds() {
        let map = HeatmapModel(cycle: cycle([point(1, 3), point(2, 1)]))
        XCTAssertEqual(map.sections, [])
        XCTAssertEqual(map.rounds, ["R1", "R2"])
        XCTAssertEqual(map.agree, [nil, nil])
    }

    func testChurnLaneStillSince() {
        let hot = "## 4. Dispatch rules"
        let c = cycle([point(1, 36, agree: 0.76, churn: [hot: 10, "## 2. Technicians": 20, "## 1. Overview": 8]),
                       point(2, 15, agree: 0.8, churn: [hot: 6, "## 2. Technicians": 6]),
                       point(3, 22, agree: 0.57, churn: [hot: 14, "## 3. Jobs": 8]),
                       point(4, 29, agree: 0.48, churn: [hot: 20, "## 3. Jobs": 6])])

        let settled = ChurnLaneModel(cycle: c, section: "## 2. Technicians")
        XCTAssertEqual(settled.bars, [1.0, 0.3, 0, 0])
        XCTAssertEqual(settled.stillSince, "still since R2")
        XCTAssertFalse(settled.hot)
        XCTAssertEqual(settled.caption, "still since R2")

        let early = ChurnLaneModel(cycle: c, section: "## 1. Overview")
        XCTAssertEqual(early.stillSince, "still since R1")

        let settling = ChurnLaneModel(cycle: c, section: "## 3. Jobs")
        XCTAssertNil(settling.stillSince, "changed in the last round: not still")
        XCTAssertEqual(settling.caption, "settling", "shrinking in the last round")

        let flat = cycle([point(1, 9, churn: ["## 7. Testing": 4]), point(2, 5, churn: ["## 7. Testing": 2]),
                          point(3, 4, churn: ["## 7. Testing": 2, "## 5. Mobile": 1]), point(4, 3, churn: ["## 5. Mobile": 3])])
        XCTAssertEqual(ChurnLaneModel(cycle: flat, section: "## 7. Testing").caption, "still since R3")
        XCTAssertEqual(ChurnLaneModel(cycle: flat, section: "## 5. Mobile").caption, "moving", "grew from 1 to 3")

        let flipping = ChurnLaneModel(cycle: c, section: hot)
        XCTAssertTrue(flipping.hot)
        XCTAssertNil(flipping.stillSince)
        XCTAssertEqual(flipping.caption, "changed in 4 of 4")
        XCTAssertEqual(flipping.lines, [10, 6, 14, 20])

        let untouched = ChurnLaneModel(cycle: c, section: "## 9. Glossary")
        XCTAssertEqual(untouched.bars, [0, 0, 0, 0])
        XCTAssertNil(untouched.stillSince, "never changed in this cycle: nothing to be still since")
        XCTAssertNil(untouched.caption)
        XCTAssertTrue(untouched.isEmpty, "a section the cycle never touched draws no marker")
    }

    /// The hover on an amber marker lists the section's proposals round by round, matched to
    /// the heading however the reviewer spelled it, with the integrator's verdict when kept.
    func testSectionVersionsFromChangesJSON() throws {
        let hot = "## 4. Dispatch rules"
        let c = cycle([point(1, 2, churn: [hot: 4], checkpoint: 10), point(2, 1, churn: [hot: 3], checkpoint: 11)])
        let files: [Int: [String: Data]] = [
            10: ["changes.json": try IntakeJSON.encoder.encode([
                ProposedChange(section: "4. Dispatch rules", rationale: "r", edit: "Unassigned for 24 hours, then nearest."),
                ProposedChange(section: "## 2. Technicians", rationale: "r", edit: "Not this one."),
            ]), "verdicts.json": try IntakeJSON.encoder.encode([ChangeVerdict(index: 0, verdict: .somewhat)])],
            11: ["changes.json": try IntakeJSON.encoder.encode([
                ProposedChange(section: "§4 Dispatch rules", rationale: "r", edit: "Unassigned until a dispatcher assigns it."),
            ])],
        ]
        let versions = ChurnLaneModel.versions(cycle: c, section: hot) { files[$0]?[$1] }
        XCTAssertEqual(versions, [
            SectionVersion(round: "R1", text: "Unassigned for 24 hours, then nearest.", verdict: .somewhat),
            SectionVersion(round: "R2", text: "Unassigned until a dispatcher assigns it.", verdict: nil),
        ])
    }

    /// The amber highlight (spec §8.2) goes on the sentence of the hot section that the rounds
    /// kept proposing — matched by words in two or more rounds — and nowhere else, not even an
    /// identical sentence in another section.
    func testFlippingSentenceIsTheOneTwoRoundsProposed() {
        let plan = """
        ## 3. Jobs

        - A job with no candidate stays Unassigned until a dispatcher assigns it.

        ## 4. Dispatch rules

        - A job is offered to the best-scoring technician. A job with no candidate stays Unassigned until a dispatcher assigns it (R4).
        - Max 6 jobs per technician per day.
        """
        let versions = [
            SectionVersion(round: "R1", text: "A job with no candidate stays Unassigned for 24 hours, then goes to the nearest technician.", verdict: nil),
            SectionVersion(round: "R2", text: "A job with no candidate stays Unassigned until a dispatcher assigns it.", verdict: nil),
            SectionVersion(round: "R4", text: "A job with no candidate stays unassigned until a dispatcher assigns it", verdict: nil),
        ]
        let ranges = ChurnLaneModel.flippingSentences(in: plan, section: "## 4. Dispatch rules", versions: versions)
        let ns = plan as NSString
        XCTAssertEqual(ranges.map { ns.substring(with: $0) },
                       ["A job with no candidate stays Unassigned until a dispatcher assigns it (R4)."])
        XCTAssertEqual(ChurnLaneModel.flippingSentences(in: plan, section: "## 4. Dispatch rules", versions: Array(versions.prefix(2))), [],
                       "one round proposing it is a change, not a flip")
    }

    /// Where the churn highlight meets the human's green insertion tint, the insertion wins: the
    /// churn ranges are cut around it.
    func testChurnHighlightGivesWayToInsertions() {
        let cut = ChurnLaneModel.subtracting([NSRange(location: 10, length: 20)],
                                             [NSRange(location: 15, length: 5), NSRange(location: 28, length: 10)])
        XCTAssertEqual(cut, [NSRange(location: 10, length: 5), NSRange(location: 20, length: 8)])
    }
}
