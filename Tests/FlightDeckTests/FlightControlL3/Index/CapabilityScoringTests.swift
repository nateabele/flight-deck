import XCTest
import IntakeKit

/// Spec §6, rule by rule: a benchmark ranks models by percentile; a dimension is the weighted
/// mean over the benchmarks present, with confidence the present weight's share; no data is
/// unknown, never zero; hand scores win with confidence 1; an inherited score is discounted.
/// Every table here is small enough to check by hand — the expected values are worked in the
/// comments.
final class CapabilityScoringTests: XCTestCase {
    private let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet

    private func row(_ name: String, _ score: Double, unit: IndexUnit = .percent) -> AcceptedRow {
        AcceptedRow(benchmarkModel: name, score: score, unit: unit, url: "https://x.test", retrievedAt: nil, quotedFigure: "\(score)")
    }
    private func result(_ id: String, _ rows: [AcceptedRow], stale: Bool = false) -> SourceResult {
        SourceResult(sourceID: id, rows: rows, stale: stale, refreshedAt: nil)
    }
    private func aliases(_ pairs: [(String, String, ModelRef)]) -> AliasTable {
        var t = AliasTable()
        for (s, n, m) in pairs { t.set(source: s, benchmarkModel: n, model: m, status: .confirmed) }
        return t
    }
    private func dim(_ scores: [ModelScores], _ ref: ModelRef, _ d: String) -> DimensionScore? {
        scores.first { $0.model == ref }?.dimensions[d]
    }

    func testPercentileRanksWorstToZeroAndBestToOne() {
        XCTAssertEqual(CapabilityScoring.percentiles([10, 20, 30], higherIsBetter: true), [0, 0.5, 1])
    }

    func testTiesShareTheirMiddle() {
        XCTAssertEqual(CapabilityScoring.percentiles([10, 10, 30], higherIsBetter: true), [0.25, 0.25, 1])
    }

    func testLowerIsBetterUnitInvertsPercentile() {
        XCTAssertEqual(CapabilityScoring.percentiles([1.0, 3.0], higherIsBetter: false), [1, 0])
        let price = IndexFixtures.source("price", ["cost-efficiency": 1], unit: .usdPerMillionTokens)
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("price", [row("Cheap", 1.0, unit: .usdPerMillionTokens), row("Dear", 15.0, unit: .usdPerMillionTokens)])],
            sources: [price], aliases: aliases([("price", "Cheap", sonnet), ("price", "Dear", opus)]))
        XCTAssertEqual(dim(scores, sonnet, "cost-efficiency")?.score, 1, "the cheaper model must score higher on cost-efficiency")
        XCTAssertEqual(dim(scores, opus, "cost-efficiency")?.score, 0)
    }

    func testSingleRowBenchmarkContributesNothing() {
        XCTAssertNil(CapabilityScoring.percentiles([42], higherIsBetter: true))
        let (scores, unmapped) = CapabilityScoring.computeScores(
            results: [result("a", [row("GPT-6 Sol (high)", 42)])],
            sources: [IndexFixtures.source("a")], aliases: aliases([("a", "GPT-6 Sol (high)", sol)]))
        XCTAssertEqual(scores, [], "one row ranks against nothing; it must read neither as best nor as middling")
        XCTAssertEqual(unmapped, [])
    }

    func testDimensionIsWeightedMeanAndConfidenceIsPresentWeightShare() {
        let a = IndexFixtures.source("a", ["agentic-coding": 1.0])
        let b = IndexFixtures.source("b", ["agentic-coding": 0.5])
        let c = IndexFixtures.source("c", ["agentic-coding": 0.5])
        let (scores, unmapped) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)]),
                      result("b", [row("Sol", 5), row("Opus", 10)]),
                      result("c", [row("Opus", 1), row("X", 2)])],
            sources: [a, b, c],
            aliases: aliases([("a", "Sol", sol), ("a", "Opus", opus), ("b", "Sol", sol), ("b", "Opus", opus), ("c", "Opus", opus)]))
        // sol: a → 1 (weight 1.0), b → 0 (weight 0.5): (1×1 + 0.5×0) / 1.5; present 1.5 of 2.0.
        XCTAssertEqual(dim(scores, sol, "agentic-coding")!.score, 1.0 / 1.5, accuracy: 1e-12)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")!.confidence, 0.75, accuracy: 1e-12)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")!.sources, ["a", "b"])
        // opus: a → 0, b → 1, c → 0 (X beats it): 0.5 / 2.0; every source present.
        XCTAssertEqual(dim(scores, opus, "agentic-coding")!.score, 0.25, accuracy: 1e-12)
        XCTAssertEqual(dim(scores, opus, "agentic-coding")!.confidence, 1, accuracy: 1e-12)
        XCTAssertEqual(unmapped, [UnmappedName(source: "c", benchmarkModel: "X")])
    }

    func testUnknownIsAbsentNeverZero() {
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)])],
            sources: [IndexFixtures.source("a", ["agentic-coding": 1])], aliases: aliases([("a", "Sol", sol)]))
        XCTAssertNotNil(dim(scores, sol, "agentic-coding"))
        XCTAssertNil(dim(scores, sol, "debugging"), "no data is unknown, not zero")
    }

    func testUnmappedRowsAreIgnoredButStillCompete() {
        let (scores, unmapped) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 10), row("Better Unknown", 20)])],
            sources: [IndexFixtures.source("a")], aliases: aliases([("a", "Sol", sol)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 0, "an unmapped model that beats sol still beats it")
        XCTAssertEqual(scores.map(\.model), [sol], "the unmapped model itself is never scored")
        XCTAssertEqual(unmapped, [UnmappedName(source: "a", benchmarkModel: "Better Unknown")])
    }

    func testTwoNamesForOneModelKeepTheBestRow() {
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol A", 10), row("Sol B", 30), row("Opus", 20)])],
            sources: [IndexFixtures.source("a")],
            aliases: aliases([("a", "Sol A", sol), ("a", "Sol B", sol), ("a", "Opus", opus)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 1)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.sources, ["a"], "one source counts once, however many names map to the model")
    }

    func testDisabledSourceIsLeftOutOfScoreAndConfidence() {
        let a = IndexFixtures.source("a", ["agentic-coding": 1])
        let off = IndexFixtures.source("off", ["agentic-coding": 1], enabled: false)
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)]), result("off", [row("Sol", 1), row("Opus", 10)])],
            sources: [a, off], aliases: aliases([("a", "Sol", sol), ("off", "Sol", sol)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 1)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.confidence, 1)
    }

    func testStaleRowsStillScore() {
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)], stale: true)],
            sources: [IndexFixtures.source("a")], aliases: aliases([("a", "Sol", sol)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 1)
    }

    func testManualScoresWinWithConfidenceOne() {
        let computed = [ModelScores(model: sol, dimensions: ["debugging": DimensionScore(score: 0.2, confidence: 0.5)])]
        let local = ModelRef(agent: .gemini, model: "ollama/qwen")
        let out = CapabilityScoring.overlay(computed, manual: [
            ManualModelScores(model: local, dimensions: ["debugging": 0.7, "vibes": 1]),
            ManualModelScores(model: sol, dimensions: ["debugging": 0.9])])
        XCTAssertEqual(dim(out, local, "debugging"), DimensionScore(score: 0.7, confidence: 1, origin: .manual))
        XCTAssertNil(dim(out, local, "vibes"), "a hand score on an unknown dimension is dropped")
        XCTAssertEqual(dim(out, sol, "debugging")?.origin, .manual, "a hand score beats a computed one")
    }

    func testInheritedScoresAreDiscountedAndLabelled() {
        let computed = [ModelScores(model: sol, dimensions: [
            "agentic-coding": DimensionScore(score: 0.8, confidence: 0.75, sources: ["a"]),
            "debugging": DimensionScore(score: 0.4, confidence: 1, sources: ["b"])])]
        let local = ModelRef(agent: .gemini, model: "ollama/qwen")
        let out = CapabilityScoring.overlay(computed, manual: [
            ManualModelScores(model: local, dimensions: ["debugging": 0.9], inheritFrom: sol)])
        let inherited = dim(out, local, "agentic-coding")!
        XCTAssertEqual(inherited.score, 0.68, accuracy: 1e-12)   // 0.8 × 0.85
        XCTAssertEqual(inherited.confidence, 0.75)
        XCTAssertEqual(inherited.origin, .inherited)
        XCTAssertEqual(inherited.inheritedFrom, sol)
        XCTAssertEqual(dim(out, local, "debugging")?.origin, .manual, "a hand score beats an inherited one")
    }

    func testComputedBeatsInherited() {
        let local = ModelRef(agent: .gemini, model: "ollama/qwen")
        let computed = [ModelScores(model: sol, dimensions: ["agentic-coding": DimensionScore(score: 0.8, confidence: 1)]),
                        ModelScores(model: local, dimensions: ["agentic-coding": DimensionScore(score: 0.3, confidence: 0.2)])]
        let out = CapabilityScoring.overlay(computed, manual: [ManualModelScores(model: local, dimensions: [:], inheritFrom: sol)])
        XCTAssertEqual(dim(out, local, "agentic-coding")?.score, 0.3)
        XCTAssertEqual(dim(out, local, "agentic-coding")?.origin, .computed)
    }

    func testAssembleKeepsOnlyConfirmedAliasesAndScoresTheRows() {
        var table = aliases([("a", "Sol", sol)])
        table.addProposals([AliasEntry(source: "a", benchmarkModel: "Opus", model: opus, status: .pending)])
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let snap = IndexSnapshot.assemble(results: [result("a", [row("Sol", 30), row("Opus", 10)])],
                                          sources: [IndexFixtures.source("a")], aliases: table, createdAt: at)
        XCTAssertEqual(snap.aliases.map(\.benchmarkModel), ["Sol"])
        XCTAssertEqual(snap.scores.map(\.model), [sol])
        XCTAssertEqual(snap.unmapped, [UnmappedName(source: "a", benchmarkModel: "Opus")])
        XCTAssertEqual(snap.createdAt, at)
    }
}
