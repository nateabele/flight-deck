import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4's failure rules against a fake headless runner: the cap stops the run and leaves the
/// rest of the sources on their previous values, marked stale; a failing source keeps its
/// previous values, marked stale with the error; rejected rows are logged with their reason.
final class IndexRefreshRunnerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_093_600)   // 2026-10-04T06:00:00Z
    private let earlier = Date(timeIntervalSince1970: 1_790_488_800) // 2026-09-27T06:00:00Z
    private var work: URL!

    override func setUp() {
        work = IndexFixtures.scratch()
        let w = work!
        addTeardownBlock { try? FileManager.default.removeItem(at: w) }
    }

    private func runner(_ h: ScriptedIndexHeadless) -> IndexRefreshRunner {
        let t = now
        return IndexRefreshRunner(headless: h, now: { t })
    }

    private func plan(_ sources: [IndexSource], cap: Int = 1_000_000, previous: IndexSnapshot? = nil) -> IndexRefreshPlan {
        var aliases = AliasTable()
        aliases.set(source: "a", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)
        return IndexRefreshPlan(sources: sources, aliases: aliases, catalogs: IndexFixtures.catalogs(),
                                agent: IndexAgentSettings(model: "sonnet", effort: "medium", tokenCap: cap),
                                previous: previous, workDirectory: work)
    }

    private func oldRow(_ name: String) -> AcceptedRow {
        AcceptedRow(benchmarkModel: name, score: 1, unit: .percent, url: "https://old.test", retrievedAt: nil, quotedFigure: "1")
    }

    private func previous(_ ids: [String]) -> IndexSnapshot {
        IndexSnapshot(createdAt: earlier,
                      sources: ids.map { SourceResult(sourceID: $0, rows: [oldRow("Old \($0)")], refreshedAt: earlier, tokens: 5) },
                      aliases: [], scores: [], unmapped: [])
    }

    func testValidSourceScoresAndProposesAliasesForCatalogNames() async {
        let h = ScriptedIndexHeadless()
        h.answers["a"] = (IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("GPT-6 Sol (high)", 61.3), ("Opus 5 (high)", 58.0),
                                                                               ("Mystery-1", 40.0)])), "", 0)
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a")]))
        XCTAssertEqual(outcome.snapshot.sources.map(\.stale), [false])
        XCTAssertEqual(outcome.snapshot.scores.map(\.model), [IndexFixtures.sol], "only a confirmed alias scores")
        XCTAssertEqual(outcome.snapshot.scores.first?.dimensions["agentic-coding"]?.score, 1)
        XCTAssertEqual(outcome.proposals.map(\.model), [IndexFixtures.opus], "Mystery-1 is never guessed")
        XCTAssertEqual(outcome.snapshot.unmapped.map(\.benchmarkModel), ["Mystery-1", "Opus 5 (high)"])
        XCTAssertEqual(outcome.tokensUsed, 1200)
        XCTAssertEqual(outcome.snapshot.createdAt, now)
        XCTAssertEqual(outcome.snapshot.sources.first?.refreshedAt, now)
    }

    func testCapReachedMarksTheRestStaleAndKeepsTheirPreviousRows() async {
        let h = ScriptedIndexHeadless()
        for id in ["a", "b", "c"] {
            h.answers[id] = (IndexFixtures.stream(IndexFixtures.payloadJSON(id, [("X", 1.0), ("Y", 2.0)])), "", 0)
        }
        let sources = ["a", "b", "c"].map { IndexFixtures.source($0) }
        let prior = previous(["b", "c"])
        let outcome = await runner(h).refresh(plan(sources, cap: 1500, previous: prior))
        // a spends 1200 of 1500; b is handed the remaining 300, spends 1200 and is stopped; c never runs.
        XCTAssertEqual(h.ran, ["a", "b"])
        XCTAssertEqual(outcome.snapshot.sources.map(\.stale), [false, true, true])
        XCTAssertEqual(outcome.snapshot.sources.map(\.error), [nil, "token cap reached", "token cap reached"])
        XCTAssertEqual(outcome.snapshot.sources[1].rows, prior.sources[0].rows)
        XCTAssertEqual(outcome.snapshot.sources[2].rows, prior.sources[1].rows)
        XCTAssertEqual(outcome.snapshot.sources[2].refreshedAt, earlier, "carried rows keep the time they were read")
        XCTAssertEqual(outcome.tokensUsed, 2400)
    }

    func testFailingSourceKeepsPreviousValuesMarkedStale() async {
        let h = ScriptedIndexHeadless()
        h.answers["a"] = (Data(), "auth failed", 1)
        let prior = previous(["a"])
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a")], previous: prior))
        XCTAssertEqual(outcome.snapshot.sources.first?.stale, true)
        XCTAssertEqual(outcome.snapshot.sources.first?.error, "claude exited 1: auth failed")
        XCTAssertEqual(outcome.snapshot.sources.first?.rows, prior.sources[0].rows)
        XCTAssertTrue(outcome.log.contains("a: failed: claude exited 1: auth failed"))
    }

    func testSourceWithOnlyRejectedRowsKeepsPreviousValues() async {
        let h = ScriptedIndexHeadless()
        let bad = #"{"source":"a","rows":[{"benchmarkModel":"X","score":50,"unit":"percent","url":"https://a.test","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"5%"}]}"#
        h.answers["a"] = (IndexFixtures.stream(bad), "", 0)
        let prior = previous(["a"])
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a")], previous: prior))
        XCTAssertEqual(outcome.snapshot.sources.first?.stale, true)
        XCTAssertEqual(outcome.snapshot.sources.first?.error, "no valid rows (1 rejected)")
        XCTAssertEqual(outcome.snapshot.sources.first?.rows, prior.sources[0].rows)
        XCTAssertTrue(outcome.log.contains(#"a: rejected "X": quoted figure "5%" does not match score 50.0"#))
    }

    func testDisabledSourceIsNeverRun() async {
        let h = ScriptedIndexHeadless()
        h.answers["a"] = (IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("X", 1.0), ("Y", 2.0)])), "", 0)
        h.answers["b"] = h.answers["a"]
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a"), IndexFixtures.source("b", enabled: false)]))
        XCTAssertEqual(h.ran, ["a"])
        XCTAssertEqual(outcome.snapshot.sources.map(\.sourceID), ["a"])
    }

    func testEachSourceRunsTheWebOnlyExtractionCommand() async {
        let h = ScriptedIndexHeadless()
        _ = await runner(h).refresh(plan([IndexFixtures.source("a")]))
        let args = h.commands.first ?? []
        XCTAssertTrue(args.contains("WebSearch WebFetch"))
        XCTAssertTrue(args.contains("--restricted"))
        XCTAssertTrue(h.prompts.first?.contains("(id a)") == true)
    }

    func testRescoreUsesNewAliasesWithoutRunningAnything() {
        let snap = IndexSnapshot(createdAt: earlier, sources: [SourceResult(sourceID: "a", rows: [
            AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "61.3%"),
            AcceptedRow(benchmarkModel: "Opus 5 (high)", score: 58.0, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "58.0%")],
            refreshedAt: earlier)], aliases: [], scores: [], unmapped: [])
        var aliases = AliasTable()
        aliases.set(source: "a", benchmarkModel: "Opus 5 (high)", model: IndexFixtures.opus, status: .confirmed)
        let rescored = IndexRefreshRunner.rescore(snap, sources: [IndexFixtures.source("a")], aliases: aliases, now: now)
        XCTAssertEqual(rescored.scores.map(\.model), [IndexFixtures.opus])
        XCTAssertEqual(rescored.sources, snap.sources, "a rescore re-reads nothing")
        XCTAssertEqual(rescored.createdAt, now)
    }

    func testCapStopsARunMidStream() async {
        // The meter crosses the cap while the process is still running; only cancelling it ends
        // this fake, so a runner that waited for exit would hang rather than pass.
        let h = StreamingIndexHeadless(tokens: 2000)
        let sources = ["a", "b"].map { IndexFixtures.source($0) }
        let outcome = await IndexRefreshRunner(headless: h, now: { [now] in now }).refresh(plan(sources, cap: 1500))
        XCTAssertEqual(h.ran.count, 1, "the later source is skipped, not run")
        XCTAssertEqual(outcome.snapshot.sources.map(\.stale), [true, true])
        XCTAssertEqual(outcome.snapshot.sources.map(\.error), ["token cap reached", "token cap reached"])
        XCTAssertEqual(outcome.tokensUsed, 2000)
    }
}

