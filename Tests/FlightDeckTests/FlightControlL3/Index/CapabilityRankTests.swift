import XCTest
import IntakeKit

/// `rank` is what the router asks when no rule matches (L3-R §5 step 3), so its contract is the
/// contract's: best first, unknown models omitted (never scored zero), ties in catalog order.
/// The numbers are worked by hand in `testRankBlendsKindWeightsOverDimensionsWithData`.
final class CapabilityRankTests: XCTestCase {
    private let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet
    private let tests = TaskKind(id: "tests", name: "Tests", description: "d",
                                 dimensions: ["test-authoring": 0.9, "agentic-coding": 0.3], origin: .seed,
                                 createdAt: Date(timeIntervalSince1970: 0))

    private var scores: [ModelScores] {
        [ModelScores(model: sol, dimensions: ["test-authoring": DimensionScore(score: 0.8, confidence: 1),
                                              "agentic-coding": DimensionScore(score: 0.6, confidence: 1)]),
         ModelScores(model: opus, dimensions: ["test-authoring": DimensionScore(score: 0.6, confidence: 1),
                                               "agentic-coding": DimensionScore(score: 0.9, confidence: 1)]),
         ModelScores(model: sonnet, dimensions: ["agentic-coding": DimensionScore(score: 0.5, confidence: 1)])]
    }

    func testRankBlendsKindWeightsOverDimensionsWithData() {
        let ranked = CapabilityScoring.rank(kind: tests, candidates: [IndexFixtures.bare(sonnet), IndexFixtures.bare(opus),
                                                                      IndexFixtures.bare(sol)], scores: scores)
        XCTAssertEqual(ranked.map(\.model), [sol, opus, sonnet], "a bare catalog candidate resolves to its scored knob variant")
        XCTAssertEqual(ranked[0].score, 0.75, accuracy: 1e-12)          // (0.3×0.6 + 0.9×0.8) / 1.2
        XCTAssertEqual(ranked[0].confidence, 1, accuracy: 1e-12)
        XCTAssertEqual(ranked[1].score, 0.675, accuracy: 1e-12)         // (0.3×0.9 + 0.9×0.6) / 1.2
        XCTAssertEqual(ranked[2].score, 0.5, accuracy: 1e-12)           // only agentic-coding had data
        XCTAssertEqual(ranked[2].confidence, 0.25, accuracy: 1e-12, "0.3 of the kind's 1.2 weight had data")
    }

    func testUnknownModelIsOmittedNeverZero() {
        let ranked = CapabilityScoring.rank(kind: tests, candidates: [ModelRef(agent: .codex, model: "gpt-6-terra"),
                                                                      IndexFixtures.bare(sol)], scores: scores)
        XCTAssertEqual(ranked.map(\.model), [sol])
    }

    func testTiesGoToCatalogOrder() {
        let a = ModelRef(agent: .grok, model: "a"), b = ModelRef(agent: .grok, model: "b")
        let tied = [ModelScores(model: a, dimensions: ["agentic-coding": DimensionScore(score: 0.5, confidence: 1)]),
                    ModelScores(model: b, dimensions: ["agentic-coding": DimensionScore(score: 0.5, confidence: 1)])]
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [b, a], scores: tied).map(\.model), [b, a])
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [a, b], scores: tied).map(\.model), [a, b])
    }

    func testCandidateWithKnobsMatchesExactly() {
        let low = ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "low"])
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [low], scores: scores), [])
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [sol], scores: scores).map(\.model), [sol])
    }

    func testBareCandidatePicksTheBestKnobVariant() {
        let low = ModelRef(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "low"])
        let variants = [ModelScores(model: low, dimensions: ["test-authoring": DimensionScore(score: 0.4, confidence: 1)]),
                        ModelScores(model: sol, dimensions: ["test-authoring": DimensionScore(score: 0.8, confidence: 1)])]
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [IndexFixtures.bare(sol)], scores: variants).map(\.model), [sol])
    }

    func testKindWithNoUsableWeightsRanksNothing() {
        let empty = TaskKind(id: "x", name: "X", description: "d", dimensions: [:], origin: .user,
                             createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(CapabilityScoring.rank(kind: empty, candidates: [sol], scores: scores), [])
    }

    func testSnapshotIndexConformsAndReportsItsDate() {
        let date = Date(timeIntervalSince1970: 1_791_093_600)
        let index: any CapabilityIndex = SnapshotCapabilityIndex(scores: scores, snapshotDate: date)
        XCTAssertEqual(index.snapshotDate, date)
        XCTAssertEqual(index.rank(kind: tests, candidates: [IndexFixtures.bare(sol)]).first?.model, sol)
        XCTAssertNil(SnapshotCapabilityIndex.empty.snapshotDate)
    }

    func testCitationsAreTheRowsBehindACell() {
        let snap = IndexSnapshotCodingTests.sample(at: Date(timeIntervalSince1970: 1_790_000_000))
        let rows = CapabilityScoring.citations(for: sol, dimension: "tool-use-reliability", snapshot: snap,
                                               sources: IndexSourceRegistry.initial)
        XCTAssertEqual(rows.map(\.url), ["https://www.tbench.ai/leaderboard"])
        XCTAssertEqual(rows.first?.quotedFigure, "61.3%")
        XCTAssertEqual(rows.first?.sourceName, "Terminal-Bench")
        XCTAssertEqual(CapabilityScoring.citations(for: sol, dimension: "docs-prose", snapshot: snap,
                                                   sources: IndexSourceRegistry.initial), [])
    }
}
