import XCTest
import IntakeKit
@testable import FlightDeck

/// The service is where the index meets time and the user: a new snapshot applies the moment
/// it is written, rollback is one call, the weekly check never fires before a first manual
/// refresh, and — the expensive failure — a refresh that fails must not be retried on every
/// beat of the 500 ms clock.
@MainActor
final class CapabilityIndexServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_093_600)
    private var dir: URL!

    override func setUp() {
        dir = IndexFixtures.scratch()
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    }

    private func make(_ h: ScriptedIndexHeadless) -> CapabilityIndexService {
        let t = now
        return CapabilityIndexService(directory: dir, runner: IndexRefreshRunner(headless: h, now: { t }),
                                      catalogs: { IndexFixtures.catalogs() }, now: { t })
    }

    private func seedConfig(_ change: (inout IndexConfig) -> Void = { _ in }) throws {
        var c = IndexConfig.initial()
        c.sources = [IndexFixtures.source("a")]
        c.aliases.set(source: "a", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)
        change(&c)
        try c.save(to: dir.appendingPathComponent("config.json"))
    }

    private let kind = TaskKind(id: "k", name: "K", description: "d", dimensions: ["agentic-coding": 1], origin: .user,
                                createdAt: Date(timeIntervalSince1970: 0))

    private func answerA(_ h: ScriptedIndexHeadless) {
        h.answers["a"] = (IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("GPT-6 Sol (high)", 61.3), ("Opus 5 (high)", 58.0)])), "", 0)
    }

    func testRefreshWritesAndAppliesTheSnapshot() async throws {
        try seedConfig()
        let h = ScriptedIndexHeadless()
        answerA(h)
        let service = make(h)
        await service.refreshNow()
        XCTAssertEqual(service.current?.createdAt, now)
        XCTAssertEqual(service.live.snapshotDate, now)
        XCTAssertEqual(service.live.rank(kind: kind, candidates: [IndexFixtures.bare(IndexFixtures.sol)]).first?.model, IndexFixtures.sol)
        XCTAssertEqual(service.config.aliases.pending.map(\.model), [IndexFixtures.opus], "proposals land as pending aliases")
        XCTAssertFalse(service.isRefreshing)
        XCTAssertEqual(IndexSnapshotStore(directory: dir).list().count, 1)
    }

    func testFirstRefreshIsNeverAutomatic() throws {
        try seedConfig()
        let h = ScriptedIndexHeadless()
        let service = make(h)
        XCTAssertFalse(service.isDue)
        service.tick()
        XCTAssertNil(service.refreshTask, "a fresh install must not spend tokens until someone clicks Refresh now")
    }

    func testFailedRefreshDoesNotRetryOnNextTick() async throws {
        try seedConfig { $0.lastRefreshAttemptAt = self.now.addingTimeInterval(-8 * 86_400) }
        let h = ScriptedIndexHeadless()   // no answers: every source fails
        let service = make(h)
        XCTAssertTrue(service.isDue)
        service.tick()
        await service.refreshTask?.value
        XCTAssertEqual(h.prompts.count, 1)
        service.tick()
        service.tick()
        await service.refreshTask?.value
        XCTAssertEqual(h.prompts.count, 1, "a failed run waits a week; it must not retry on every 500 ms beat")
        XCTAssertEqual(service.config.lastRefreshAttemptAt, now)
        XCTAssertFalse(service.isDue)
    }

    func testDueAWeekAfterTheLastSnapshot() throws {
        try seedConfig()
        try IndexSnapshotStore(directory: dir).write(IndexSnapshot(createdAt: now.addingTimeInterval(-7 * 86_400), sources: [],
                                                                   aliases: [], scores: [], unmapped: []))
        XCTAssertTrue(make(ScriptedIndexHeadless()).isDue)
    }

    func testRollBackMakesThePreviousCurrentAndRepublishes() throws {
        try seedConfig()
        let store = IndexSnapshotStore(directory: dir)
        let older = now.addingTimeInterval(-86_400)
        try store.write(IndexSnapshot(createdAt: older, sources: [], aliases: [], scores: [], unmapped: []))
        try store.write(IndexSnapshot(createdAt: now, sources: [], aliases: [], scores: [], unmapped: []))
        let service = make(ScriptedIndexHeadless())
        XCTAssertTrue(service.canRollBack)
        service.rollBack()
        XCTAssertEqual(service.current?.createdAt, older)
        XCTAssertEqual(service.live.snapshotDate, older)
        XCTAssertFalse(service.canRollBack)
        service.rollBack()
        XCTAssertEqual(service.problem, "There is no earlier snapshot to roll back to.")
        XCTAssertEqual(service.current?.createdAt, older)
    }

    func testConfirmingAnAliasRescoresWithoutAnAgentRun() throws {
        try seedConfig { $0.aliases.addProposals([AliasEntry(source: "a", benchmarkModel: "Opus 5 (high)", model: IndexFixtures.opus, status: .pending)]) }
        let rows = [AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "61.3%"),
                    AcceptedRow(benchmarkModel: "Opus 5 (high)", score: 58.0, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "58.0%")]
        try IndexSnapshotStore(directory: dir).write(IndexSnapshot(createdAt: now.addingTimeInterval(-60),
                                                                   sources: [SourceResult(sourceID: "a", rows: rows, refreshedAt: nil)],
                                                                   aliases: [], scores: [], unmapped: []))
        let h = ScriptedIndexHeadless()
        let service = make(h)
        service.confirmAlias(source: "a", benchmarkModel: "Opus 5 (high)")
        XCTAssertEqual(service.scores.first { $0.model == IndexFixtures.opus }?.dimensions["agentic-coding"]?.score, 0)
        XCTAssertEqual(h.prompts, [], "a rescore never runs the agent")
        XCTAssertEqual(IndexSnapshotStore(directory: dir).list().count, 2, "the rescore is its own snapshot, so it can be rolled back")
        service.rejectAlias(source: "a", benchmarkModel: "GPT-6 Sol (high)")
        XCTAssertNil(service.scores.first { $0.model == IndexFixtures.sol }, "rejecting a confirmed mapping unscores it")
    }

    func testManualScoresReachTheLiveIndex() throws {
        try seedConfig()
        let service = make(ScriptedIndexHeadless())
        let local = ModelRef(harness: "opencode", model: "ollama/qwen")
        service.setManual(ManualModelScores(model: local, dimensions: ["agentic-coding": 0.9]))
        XCTAssertEqual(service.live.rank(kind: kind, candidates: [local]).first?.score, 0.9)
        XCTAssertEqual(service.scores.first { $0.model == local }?.dimensions["agentic-coding"]?.origin, .manual)
        let renamed = ModelRef(harness: "opencode", model: "ollama/qwen3")
        service.setManual(ManualModelScores(model: renamed, dimensions: ["agentic-coding": 0.8]), replacing: local)
        XCTAssertEqual(service.config.manual.map(\.model), [renamed])
        XCTAssertEqual(IndexConfig.load(from: dir.appendingPathComponent("config.json")).config.manual.map(\.model), [renamed], "hand scores persist")
    }

    func testUnreadableConfigIsReportedNotOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent("config.json"))
        let service = make(ScriptedIndexHeadless())
        XCTAssertNotNil(service.problem)
        XCTAssertEqual(service.config, IndexConfig.initial())
    }

    func testSchedulingRegistersOnTheSharedClock() throws {
        try seedConfig()
        let clock = WatchClock(appIsActive: { true })
        let service = make(ScriptedIndexHeadless())
        service.startScheduling(clock: clock)
        XCTAssertTrue(clock.isRegistered(service))
        service.stopScheduling()
        XCTAssertFalse(clock.isRegistered(service))
    }

    func testHintsComeFromTheLiveIndex() throws {
        try seedConfig()
        let service = make(ScriptedIndexHeadless())
        service.setManual(ManualModelScores(model: IndexFixtures.sol, dimensions: ["debugging": 0.2]))
        service.setManual(ManualModelScores(model: IndexFixtures.opus, dimensions: ["debugging": 0.9]))
        XCTAssertEqual(service.hints(for: ["debugging": 0.5], assigned: IndexFixtures.sol, candidates: [IndexFixtures.opus]).first?.better,
                       IndexFixtures.opus)
    }

    /// A settings edit that moves no score (here: disabling a source nothing was scored from)
    /// must not write a snapshot, or about twelve such edits would evict every real refresh
    /// from the twelve kept.
    func testNoOpEditWritesNoSnapshot() throws {
        try seedConfig()
        let rows = [AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "61.3%"),
                    AcceptedRow(benchmarkModel: "Opus 5 (high)", score: 58.0, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "58.0%")]
        try IndexSnapshotStore(directory: dir).write(IndexSnapshot(createdAt: now.addingTimeInterval(-60),
                                                                   sources: [SourceResult(sourceID: "a", rows: rows, refreshedAt: nil)],
                                                                   aliases: [], scores: [], unmapped: []))
        let service = make(ScriptedIndexHeadless())
        service.setSourceEnabled("a", true)
        let count = IndexSnapshotStore(directory: dir).list().count
        service.setSourceEnabled("a", true)
        service.confirmAlias(source: "a", benchmarkModel: "GPT-6 Sol (high)")
        XCTAssertEqual(IndexSnapshotStore(directory: dir).list().count, count, "re-applying the same state must not write snapshots")
        XCTAssertEqual(count, 2, "the first rescore moved the empty scores, so it is a real change")
        service.setSourceEnabled("a", true)
        XCTAssertEqual(IndexSnapshotStore(directory: dir).list().count, 2)
    }
}
