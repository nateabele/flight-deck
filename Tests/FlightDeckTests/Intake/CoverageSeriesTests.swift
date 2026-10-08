import XCTest
import IntakeKit

/// Coverage spec §5: counting accepted issues per family, Chapman's estimate and the bands.
final class CoverageSeriesTests: XCTestCase {
    /// `a` issues only family A raised, `b` only B, `shared` raised by both, all accepted; plus
    /// `rejected` proposals from A the integrator disagreed with.
    private func reading(a: Int, b: Int, shared: Int, rejected: Int = 0, clusters given: Bool = true,
                         families: [AgentID] = [.codex, .claude], verdicts: Bool = true) -> CoverageReading {
        var proposers: [Int] = [], clusters: [[Int]] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = []
        func add(_ p: Int, _ text: String, _ v: Verdict) -> Int {
            proposers.append(p); changes.append(ProposedChange(section: "## \(text)", rationale: text, edit: text))
            vs.append(ChangeVerdict(index: changes.count - 1, verdict: v)); return changes.count - 1
        }
        for i in 0..<a { _ = add(0, "a\(i)", .agree) }
        for i in 0..<b { _ = add(1, "b\(i)", .somewhat) }
        for i in 0..<shared { clusters.append([add(0, "s\(i)", .agree), add(1, "s\(i)", .agree)]) }
        for i in 0..<rejected { _ = add(0, "r\(i)", .disagree) }
        let record = CrossCheckRecord(proposers: proposers, families: families,
                                      clusters: given ? (clusters.isEmpty ? nil : clusters) : nil, blindOrderSeed: 1)
        return CoverageSeries.reading(checkpoint: 3, round: 1, record: record, changes: changes, verdicts: verdicts ? vs : nil)
    }

    func testChapman() {
        XCTAssertEqual(CoverageSeries.chapman(n1: 20, n2: 18, both: 15), 21.0 * 19.0 / 16.0 - 1, accuracy: 1e-9)
        XCTAssertEqual(CoverageSeries.chapman(n1: 3, n2: 4, both: 0), 19, accuracy: 1e-9, "finite at no overlap")
    }

    /// The handoff's worked examples: 20/18/15 is saturated, 20/18/4 is far from it.
    func testWorkedExamples() {
        let sat = reading(a: 5, b: 3, shared: 15)
        XCTAssertEqual([sat.n1, sat.n2, sat.both, sat.found], [20, 18, 15, 23])
        XCTAssertEqual(sat.unfound, 1)   // N̂ = 21·19/16 − 1 ≈ 23.9, found 23
        XCTAssertEqual(sat.band, .saturated)
        let far = reading(a: 16, b: 14, shared: 4)
        XCTAssertEqual(far.band, .manyLeft)
        XCTAssertGreaterThan(far.unfound ?? 0, 6)
    }

    func testBandBoundariesInOrder() {
        XCTAssertEqual(reading(a: 1, b: 1, shared: 0).band, .saturated, "found ≤ 2 beats no-overlap")
        XCTAssertEqual(reading(a: 0, b: 0, shared: 0).band, .saturated, "nothing found by either (Review Focus 3)")
        XCTAssertEqual(reading(a: 3, b: 3, shared: 0).band, .noOverlap)
        XCTAssertEqual(reading(a: 6, b: 6, shared: 6).band, .fewLeft)   // 12/12/6: N̂ = 169/7 − 1 ≈ 23.1, found 18 → 5
        XCTAssertEqual(reading(a: 5, b: 3, shared: 15, families: [.claude, .claude]).band, .sameFamily)
        XCTAssertNil(reading(a: 5, b: 3, shared: 15, families: [.claude, .claude]).unfound)
        XCTAssertEqual(reading(a: 5, b: 3, shared: 15, verdicts: false).band, .unmeasured)
    }

    func testRejectedProposalsAreNotCoverage() {
        let r = reading(a: 2, b: 2, shared: 6, rejected: 4)
        XCTAssertEqual(r.n1, 8); XCTAssertEqual(r.rejectedA, 4); XCTAssertEqual(r.rejectedB, 0)
    }

    func testCorrelated() {
        XCTAssertTrue(reading(a: 0, b: 1, shared: 10).correlated)
        XCTAssertFalse(reading(a: 2, b: 2, shared: 3).correlated, "3 of 5 overlap is not near-total")
        XCTAssertFalse(reading(a: 5, b: 3, shared: 15).correlated)
    }

    func testTextSimilarityFallbackIsLabelled() {
        let r = reading(a: 1, b: 1, shared: 3, clusters: false)
        XCTAssertEqual(r.matcher, .textSimilarity)
        XCTAssertEqual(r.both, 3, "identical texts cluster by similarity")
        XCTAssertEqual(reading(a: 1, b: 1, shared: 3).matcher, .integrator)
    }

    func testMatcherDisagreement() {
        // The integrator paired 12 issues whose texts share nothing: the text matcher finds 0.
        var proposers: [Int] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = [], clusters: [[Int]] = []
        for i in 0..<12 {
            proposers += [0, 1]
            changes += [ProposedChange(section: "## X\(i)", rationale: "alpha\(i)", edit: "one"),
                        ProposedChange(section: "## Y\(i)", rationale: "omega\(i)", edit: "two")]
            vs += [ChangeVerdict(index: 2 * i, verdict: .agree), ChangeVerdict(index: 2 * i + 1, verdict: .agree)]
            clusters.append([2 * i, 2 * i + 1])
        }
        let r = CoverageSeries.reading(checkpoint: 1, round: 1,
                                       record: CrossCheckRecord(proposers: proposers, families: [.codex, .claude], clusters: clusters, blindOrderSeed: 1),
                                       changes: changes, verdicts: vs)
        XCTAssertEqual(r.textSimilarityBoth, 0)
        XCTAssertTrue(r.matchersDisagree)
    }

    func testReadingsSkipRoundsWithoutARecord() throws {
        let cps = [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: Date()),
                   Checkpoint(id: 2, stage: .refine, round: 1, major: false, createdAt: Date()),
                   Checkpoint(id: 3, stage: .refine, round: 2, major: true, createdAt: Date())]
        let record = CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude], clusters: [[0, 1]], blindOrderSeed: 3)
        let files: [Int: [String: Data]] = [3: [
            CrossCheckRecord.fileName: try IntakeJSON.encoder.encode(record),
            "changes.json": try IntakeJSON.encoder.encode([ProposedChange(section: "s", rationale: "r", edit: "e"),
                                                           ProposedChange(section: "s", rationale: "r", edit: "e")]),
            "verdicts.json": try IntakeJSON.encoder.encode([ChangeVerdict(index: 0, verdict: .agree), ChangeVerdict(index: 1, verdict: .agree)]),
        ]]
        let readings = CoverageSeries.readings(cps) { files[$0]?[$1] }
        XCTAssertEqual(readings.map(\.checkpoint), [3], "old rounds with no crosscheck.json read as no reading, never as 0")
        XCTAssertEqual(readings.first?.round, 2)
    }

    /// Both families finding nothing is the best result a cross-check can give, and the likeliest
    /// one on the last round of a converged plan. The executor's empty-review path writes no
    /// `verdicts.json` (no integrator ran), and reading that as "unmeasured" hid it.
    func testEmptyCrossCheckWithoutVerdictsIsSaturated() throws {
        let cps = [Checkpoint(id: 4, stage: .refine, round: 3, major: true, createdAt: Date())]
        let record = CrossCheckRecord(proposers: [], families: [.codex, .claude], clusters: nil, blindOrderSeed: 2)
        let files: [Int: [String: Data]] = [4: [
            CrossCheckRecord.fileName: try IntakeJSON.encoder.encode(record),
            "changes.json": try IntakeJSON.encoder.encode([ProposedChange]()),
        ]]
        let r = try XCTUnwrap(CoverageSeries.readings(cps) { files[$0]?[$1] }.first)
        XCTAssertEqual(r.band, .saturated)
        XCTAssertEqual([r.n1, r.n2, r.both, r.found], [0, 0, 0, 0])
        XCTAssertEqual(r.unfound, 0)
    }

    /// `crosscheck.json` is disk-persisted, so a corrupted/hand-edited file or version skew can
    /// carry an out-of-range or repeated cluster index, or a families list with only one entry.
    /// None of that may crash the fold that reads it — it runs off-main in the live app.
    func testMalformedRecordDoesNotCrash() {
        let changes = [ProposedChange(section: "## s0", rationale: "r0", edit: "e0"),
                       ProposedChange(section: "## s1", rationale: "r1", edit: "e1")]
        let verdicts = [ChangeVerdict(index: 0, verdict: .agree), ChangeVerdict(index: 1, verdict: .agree)]

        let badIndex = CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude],
                                        clusters: [[0, 99], [1, 1]], blindOrderSeed: 1)
        let r1 = CoverageSeries.reading(checkpoint: 1, round: 1, record: badIndex, changes: changes, verdicts: verdicts)
        XCTAssertEqual(r1.matcher, .textSimilarity, "a cluster list that cleans to nothing reads as none given")

        let oneFamily = CrossCheckRecord(proposers: [0, 1], families: [.codex], clusters: [[0, 1]], blindOrderSeed: 1)
        let r2 = CoverageSeries.reading(checkpoint: 1, round: 1, record: oneFamily, changes: changes, verdicts: verdicts)
        XCTAssertEqual(r2.familyB, r2.familyA, "a families list missing the second entry reads as same-family")
        XCTAssertEqual(r2.band, .sameFamily)
    }

    // MARK: - Targets and verdict (coverage spec §7)

    func testTargetsPerPreset() {
        XCTAssertEqual(CoverageTarget(.bead), .none)
        XCTAssertEqual(CoverageTarget(.sketch), .none)
        XCTAssertEqual(CoverageTarget(.featurePlan), .fewLeftOrBetter)
        XCTAssertEqual(CoverageTarget(.fullPlan), .saturatedIndependent)
        XCTAssertNil(CoverageTarget.none.met(by: reading(a: 16, b: 14, shared: 4)))
        XCTAssertEqual(CoverageTarget.fewLeftOrBetter.met(by: reading(a: 6, b: 6, shared: 6)), true)
        XCTAssertEqual(CoverageTarget.saturatedIndependent.met(by: reading(a: 6, b: 6, shared: 6)), false)
        XCTAssertEqual(CoverageTarget.saturatedIndependent.met(by: reading(a: 0, b: 1, shared: 10)), false, "correlated")
    }

    func testStalledWhenConvergedButShort() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                       convergence: .converging(settled: true), refineRoundsRemaining: 0, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .stalled)
        XCTAssertEqual(v.targetMet, false)
        XCTAssertTrue(v.suggestedAction.hasPrefix("Stalled: converged, but coverage is short of the Feature plan target."))
        let plateau = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                             convergence: .plateau, refineRoundsRemaining: 0, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(plateau.state, .stalled)
    }

    /// A Feature plan (cap 3, first and last) whose R1 read MANY LEFT and whose convergence
    /// settled after R2 is not stalled: R3 is already planned to cross-check and re-measure it.
    /// "One more Refine round will cross-check again" would ask for a round the plan has.
    func testNotStalledWhileACrossCheckIsAhead() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                       convergence: .converging(settled: true), refineRoundsRemaining: 1,
                                       crossCheckAhead: true, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .reading(.manyLeft))
        XCTAssertEqual(v.targetMet, false)
        XCTAssertTrue(v.suggestedAction.hasPrefix("Coverage is short. Codex and Claude are finding different issues"),
                      v.suggestedAction)
        let none = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                          convergence: .converging(settled: true), refineRoundsRemaining: 1,
                                          crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(none.state, .stalled, "with no cross-check left to run, a settled shortfall is a stall")
    }

    func testNotStalledWhileStillConverging() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                       convergence: .converging(settled: false), refineRoundsRemaining: 2, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .reading(.manyLeft))
        XCTAssertTrue(v.suggestedAction.hasPrefix("Coverage is short. Codex and Claude are finding different issues"))
    }

    func testSaturatedEarlySuggestsTrimming() {
        let v = CoverageSeries.verdict(readings: [reading(a: 5, b: 3, shared: 15)], preset: .fullPlan,
                                       convergence: .tooEarly, refineRoundsRemaining: 4, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(v.suggestedAction,
                       "Saturated at Refine 1. Consider removing the remaining 4 Refine rounds (Run ▸ Remove a Round, ⌘-).")
    }

    /// A FEW LEFT reading meets the Feature plan target at Refine 1 too, and the same trim is
    /// suggested — but its headline must not call a FEW LEFT band "Saturated".
    func testTargetMetEarlyNamesTheBandItReached() {
        let r = reading(a: 6, b: 4, shared: 6)
        XCTAssertEqual(r.band, .fewLeft)
        let v = CoverageSeries.verdict(readings: [r], preset: .featurePlan,
                                       convergence: .tooEarly, refineRoundsRemaining: 2, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(v.suggestedAction,
                       "Coverage target met at Refine 1. Consider removing the remaining 2 Refine rounds (Run ▸ Remove a Round, ⌘-).")
    }

    func testSketchIsShownNeverJudged() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .sketch,
                                       convergence: .plateau, refineRoundsRemaining: 0, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .reading(.manyLeft))
        XCTAssertNil(v.targetMet)
    }

    func testAwaitingAndFailedCrossCheck() {
        let none = CoverageSeries.verdict(readings: [], preset: .featurePlan, convergence: nil, refineRoundsRemaining: 3, crossCheckAhead: false,
                                          failedCrossCheckRound: nil)
        XCTAssertEqual(none.state, .awaiting)
        XCTAssertEqual(none.suggestedAction, "")
        let failed = CoverageSeries.verdict(readings: [], preset: .featurePlan, convergence: nil, refineRoundsRemaining: 2, crossCheckAhead: false,
                                            failedCrossCheckRound: 1)
        XCTAssertEqual(failed.suggestedAction, "The cross-check agent failed at Refine 1, so coverage is unmeasured there.")
    }

    func testCorrelatedAndSameFamilyWording() {
        let corr = CoverageSeries.verdict(readings: [reading(a: 0, b: 1, shared: 10)], preset: .sketch, convergence: nil,
                                          refineRoundsRemaining: 0, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertTrue(corr.suggestedAction.hasPrefix("Codex and Claude found nearly the same issues."))
        let same = CoverageSeries.verdict(readings: [reading(a: 5, b: 3, shared: 15, families: [.claude, .claude])], preset: .fullPlan,
                                          convergence: nil, refineRoundsRemaining: 0, crossCheckAhead: false, failedCrossCheckRound: nil)
        XCTAssertEqual(same.suggestedAction, "Both reviews at Refine 1 ran as Claude, so coverage is unmeasured there.")
    }
}
