import XCTest
import IntakeKit
@testable import FlightDeck

/// The LCD's COVERAGE cell and its card text (coverage spec §8): every string is the engine's
/// `CoverageVerdict` read out, so these pin what each band, a stall and a failed cross-check say.
final class CoverageCellModelTests: XCTestCase {
    private func verdict(_ readings: [CoverageReading], _ preset: Preset = .featurePlan,
                         convergence: ConvergenceVerdict? = nil, remaining: Int = 0,
                         failed: Int? = nil) -> CoverageVerdict {
        CoverageSeries.verdict(readings: readings, preset: preset, convergence: convergence,
                               refineRoundsRemaining: remaining, failedCrossCheckRound: failed)
    }
    private func reading(n1: Int, n2: Int, both: Int, round: Int = 1, families: [ModelFamily] = [.codex, .claude]) -> CoverageReading {
        // Build through CoverageSeries.reading so the numbers are the fold's, not hand-set.
        var proposers: [Int] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = [], clusters: [[Int]] = []
        func add(_ p: Int, _ t: String) -> Int {
            proposers.append(p); changes.append(ProposedChange(section: "## \(t)", rationale: t, edit: t))
            vs.append(ChangeVerdict(index: changes.count - 1, verdict: .agree)); return changes.count - 1
        }
        for i in 0..<(n1 - both) { _ = add(0, "a\(i)") }
        for i in 0..<(n2 - both) { _ = add(1, "b\(i)") }
        for i in 0..<both { clusters.append([add(0, "s\(i)"), add(1, "s\(i)")]) }
        return CoverageSeries.reading(checkpoint: round + 2, round: round,
                                      record: CrossCheckRecord(proposers: proposers, families: families,
                                                               clusters: clusters.isEmpty ? nil : clusters, blindOrderSeed: 1),
                                      changes: changes, verdicts: vs)
    }

    func testAbsentWithoutCrossChecksOrReadings() {
        XCTAssertNil(CoverageCellModel(verdict: verdict([]), crossChecks: false))
        XCTAssertEqual(CoverageCellModel(verdict: verdict([]), crossChecks: true)?.word, "—")
        XCTAssertEqual(CoverageCellModel(verdict: verdict([]), crossChecks: true)?.caption, "cross-check pending")
    }

    func testSaturatedCell() throws {
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 15)]), crossChecks: true))
        XCTAssertEqual([m.word, m.shortWord, m.caption], ["SATURATED", "SAT", "cross-check R1"])
        XCTAssertEqual(m.tone, .normal)
        XCTAssertEqual(m.rows, ["Refine 1 · Codex 20 · Claude 18 · both 15 · ≈ 1 unfound (estimate)"])
        XCTAssertEqual(m.targetLine, "Feature plan target: FEW LEFT or better · met at Refine 1")
    }

    func testStalledIsAmberWithTheEnginesAction() throws {
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 4)], convergence: .plateau),
                                                crossChecks: true))
        XCTAssertEqual([m.word, m.shortWord], ["STALLED", "STALL"])
        XCTAssertEqual(m.tone, .amber)
        XCTAssertEqual(m.actionHeadline, "Stalled: converged, but coverage is short of the Feature plan target")
        XCTAssertEqual(m.targetLine, "Feature plan target: FEW LEFT or better · not met")
    }

    func testNoOverlapIsAmberAndSameFamilyIsUnmeasured() throws {
        XCTAssertEqual(CoverageCellModel(verdict: verdict([reading(n1: 3, n2: 3, both: 0)]), crossChecks: true)?.tone, .amber)
        let same = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 15, families: [.claude, .claude])]),
                                                   crossChecks: true))
        XCTAssertEqual([same.word, same.caption], ["—", "unmeasured"])
        XCTAssertTrue(same.rows[0].hasSuffix("same family, not independent"))
    }

    /// A cross-reviewer that failed after the latest reading leaves that round unmeasured: the
    /// caption must not keep naming the older round as though it were current (spec §8 gap).
    func testFailedCrossCheckNewerThanTheReadingIsUnmeasured() throws {
        let stale = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 15)], failed: 3),
                                                    crossChecks: true))
        // No stale band beside "unmeasured": the older reading's SATURATED would read as current.
        XCTAssertEqual([stale.word, stale.shortWord, stale.caption], ["—", "—", "unmeasured"])
        XCTAssertEqual(stale.tone, .normal)
        XCTAssertEqual(stale.actionHeadline, "The cross-check agent failed at Refine 3, so coverage is unmeasured there")
        let none = try XCTUnwrap(CoverageCellModel(verdict: verdict([], failed: 1), crossChecks: true))
        XCTAssertEqual([none.word, none.caption], ["—", "unmeasured"])
        // A failure at or before the reading's own round is already superseded by the reading.
        let current = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 15, round: 3)], failed: 3),
                                                      crossChecks: true))
        XCTAssertEqual(current.caption, "cross-check R3")
    }

    /// The integrator's declines and the matchers' disagreement are the card's notes, in words.
    func testNotesNameDeclinesAndMatcher() throws {
        var r = reading(n1: 6, n2: 5, both: 2)
        r.rejectedA = 2
        r.rejectedB = 1
        r.matcher = .textSimilarity
        r.matchersDisagree = true
        r.textSimilarityBoth = 7
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([r]), crossChecks: true))
        XCTAssertEqual(m.notes, ["Integrator declined: Codex 2 · Claude 1",
                                 "Matched by text similarity: the integrator gave no groups",
                                 "Text matching finds 7 in common; the integrator found 2"])
    }

    /// Near-total overlap is flagged, not trusted: correlated reviewers make the estimate read low.
    func testCorrelatedReadingGetsANote() throws {
        let r = reading(n1: 20, n2: 18, both: 17)
        XCTAssertTrue(r.correlated)
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([r]), crossChecks: true))
        XCTAssertTrue(m.notes.contains("Codex and Claude overlap on nearly every issue; the estimate may be low"), "\(m.notes)")
    }

    /// A round with no per-change verdicts has no counts: its row must never read as zeros.
    func testUnmeasuredRowSaysSoInsteadOfZeros() throws {
        let r = CoverageSeries.reading(checkpoint: 5, round: 2,
                                       record: CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude],
                                                                clusters: nil, blindOrderSeed: 1),
                                       changes: nil, verdicts: nil)
        XCTAssertEqual(r.band, .unmeasured)
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([r]), crossChecks: true))
        XCTAssertEqual(m.rows, ["Refine 2 · unmeasured (no per-change verdicts)"])
    }

    /// Both cells split the engine's action at the same first ". " — one splitter, not two.
    func testActionSplitIsShared() {
        let parts = ConvergenceCellModel.splitAction("Saturated at Refine 1. Consider removing the rest.")
        XCTAssertEqual(parts?.headline, "Saturated at Refine 1")
        XCTAssertEqual(parts?.detail, "Consider removing the rest.")
        XCTAssertNil(ConvergenceCellModel.splitAction(""))
    }
}
