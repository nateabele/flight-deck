import XCTest
import IntakeKit

/// Snapshots and the config are the index's only state on disk. These tests pin that a snapshot
/// round-trips exactly, that its file stamp is UTC whatever zone the Mac is in (a zone change
/// must never reorder which snapshot is newest), and that a config Flight Deck cannot read is
/// moved aside rather than overwritten — it holds the user's confirmed aliases and hand scores.
final class IndexSnapshotCodingTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21T14:13:20Z

    static func sample(at: Date) -> IndexSnapshot {
        let row = AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent,
                              url: "https://www.tbench.ai/leaderboard", retrievedAt: "2026-09-21T14:13:20Z", quotedFigure: "61.3%")
        return IndexSnapshot(
            createdAt: at,
            sources: [SourceResult(sourceID: "terminal-bench", rows: [row], refreshedAt: at, tokens: 1200),
                      SourceResult(sourceID: "aider-polyglot", rows: [], stale: true, error: "token cap reached", refreshedAt: nil)],
            aliases: [AliasEntry(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)],
            scores: [ModelScores(model: IndexFixtures.sol, dimensions: [
                "tool-use-reliability": DimensionScore(score: 1, confidence: 0.5, sources: ["terminal-bench"])])],
            unmapped: [UnmappedName(source: "terminal-bench", benchmarkModel: "Mystery-1")])
    }

    func testSnapshotRoundTrips() throws {
        let s = Self.sample(at: at)
        let data = try IndexSnapshot.encoder().encode(s)
        XCTAssertEqual(try IndexSnapshot.decoder().decode(IndexSnapshot.self, from: data), s)
    }

    func testStampIsUTCWhateverTheLocalTimeZone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!   // UTC+14
        XCTAssertEqual(IndexStamp.string(at), "2026-09-21T141320Z")
        XCTAssertEqual(IndexStamp.date("2026-09-21T141320Z"), at)
        XCTAssertNil(IndexStamp.date("2026-09-21"), "a bare date is not a stamp")
        XCTAssertNil(IndexStamp.date("config"))
        XCTAssertLessThan(IndexStamp.string(at), IndexStamp.string(at.addingTimeInterval(1)), "stamps sort as time does")
    }

    func testConfigMissingKeysFallBackToDefaults() throws {
        let c = try IndexSnapshot.decoder().decode(IndexConfig.self, from: Data(#"{"v":1}"#.utf8))
        XCTAssertEqual(c.sources, IndexSourceRegistry.initial)
        XCTAssertEqual(c.agent, .standard)
        XCTAssertEqual(c.aliases, AliasTable())
        XCTAssertNil(c.lastRefreshAttemptAt)
    }

    func testConfigRoundTripsThroughDisk() throws {
        let dir = IndexFixtures.scratch()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var c = IndexConfig.initial()
        c.manual = [ManualModelScores(model: ModelRef(agent: .gemini, model: "ollama/qwen"), dimensions: ["debugging": 0.7],
                                      inheritFrom: IndexFixtures.sol)]
        c.lastRefreshAttemptAt = at
        let url = dir.appendingPathComponent("config.json")
        try c.save(to: url)
        let (loaded, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(loaded, c)
        XCTAssertNil(problem)
        XCTAssertEqual(loaded.manual.first?.discount, 0.85)
    }

    func testUnreadableConfigIsMovedAsideAndReported() throws {
        let dir = IndexFixtures.scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: url)
        let (config, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(config, IndexConfig.initial())
        XCTAssertNotNil(problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the unreadable file must not stay where the next save would overwrite it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.unreadable-") }.count, 1)
    }

    func testNewerVersionConfigIsMovedAsideAndReported() throws {
        let dir = IndexFixtures.scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"v":99}"#.utf8).write(to: url)
        let (config, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(config, IndexConfig.initial())
        XCTAssertNotNil(problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.unreadable-") }.count, 1)
    }

    func testExistingButUnreadableFileIsNotTreatedAsMissing() throws {
        let dir = IndexFixtures.scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"v":1}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let (config, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(config, IndexConfig.initial())
        XCTAssertNotNil(problem, "a file that exists but cannot be read is a problem, not a first launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "it must be moved aside, not left for the next save")
    }

    func testFailedMoveLeavesTheOriginalAndBlocksSaving() throws {
        let dir = IndexFixtures.scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let original = Data("{ not json".utf8)
        try original.write(to: url)
        // A read-only directory refuses both the move and the copy.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let (config, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(try Data(contentsOf: url), original, "the original must be left exactly where it is")
        XCTAssertTrue(config.isSaveBlocked)
        XCTAssertTrue(try XCTUnwrap(problem).contains("left untouched"), "the message must not claim a move that did not happen")
        XCTAssertThrowsError(try config.save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original, "a later save must not overwrite it")
    }

    func testTwoFailuresInTheSameSecondGetDistinctAsideNames() throws {
        let dir = IndexFixtures.scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        for _ in 0..<2 {
            try Data("{ bad".utf8).write(to: url)
            _ = IndexConfig.load(from: url)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.unreadable-") }.count, 2)
    }

    func testMissingConfigIsInitialWithoutAProblem() {
        let (config, problem) = IndexConfig.load(from: IndexFixtures.scratch().appendingPathComponent("config.json"))
        XCTAssertEqual(config, IndexConfig.initial())
        XCTAssertNil(problem)
    }
}
