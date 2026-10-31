import XCTest
import IntakeKit

/// "The newest valid snapshot is current" is the whole storage model, so these tests attack
/// "newest" (clock moved back, two writes in one second) and "valid" (a torn write, a file from
/// a newer Flight Deck), then rollback and retention, then the diff Settings shows.
final class IndexSnapshotStoreTests: XCTestCase {
    private var dir: URL!
    private var store: IndexSnapshotStore!
    private let t0: TimeInterval = 1_790_000_000

    override func setUpWithError() throws {
        dir = IndexFixtures.scratch()
        store = IndexSnapshotStore(directory: dir)
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    }

    private func snapshot(_ t: TimeInterval, score: Double = 0.5, v: Int = IndexSnapshot.currentVersion) -> IndexSnapshot {
        IndexSnapshot(v: v, createdAt: Date(timeIntervalSince1970: t), sources: [], aliases: [],
                      scores: [ModelScores(model: IndexFixtures.sol, dimensions: ["debugging": DimensionScore(score: score, confidence: 1)])],
                      unmapped: [])
    }
    private func score(_ s: IndexSnapshot?) -> Double? { s?.scores.first?.dimensions["debugging"]?.score }

    func testNewestValidIsCurrent() throws {
        try store.write(snapshot(t0, score: 0.4))
        try store.write(snapshot(t0 + 60, score: 0.6))
        XCTAssertEqual(score(store.current()?.snapshot), 0.6)
        XCTAssertEqual(store.current()?.ref.stamp, IndexStamp.string(Date(timeIntervalSince1970: t0 + 60)))
        XCTAssertEqual(score(store.previous(before: store.current()!.ref)?.snapshot), 0.4)
    }

    func testCorruptNewestSnapshotFallsBackToPreviousValid() throws {
        try store.write(snapshot(t0, score: 0.4))
        try Data("{ truncated".utf8).write(to: dir.appendingPathComponent(IndexStamp.string(Date(timeIntervalSince1970: t0 + 60)) + ".json"))
        XCTAssertEqual(score(store.current()?.snapshot), 0.4)
    }

    func testNewerVersionSnapshotIsSkipped() throws {
        try store.write(snapshot(t0, score: 0.4))
        let newer = snapshot(t0 + 60, score: 0.9, v: IndexSnapshot.currentVersion + 1)
        try IndexSnapshot.encoder().encode(newer)
            .write(to: dir.appendingPathComponent(IndexStamp.string(Date(timeIntervalSince1970: t0 + 60)) + ".json"))
        XCTAssertEqual(score(store.current()?.snapshot), 0.4, "a snapshot from a newer Flight Deck is not read as this version")
    }

    func testWriteAfterTheClockMovedBackStillBecomesCurrent() throws {
        try store.write(snapshot(t0, score: 0.4))
        let ref = try store.write(snapshot(t0 - 3600, score: 0.9))
        XCTAssertEqual(ref.stamp, IndexStamp.string(Date(timeIntervalSince1970: t0 + 1)))
        XCTAssertEqual(score(store.current()?.snapshot), 0.9)
    }

    func testTwoWritesInOneSecondBothSurvive() throws {
        try store.write(snapshot(t0, score: 0.4))
        try store.write(snapshot(t0, score: 0.5))
        XCTAssertEqual(store.list().count, 2)
        XCTAssertEqual(score(store.current()?.snapshot), 0.5)
    }

    func testRollBackMakesThePreviousCurrentAndKeepsTheFile() throws {
        try store.write(snapshot(t0, score: 0.4))
        try store.write(snapshot(t0 + 60, score: 0.6))
        XCTAssertEqual(score(try store.rollBack().snapshot), 0.4)
        XCTAssertEqual(score(store.current()?.snapshot), 0.4)
        XCTAssertEqual(store.list().map(\.rolledBack), [false, true])
        try store.write(snapshot(t0 + 120, score: 0.7))
        XCTAssertEqual(score(store.current()?.snapshot), 0.7, "a refresh after a rollback is current again")
    }

    func testRollBackWithNothingOlderThrows() throws {
        try store.write(snapshot(t0))
        XCTAssertThrowsError(try store.rollBack()) { XCTAssertEqual($0 as? IndexStoreError, .nothingToRollBackTo) }
        XCTAssertNotNil(store.current(), "a refused rollback leaves the current snapshot alone")
    }

    func testPruneKeepsTwelveNewestValid() throws {
        for i in 0..<14 { try store.write(snapshot(t0 + Double(i) * 60)) }
        try store.prune()
        XCTAssertEqual(store.list().count, 12)
        XCTAssertEqual(store.list().first?.stamp, IndexStamp.string(Date(timeIntervalSince1970: t0 + 120)))
    }

    func testForeignFilesAreIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "notes.txt", "2026-10-04.json"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        try store.write(snapshot(t0))
        XCTAssertEqual(store.list().count, 1)
        try store.prune()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path), "prune never touches the config")
    }

    func testDiffReportsMovedAppearedAndDisappeared() {
        let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet
        let old = IndexSnapshot(createdAt: Date(timeIntervalSince1970: t0), sources: [], aliases: [], scores: [
            ModelScores(model: sol, dimensions: ["debugging": DimensionScore(score: 0.4, confidence: 1),
                                                 "docs-prose": DimensionScore(score: 0.5, confidence: 1)]),
            ModelScores(model: opus, dimensions: ["debugging": DimensionScore(score: 0.7, confidence: 1)])], unmapped: [])
        let new = IndexSnapshot(createdAt: Date(timeIntervalSince1970: t0 + 60), sources: [], aliases: [], scores: [
            ModelScores(model: sol, dimensions: ["debugging": DimensionScore(score: 0.6, confidence: 1)]),
            ModelScores(model: opus, dimensions: ["debugging": DimensionScore(score: 0.705, confidence: 1)]),
            ModelScores(model: sonnet, dimensions: ["speed": DimensionScore(score: 0.3, confidence: 1)])], unmapped: [])
        let changes = SnapshotDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.map { "\(IndexKeys.key($0.model)) \($0.dimension)" },
                       ["claude/sonnet speed", "codex/gpt-6-sol[effort=high] docs-prose", "codex/gpt-6-sol[effort=high] debugging"])
        XCTAssertEqual(changes[2].delta ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(changes[0].before)
        XCTAssertNil(changes[1].after)
        XCTAssertEqual(SnapshotDiff.changes(from: nil, to: new), [], "nothing to compare with is no change, not everything new")
    }
}
