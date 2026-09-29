import XCTest
import IntakeKit

/// `ConvergenceSeries` is a pure fold over `[Checkpoint]` plus whatever checkpoint files a
/// loader hands it, so every fixture here is a tape built in memory and a dictionary of
/// files — no store, no runner.
final class ConvergenceSeriesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)
    func model(_ name: String) -> ModelChoice { ModelChoice(harness: .codex, model: name, effort: "high") }

    /// A tally whose agree ratio ((agree + ½·somewhat) / verdicts) is exactly `ratio`.
    func tally(_ ratio: Double) -> VerdictTally {
        let agree = Int((ratio * 100).rounded())
        return VerdictTally(agree: agree, somewhat: 0, disagree: 100 - agree)
    }

    /// Checkpoints are numbered in the order they are appended, like the runner does.
    struct TapeFixture {
        var checkpoints: [Checkpoint] = []
        var files: [Int: [String: Data]] = [:]
        var loadFile: (Int, String) -> Data? { { [files] id, path in files[id]?[path] } }

        @discardableResult
        mutating func add(_ stage: Stage, round: Int = 0, changes: Int? = nil, tally: VerdictTally? = nil,
                          model: ModelChoice? = nil, edges: Int? = nil, plan: String? = nil,
                          files extra: [String: String] = [:]) -> Int {
            let id = checkpoints.count + 1
            let role = stage == .refine ? "reviewer" : stage == .polish ? "polisher" : "drafter"
            let slots = model.map { [SlotOutcome(role: role, used: $0, requested: $0, status: .ok)] } ?? []
            checkpoints.append(Checkpoint(id: id, parent: id == 1 ? nil : id - 1, stage: stage, round: round, major: true,
                                          createdAt: Date(timeIntervalSince1970: 0),
                                          record: RoundRecord(slots: slots, changeCount: changes, tally: tally,
                                                              edgesChanged: edges)))
            var f = extra.mapValues { Data($0.utf8) }
            if let plan { f["plan.md"] = Data(plan.utf8) }
            files[id] = f
            return id
        }
    }

    /// Draft, synthesis, then one refine round per count, with agreement ratios alongside.
    func refineTape(_ counts: [Int], agree: [Double?]? = nil, models: [String]? = nil) -> TapeFixture {
        var t = TapeFixture()
        t.add(.draft)
        t.add(.synthesis, changes: 30, tally: tally(0.5))
        for (i, c) in counts.enumerated() {
            let ratio = agree.map { $0[i] } ?? nil
            t.add(.refine, round: i + 1, changes: c, tally: ratio.map(tally), model: model(models?[i] ?? "A"))
        }
        return t
    }

    func onlyCycle(_ t: TapeFixture, file: StaticString = #filePath, line: UInt = #line) throws -> ConvergenceCycle {
        let cycles = ConvergenceSeries.cycles(t.checkpoints, loadFile: t.loadFile)
        XCTAssertEqual(cycles.count, 1, file: file, line: line)
        return try XCTUnwrap(cycles.first, file: file, line: line)
    }

    // MARK: - Verdicts

    func testSingleRefineRoundIsTooEarly() throws {
        let cycle = try onlyCycle(refineTape([41], agree: [0.7]))
        XCTAssertEqual(cycle.verdict, .tooEarly)
        XCTAssertEqual(cycle.explanation, "one round, nothing to compare yet")
    }

    func testShrinkingCountsWithRisingAgreementConvergeAndSettle() throws {
        let cycle = try onlyCycle(refineTape([41, 14, 5], agree: [0.7, 0.82, 0.9]))
        XCTAssertEqual(cycle.verdict, .converging(settled: true))
        XCTAssertEqual(cycle.points.map(\.changeCount), [41, 14, 5])
        XCTAssertEqual(try XCTUnwrap(cycle.trend.changeRatio), 5.0 / 14.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cycle.trend.agreeDelta), 0.08, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(cycle.trend.logSlope), 0)
    }

    func testConvergingButAboveFloorIsNotSettled() throws {
        let cycle = try onlyCycle(refineTape([41, 20, 11], agree: [0.7, 0.82, 0.9]))
        XCTAssertEqual(cycle.verdict, .converging(settled: false))
    }

    /// A reviewer that found nothing skips the integrator, so there is no tally at all — and
    /// that round is the clearest convergence signal the engine has.
    func testZeroProposedChangesIsSettledEvenWithoutTally() throws {
        let cycle = try onlyCycle(refineTape([12, 0], agree: [0.8, nil]))
        XCTAssertNil(cycle.points.last?.agreeRatio)
        XCTAssertEqual(cycle.verdict, .converging(settled: true))
    }

    func testFlatCountsArePlateau() throws {
        XCTAssertEqual(try onlyCycle(refineTape([38, 14, 12, 13], agree: [0.7, 0.72, 0.74, 0.73])).verdict, .plateau)
        XCTAssertEqual(try onlyCycle(refineTape([14, 12, 13], agree: [0.72, 0.74, 0.73])).verdict, .plateau)
    }

    /// Sketch caps refinement at 2: a verdict from two points is allowed, but it says so.
    func testTwoPointPlateauIsFlaggedThin() throws {
        let cycle = try onlyCycle(refineTape([14, 12], agree: [0.72, 0.74]))
        XCTAssertEqual(cycle.verdict, .plateau)
        XCTAssertTrue(cycle.explanation.hasSuffix(" · only 2 rounds"), cycle.explanation)
    }

    func testGrowthOver25PercentAndThreeIsDiverging() throws {
        XCTAssertEqual(try onlyCycle(refineTape([15, 22], agree: [0.8, 0.8])).verdict, .diverging(reason: .growing))
    }

    func testGrowthUnderThreeAbsoluteIsNot() throws {
        XCTAssertEqual(try onlyCycle(refineTape([4, 5], agree: [0.8, 0.8])).verdict, .plateau)
    }

    func testAgreementDropOf15PointsIsDivergingEvenWhileCountsShrink() throws {
        let cycle = try onlyCycle(refineTape([20, 10], agree: [0.8, 0.6]))
        XCTAssertEqual(cycle.verdict, .diverging(reason: .agreementFell))
        // 14 points is inside the tolerance for "fell", but more than converging may lose.
        XCTAssertEqual(try onlyCycle(refineTape([20, 10], agree: [0.8, 0.66])).verdict, .plateau)
    }

    /// The integrator's counts can disagree with the number of proposals; the ratio is over the
    /// verdicts it actually gave, not over `changeCount`.
    func testIntegratorTallyMismatchUsesVerdictSumAsDenominator() throws {
        var t = TapeFixture()
        t.add(.refine, round: 1, changes: 3, tally: VerdictTally(agree: 1, somewhat: 1, disagree: 0), model: model("A"))
        XCTAssertEqual(try XCTUnwrap(try onlyCycle(t).points.first?.agreeRatio), 0.75, accuracy: 1e-9)
    }

    // MARK: - Hot and reopened sections

    func point(_ round: Int, _ changes: Int, churn: [String: Int]) -> ConvergencePoint {
        ConvergencePoint(checkpoint: round, stage: .refine, round: round, changeCount: changes, linesChurned: 0,
                         agreeRatio: 0.75, sectionChurn: churn)
    }

    /// A hot section is the oscillation red flag: changed in each of the last 3 rounds, not
    /// shrinking, and at least 30% of the last round's churn. The plateau's §4 at 24% of the
    /// round is not hot; the diverging fixture's §4 at 74% is.
    func testHotSectionRequiresThreeConsecutiveRoundsAndThirtyPercentShare() {
        let plateau = ConvergenceSeries.assess(.refine, [
            // §2 carries most of the churn but is shrinking, so it is not hot either.
            point(1, 14, churn: ["## 4. Rollout": 20, "## 2. Design": 90]),
            point(2, 12, churn: ["## 4. Rollout": 22, "## 2. Design": 80]),
            point(3, 13, churn: ["## 4. Rollout": 24, "## 2. Design": 76]),
        ])
        XCTAssertNil(plateau.trend.hotSection)
        XCTAssertEqual(plateau.verdict, .plateau)

        let diverging = ConvergenceSeries.assess(.refine, [
            point(1, 14, churn: ["## 4. Rollout": 48, "## 2. Design": 10]),
            point(2, 12, churn: ["## 4. Rollout": 30, "## 2. Design": 10]),
            point(3, 11, churn: ["## 4. Rollout": 78, "## 2. Design": 20]),
            point(4, 12, churn: ["## 4. Rollout": 131, "## 2. Design": 46]),
        ])
        XCTAssertEqual(diverging.trend.hotSection, "## 4. Rollout")
        XCTAssertEqual(diverging.verdict, .diverging(reason: .hotSection("## 4. Rollout")))
        XCTAssertEqual(diverging.explanation, "§4 changed in all 4 rounds: 48 → 30 → 78 → 131 lines")

        // Two rounds of churn is not yet a run of three.
        let short = ConvergenceSeries.assess(.refine, [
            point(1, 14, churn: ["## 2. Design": 10]),
            point(2, 12, churn: ["## 4. Rollout": 30]),
            point(3, 11, churn: ["## 4. Rollout": 78]),
        ])
        XCTAssertNil(short.trend.hotSection)
        // Nor is a section whose churn is shrinking.
        let shrinking = ConvergenceSeries.assess(.refine, [
            point(1, 14, churn: ["## 4. Rollout": 90]),
            point(2, 12, churn: ["## 4. Rollout": 60]),
            point(3, 11, churn: ["## 4. Rollout": 30]),
        ])
        XCTAssertNil(shrinking.trend.hotSection)
    }

    /// A section a round puts back the way an earlier round had it — here §4 flips A → B → A —
    /// is the methodology's oscillation, read off the stored plans with no schema change.
    func testReopenedSectionIsDiverging() throws {
        let head = "# Plan\n## 1. Scope\nkeep this\n## 4. Rollout\n"
        let a = head + "- ship behind a flag\n- roll out to staff\n- then to everyone\n"
        let b = head + "- ship to everyone at once\n- no flag needed\n- watch the dashboards\n"
        var t = TapeFixture()
        t.add(.synthesis, changes: 5, tally: tally(0.8), plan: head + "tbd\n")
        t.add(.refine, round: 1, changes: 12, tally: tally(0.8), model: model("A"), plan: a)
        t.add(.refine, round: 2, changes: 11, tally: tally(0.8), model: model("A"), plan: b)
        t.add(.refine, round: 3, changes: 10, tally: tally(0.8), model: model("A"), plan: a)
        let cycle = try onlyCycle(t)
        XCTAssertEqual(cycle.points.map(\.reopenedSections), [[], ["## 4. Rollout"], ["## 4. Rollout"]])
        XCTAssertEqual(cycle.verdict, .diverging(reason: .reopened("## 4. Rollout")))
        XCTAssertEqual(cycle.explanation, "§4 reopened in R2 and R3: 4 → 6 → 6 lines")
        XCTAssertEqual(cycle.suggestedAction, "Diverging: §4 keeps changing. Refining more will not settle it; decide §4 yourself.")
    }

    /// One reversal is a correction; it takes a second before the section "keeps reopening".
    func testASingleReversalIsNotYetDiverging() throws {
        let head = "# Plan\n## 4. Rollout\n"
        var t = TapeFixture()
        t.add(.synthesis, plan: head + "tbd\n")
        t.add(.refine, round: 1, changes: 12, tally: tally(0.8), model: model("A"), plan: head + "a1\na2\n")
        t.add(.refine, round: 2, changes: 6, tally: tally(0.8), model: model("A"), plan: head + "b1\nb2\n")
        let cycle = try onlyCycle(t)
        XCTAssertEqual(cycle.points.last?.reopenedSections, ["## 4. Rollout"])
        XCTAssertEqual(cycle.verdict, .converging(settled: false))
    }

    // MARK: - Cycles

    func testCyclesSplitRefineAndPolishAndIgnoreDraftSynthesisEncode() {
        var t = TapeFixture()
        t.add(.draft)
        t.add(.synthesis, changes: 30, tally: tally(0.5))
        t.add(.refine, round: 1, changes: 20, tally: tally(0.8), model: model("A"))
        t.add(.refine, round: 2, changes: 9, tally: tally(0.85), model: model("A"))
        t.add(.encode, changes: 57)   // ops.count — a different unit, never in a series
        t.add(.polish, round: 1, changes: 12, model: model("P"), edges: 4)
        t.add(.polish, round: 2, changes: 3, model: model("P"), edges: 0)
        t.add(.freshEyes, changes: 2, model: model("P"))
        let cycles = ConvergenceSeries.cycles(t.checkpoints, loadFile: t.loadFile)
        XCTAssertEqual(cycles.map(\.stage), [.refine, .polish])
        XCTAssertEqual(cycles.map { $0.points.map(\.changeCount) }, [[20, 9], [12, 3]])
        XCTAssertEqual(cycles[1].points.map(\.edgesChanged), [4, 0])
        XCTAssertEqual(cycles[1].points.map(\.agreeRatio), [nil, nil])
        // Polish has no agreement, so settling is the count test alone.
        XCTAssertEqual(cycles[1].verdict, .converging(settled: true))
    }

    /// ＋ Extend adds R4 past the cap; it is the same stretch of refinement, not a new one.
    func testExtendedRefineStaysOneCycle() throws {
        let cycle = try onlyCycle(refineTape([30, 20, 14, 8], agree: [0.7, 0.75, 0.8, 0.86]))
        XCTAssertEqual(cycle.points.map(\.round), [1, 2, 3, 4])
    }

    /// A fallback reviewer is a different model with a different issue budget, so the trend
    /// restarts at the swap rather than comparing across it.
    func testReviewerModelChangeRestartsTheTrend() throws {
        let cycle = try onlyCycle(refineTape([40, 20, 18, 9], agree: [0.7, 0.75, 0.8, 0.8], models: ["A", "A", "B", "B"]))
        XCTAssertTrue(cycle.trend.modelChanged)
        XCTAssertEqual(cycle.trend.restartRound, 3)
        XCTAssertEqual(try XCTUnwrap(cycle.trend.changeRatio), 0.5, accuracy: 1e-9)
        XCTAssertEqual(cycle.verdict, .converging(settled: false), "9 is above 15% of 18, R3's count")
        XCTAssertEqual(cycle.explanation,
                       "18 → 9 changes · agreement 80% → 80% · reviewer changed at R3; the trend restarts there")

        // A swap on the very last round leaves one point to compare: too early again.
        let fresh = try onlyCycle(refineTape([40, 20, 18], agree: [0.7, 0.75, 0.8], models: ["A", "A", "B"]))
        XCTAssertEqual(fresh.verdict, .tooEarly)
        XCTAssertEqual(fresh.explanation, "reviewer changed at R3; the trend restarts there")
    }

    // MARK: - Section churn

    /// Each checkpoint's plan against the EFFECTIVE plan of the plan checkpoint before it —
    /// the one that round actually started from, so a human's edit is not the round's churn.
    /// A draft checkpoint's plan is its first surviving draft.
    func testSectionChurnAttributesLinesToHeadingsAcrossCheckpoints() {
        var t = TapeFixture()
        let draft = t.add(.draft, files: ["drafts/1.md": "## A\n- a\n## B\n- b\n"])
        t.checkpoints[draft - 1].record.slots = [
            SlotOutcome(role: "drafter", used: model("X"), requested: model("X"), status: .failed),
            SlotOutcome(role: "drafter", used: model("Y"), requested: model("Y"), status: .ok),
        ]
        let syn = t.add(.synthesis, plan: "## A\n- a2\n## B\n- b\n", files: ["plan.user.md": "## A\n- a2\n## B\n- b\n- mine\n"])
        let r1 = t.add(.refine, round: 1, plan: "## A\n- a2\n## Bee\n- b\n- mine\n- more\n")
        let churn = ConvergenceSeries.sectionChurn(t.checkpoints, loadFile: t.loadFile)
        XCTAssertNil(churn[draft], "nothing before the first plan")
        XCTAssertEqual(churn[syn], ["## A": 2])
        XCTAssertEqual(churn[r1], ["## Bee": 3], "the rename maps through, and `mine` was the human's, not R1's")
    }

    func testMissingPriorPlanDropsOnlySectionChurn() throws {
        var t = TapeFixture()
        t.add(.synthesis)   // no plan file on disk
        t.add(.refine, round: 1, changes: 20, tally: tally(0.8), model: model("A"), plan: "## A\na\n")
        t.add(.refine, round: 2, changes: 8, tally: tally(0.9), model: model("A"), plan: "## A\na2\n")
        let cycle = try onlyCycle(t)
        XCTAssertEqual(cycle.points.map(\.sectionChurn), [[:], ["## A": 2]])
        XCTAssertEqual(cycle.points.map(\.changeCount), [20, 8])
        XCTAssertEqual(cycle.verdict, .converging(settled: false))
    }

    // MARK: - Novel vs repeated

    func changesJSON(_ changes: [ProposedChange]) -> String {
        String(decoding: try! IntakeJSON.encoder.encode(changes), as: UTF8.self)
    }
    func verdictsJSON(_ verdicts: [Verdict]) -> String {
        String(decoding: try! IntakeJSON.encoder.encode(verdicts.enumerated().map { ChangeVerdict(index: $0, verdict: $1) }),
               as: UTF8.self)
    }

    /// A repeat is the same idea in the same section, however it is worded: the section must
    /// match and the words overlap. The same words under another section are a new proposal.
    func testRepeatDetectionJaccardSameSectionOnly() throws {
        let r1 = [ProposedChange(section: "## 4. Rollout", rationale: "Roll out behind a feature flag to staff first",
                                 edit: "+ Ship behind the `dark-mode` flag, enabled for staff"),
                  ProposedChange(section: "## 2. Design", rationale: "Name the token file", edit: "+ tokens.json")]
        let r2 = [ProposedChange(section: "## 4. rollout", rationale: "Rolling out behind feature flags for staff first!",
                                 edit: "+ Ship behind the dark-mode flag; enable for staff"),
                  ProposedChange(section: "## 3. Testing", rationale: "Roll out behind a feature flag to staff first",
                                 edit: "+ Ship behind the `dark-mode` flag, enabled for staff"),
                  ProposedChange(section: "## 2. Design", rationale: "Support high contrast", edit: "+ a contrast mode")]
        var t = TapeFixture()
        t.add(.refine, round: 1, changes: 2, tally: tally(0.8), model: model("A"), files: ["changes.json": changesJSON(r1)])
        t.add(.refine, round: 2, changes: 3, tally: tally(0.8), model: model("A"), files: ["changes.json": changesJSON(r2)])
        let cycle = try onlyCycle(t)
        XCTAssertEqual(cycle.points.map(\.repeatCount), [0, 1])
    }

    /// Without the proposals on disk (a tape from before they were kept) there is nothing to
    /// compare, which is not the same as "no repeats".
    func testRepeatAndReopenCountsAreUnknownWithoutChangesFiles() throws {
        let cycle = try onlyCycle(refineTape([20, 10], agree: [0.8, 0.85]))
        XCTAssertEqual(cycle.points.map(\.repeatCount), [nil, nil])
        XCTAssertEqual(cycle.points.map(\.reopenCount), [nil, nil])
    }

    /// Re-proposing a change the integrator rejected is a reopen; re-proposing one it took is
    /// only a repeat.
    func testReopenOfDisagreedChangeCounts() throws {
        let rejected = ProposedChange(section: "## 2. Design", rationale: "Drop the settings screen entirely",
                                      edit: "- ## Settings screen")
        let taken = ProposedChange(section: "## 1. Scope", rationale: "Mention Safari support", edit: "+ Safari 17+")
        var t = TapeFixture()
        t.add(.refine, round: 1, changes: 2, tally: tally(0.5), model: model("A"),
              files: ["changes.json": changesJSON([rejected, taken]), "verdicts.json": verdictsJSON([.disagree, .agree])])
        t.add(.refine, round: 2, changes: 2, tally: tally(0.5), model: model("A"),
              files: ["changes.json": changesJSON([rejected, taken])])
        let cycle = try onlyCycle(t)
        XCTAssertEqual(cycle.points.map(\.repeatCount), [0, 2])
        XCTAssertEqual(cycle.points.map(\.reopenCount), [0, 1])
    }

    // MARK: - Words

    func testExplanationStringsPerVerdict() throws {
        XCTAssertEqual(try onlyCycle(refineTape([41, 14, 5], agree: [0.7, 0.82, 0.9])).explanation,
                       "41 → 14 → 5 changes · agreement 70% → 90% · settled")
        XCTAssertEqual(try onlyCycle(refineTape([41, 20, 11], agree: [0.7, 0.82, 0.9])).explanation,
                       "41 → 20 → 11 changes · agreement 70% → 90%")
        XCTAssertEqual(try onlyCycle(refineTape([15, 22, 29], agree: [0.8, 0.8, 0.8])).explanation,
                       "changes rose 15 → 22 → 29")
        XCTAssertEqual(try onlyCycle(refineTape([20, 10], agree: [0.8, 0.57])).explanation,
                       "agreement fell 80% → 57%")

        let plateau = ConvergenceSeries.assess(.refine, [
            ConvergencePoint(checkpoint: 1, stage: .refine, round: 1, changeCount: 14, linesChurned: 0, agreeRatio: 0.72,
                             sectionChurn: ["## 4. Rollout": 20, "## 2. Design": 6]),
            ConvergencePoint(checkpoint: 2, stage: .refine, round: 2, changeCount: 12, linesChurned: 0, agreeRatio: 0.74,
                             sectionChurn: ["## 4. Rollout": 22, "## 2. Design": 70]),
            ConvergencePoint(checkpoint: 3, stage: .refine, round: 3, changeCount: 13, linesChurned: 0, agreeRatio: 0.73,
                             sectionChurn: ["## 4. Rollout": 10, "## 2. Design": 10]),
        ])
        XCTAssertEqual(plateau.explanation, "14 → 12 → 13 changes · agreement flat near 73% · §2 moved most")
        XCTAssertEqual(plateau.suggestedAction,
                       "Plateau: consider annotating §2 or stopping. Another round is unlikely to change much.")

        let growing = try onlyCycle(refineTape([15, 22], agree: [0.8, 0.8]))
        XCTAssertEqual(growing.suggestedAction,
                       "Diverging: each round finds more. Step back and reframe the plan rather than refining it.")
    }

    func testSuggestedActionPerVerdict() throws {
        XCTAssertEqual(try onlyCycle(refineTape([41, 14, 5], agree: [0.7, 0.82, 0.9])).suggestedAction,
                       "Converged: ⏭ to encode")
        XCTAssertEqual(try onlyCycle(refineTape([41, 20, 11], agree: [0.7, 0.82, 0.9])).suggestedAction,
                       "Converging: one more round should help")
        XCTAssertEqual(try onlyCycle(refineTape([20, 10], agree: [0.8, 0.6])).suggestedAction,
                       "Diverging: the integrator is rejecting more. Review the last round's diffs before running another.")
        XCTAssertEqual(try onlyCycle(refineTape([41], agree: [0.7])).suggestedAction, "")
        // A plateau with no section data names no section.
        XCTAssertEqual(try onlyCycle(refineTape([14, 12, 13], agree: [0.72, 0.74, 0.73])).suggestedAction,
                       "Plateau: consider annotating a section or stopping. Another round is unlikely to change much.")
    }

    // MARK: - Cross-check rounds (coverage spec §6)

    func testCrossCheckPointCountsIssuesNotProposals() throws {
        // R1 is a cross-check of 6 proposals in 4 issues ([0,1], [2,3], 4, 5); R2 is a plain round of 2.
        let codex = model("A")
        let claude = ModelChoice(harness: .claude, model: "B", effort: "high")
        let r1 = Checkpoint(id: 1, stage: .refine, round: 1, major: false, createdAt: t0,
                            record: RoundRecord(slots: [
                                SlotOutcome(role: "reviewer", used: codex, requested: codex, status: .ok),
                                SlotOutcome(role: "crossReviewer", used: claude, requested: claude, status: .ok),
                                SlotOutcome(role: "integrator", used: claude, requested: claude, status: .ok)],
                                                changeCount: 6))
        let r2 = Checkpoint(id: 2, stage: .refine, round: 2, major: true, createdAt: t0,
                            record: RoundRecord(slots: [SlotOutcome(role: "reviewer", used: codex, requested: codex, status: .ok)],
                                                changeCount: 2))
        let record = CrossCheckRecord(proposers: [0, 1, 0, 1, 0, 1], families: [.codex, .claude],
                                      clusters: [[0, 1], [2, 3]], blindOrderSeed: 1)
        let files: [Int: [String: Data]] = [1: [CrossCheckRecord.fileName: try IntakeJSON.encoder.encode(record)]]
        let cycle = try XCTUnwrap(ConvergenceSeries.cycles([r1, r2]) { files[$0]?[$1] }.first)
        XCTAssertEqual(cycle.points.map(\.changeCount), [4, 2])
        XCTAssertEqual(cycle.points.map(\.crossCheck), [true, false])
        XCTAssertFalse(cycle.trend.modelChanged, "the primary reviewer names the trend's model")
    }

    func testCrossCheckWithoutClustersFallsBackToTextClusters() throws {
        let same = ProposedChange(section: "## Auth", rationale: "tokens expire too late", edit: "shorten token expiry to 15 minutes")
        let twin = ProposedChange(section: "## Auth", rationale: "token expiry too late", edit: "shorten the token expiry to 15 minutes")
        let other = ProposedChange(section: "## Data", rationale: "no backups", edit: "add nightly backups")
        XCTAssertEqual(ConvergenceSeries.textClusters([same, other, twin]), [[0, 2]])
        XCTAssertNil(ConvergenceSeries.textClusters([same, other]))
    }
}
