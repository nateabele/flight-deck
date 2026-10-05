import XCTest
import IntakeKit
@testable import FlightDeck

/// One real refresh of one real source. Everything else in this branch runs against recorded
/// answers; this is the check that `--restricted` still lets WebFetch through when `--tools`
/// names it, that the schema-bound answer parses, and that a real page's rows pass the
/// citation rules. Spends real tokens — skipped unless `INDEX_LIVE=1` (or
/// `TEST_RUNNER_INDEX_LIVE=1`). Never loop it.
final class IndexLiveProbeTests: XCTestCase {
    func testOneRealSourceYieldsCitedRows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["INDEX_LIVE"] == "1" || env["TEST_RUNNER_INDEX_LIVE"] == "1" else {
            throw XCTSkip("set INDEX_LIVE=1 to run; it spends real tokens")
        }
        // A data file, so the probe tests the pipeline rather than one site's page layout.
        let source = try XCTUnwrap(IndexSourceRegistry.initial.first { $0.id == "aider-polyglot" })
        let work = IndexFixtures.scratch()
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let plan = IndexRefreshPlan(sources: [source], aliases: AliasTable(), catalogs: IndexFixtures.catalogs(),
                                    agent: IndexAgentSettings(model: "sonnet", effort: "low", tokenCap: 400_000),
                                    previous: nil, workDirectory: work)
        let outcome = await IndexRefreshRunner().refresh(plan)
        print(outcome.log.joined(separator: "\n"))
        let result = try XCTUnwrap(outcome.snapshot.sources.first)
        XCTAssertFalse(result.stale, "the live run failed: \(result.error ?? "?")")
        XCTAssertGreaterThan(result.rows.count, 5)
        for row in result.rows {
            XCTAssertTrue(row.url.hasPrefix("http"), row.benchmarkModel)
            XCTAssertTrue(ExtractionValidator.figureMatches(row.quotedFigure, score: row.score), row.benchmarkModel)
        }
        XCTAssertGreaterThan(outcome.tokensUsed, 0)
    }
}
