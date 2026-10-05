import XCTest
import IntakeKit

/// Spec §6: "If some model scores at least 0.10 higher with confidence at least 0.6, the rule
/// gets a hint." A table over the cases that decide whether a hint shows, plus the float edge
/// that would hide a hint the user can see is due.
final class CapabilityHintsTests: XCTestCase {
    private func scores(_ rows: [(ModelRef, String, Double, Double)]) -> [ModelScores] {
        var by: [ModelRef: [String: DimensionScore]] = [:]
        for (m, d, s, c) in rows { by[m, default: [:]][d] = DimensionScore(score: s, confidence: c, sources: ["src-\(d)"]) }
        return by.map { ModelScores(model: $0.key, dimensions: $0.value) }.sorted { IndexKeys.key($0.model) < IndexKeys.key($1.model) }
    }

    private struct Case {
        let name: String
        let rows: [(ModelRef, String, Double, Double)]
        let dims: [String: Double]
        let expect: [String]
    }

    func testTable() {
        let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet
        let cases: [Case] = [
            Case(name: "clearly better and confident hints",
                 rows: [(sol, "test-authoring", 0.6, 1), (opus, "test-authoring", 0.74, 0.8)],
                 dims: ["test-authoring": 0.5],
                 expect: ["opus scores 0.14 higher on test-authoring (confidence 0.8)"]),
            Case(name: "below the margin is quiet",
                 rows: [(sol, "test-authoring", 0.6, 1), (opus, "test-authoring", 0.69, 1)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "low confidence is quiet",
                 rows: [(sol, "test-authoring", 0.5, 1), (opus, "test-authoring", 0.9, 0.5)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "dimensions outside the rule are ignored",
                 rows: [(sol, "debugging", 0.1, 1), (opus, "debugging", 0.9, 1),
                        (sol, "test-authoring", 0.8, 1), (opus, "test-authoring", 0.8, 1)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "an assigned model with no score cannot be judged",
                 rows: [(opus, "test-authoring", 0.9, 1)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "largest margin first",
                 rows: [(sol, "test-authoring", 0.3, 1), (sol, "algorithmic-reasoning", 0.5, 1),
                        (opus, "test-authoring", 0.5, 1), (opus, "algorithmic-reasoning", 0.9, 1),
                        (sonnet, "test-authoring", 0.9, 0.7)],
                 dims: ["test-authoring": 0.5, "algorithmic-reasoning": 0.6],
                 expect: ["sonnet scores 0.60 higher on test-authoring (confidence 0.7)",
                          "opus scores 0.40 higher on algorithmic-reasoning (confidence 1.0)",
                          "opus scores 0.20 higher on test-authoring (confidence 1.0)"]),
        ]
        for c in cases {
            let got = CapabilityHints.hints(for: c.dims, assigned: sol,
                                      candidates: [IndexFixtures.bare(sol), IndexFixtures.bare(opus), sonnet, IndexFixtures.bare(opus)],
                                      scores: scores(c.rows)).map(\.message)
            XCTAssertEqual(got, c.expect, c.name)
        }
    }

    func testExactlyTenPointMarginHintsDespiteFloatError() {
        XCTAssertLessThan(0.7 - 0.6, 0.1, "the premise: in floating point this margin is just under 0.10")
        let rows = scores([(IndexFixtures.sol, "debugging", 0.6, 1), (IndexFixtures.opus, "debugging", 0.7, 0.6)])
        XCTAssertEqual(CapabilityHints.hints(for: ["debugging": 0.5], assigned: IndexFixtures.sol,
                                       candidates: [IndexFixtures.opus], scores: rows).count, 1)
    }

    func testIndexExposesHintsOverItsScores() {
        let index = SnapshotCapabilityIndex(scores: scores([(IndexFixtures.sol, "debugging", 0.2, 1),
                                                            (IndexFixtures.opus, "debugging", 0.9, 1)]), snapshotDate: nil)
        let hint = index.hints(for: ["debugging": 0.5], assigned: IndexFixtures.sol, candidates: [IndexFixtures.opus]).first
        XCTAssertEqual(hint?.better, IndexFixtures.opus)
        XCTAssertEqual(hint?.sources, ["src-debugging"])
        XCTAssertEqual(hint?.margin ?? 0, 0.7, accuracy: 1e-12)
    }
}
