import CryptoKit
import XCTest
@testable import FlightDeckMobile

/// The phone's visual cache (P2a V3): bytes keyed by `(visualID, revision, path)`, kept until
/// the budget forces the least recently used out, and never a byte that failed its SHA-256.
final class VisualCacheTests: XCTestCase {
    private var dir: URL!
    private let clock = Clock()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VisualCache-\(UUID())", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A clock that moves one second per call, so "least recently used" is not a race on file
    /// timestamps.
    private func cache(budget: Int64 = 1_000) -> VisualCache {
        let clock = clock
        return VisualCache(directory: dir, budget: budget, now: { clock.next() })
    }

    private func sha(_ data: Data) -> String { VisualCache.sha256Hex(data) }
    private func key(_ id: String = "flow", _ r: Int = 1, _ path: String = "export/index.html") -> VisualKey {
        VisualKey(visualID: id, revision: r, path: path)
    }

    func testStoresAndReadsBackWhenTheShaMatches() {
        let c = cache()
        let bytes = Data("<p>hi</p>".utf8)
        XCTAssertTrue(c.store(bytes, for: key(), sha256: sha(bytes)))
        XCTAssertEqual(c.data(for: key(), sha256: sha(bytes)), bytes)
        XCTAssertEqual(c.totalBytes(), Int64(bytes.count))
    }

    func testAShaMismatchIsNeverCached() {
        let c = cache()
        let bytes = Data("tampered".utf8)
        XCTAssertFalse(c.store(bytes, for: key(), sha256: sha(Data("the real bytes".utf8))))
        XCTAssertNil(c.data(for: key(), sha256: sha(bytes)))
        XCTAssertNil(c.data(for: key(), sha256: sha(Data("the real bytes".utf8))))
        XCTAssertEqual(c.totalBytes(), 0)
        XCTAssertFalse(c.contains(key(), sha256: sha(bytes)))
        // And not an uppercase or short digest either: the comparison is on the whole hex string.
        XCTAssertFalse(c.store(bytes, for: key(), sha256: String(sha(bytes).prefix(10))))
    }

    func testTheCacheIsKeyedByRevisionAndPath() {
        let c = cache()
        let one = Data("one".utf8), two = Data("two".utf8)
        XCTAssertTrue(c.store(one, for: key("flow", 1), sha256: sha(one)))
        XCTAssertTrue(c.store(two, for: key("flow", 2), sha256: sha(two)))
        XCTAssertEqual(c.data(for: key("flow", 1), sha256: sha(one)), one)
        XCTAssertEqual(c.data(for: key("flow", 2), sha256: sha(two)), two)
        // r2's bytes are not an answer for r1, nor another path's for this one.
        XCTAssertNil(c.data(for: key("flow", 1), sha256: sha(two)))
        XCTAssertNil(c.data(for: key("flow", 1, "export/other.html"), sha256: sha(one)))
        XCTAssertNil(c.data(for: key("other", 1), sha256: sha(one)))
    }

    /// A visual id on another Mac can repeat `flow` r1 with other content. A hit needs the bytes
    /// the manifest now promises, so it is a miss, not the old picture.
    func testSameKeyOtherContentIsAMissAndReplacesTheOld() {
        let c = cache()
        let old = Data("old".utf8), new = Data("new!".utf8)
        XCTAssertTrue(c.store(old, for: key(), sha256: sha(old)))
        XCTAssertNil(c.data(for: key(), sha256: sha(new)))
        XCTAssertTrue(c.store(new, for: key(), sha256: sha(new)))
        XCTAssertEqual(c.data(for: key(), sha256: sha(new)), new)
        XCTAssertNil(c.data(for: key(), sha256: sha(old)))
        XCTAssertEqual(c.totalBytes(), Int64(new.count), "the replaced bytes are gone, not kept beside it")
    }

    func testTheLeastRecentlyUsedGoesFirstWhenOverBudget() {
        let c = cache(budget: 100)
        let a = Data(repeating: 1, count: 40), b = Data(repeating: 2, count: 40), d = Data(repeating: 3, count: 40)
        XCTAssertTrue(c.store(a, for: key("flow", 1, "a"), sha256: sha(a)))
        XCTAssertTrue(c.store(b, for: key("flow", 1, "b"), sha256: sha(b)))
        // Reading `a` makes `b` the oldest.
        XCTAssertNotNil(c.data(for: key("flow", 1, "a"), sha256: sha(a)))
        XCTAssertTrue(c.store(d, for: key("flow", 1, "d"), sha256: sha(d)))
        XCTAssertNotNil(c.data(for: key("flow", 1, "a"), sha256: sha(a)))
        XCTAssertNil(c.data(for: key("flow", 1, "b"), sha256: sha(b)))
        XCTAssertNotNil(c.data(for: key("flow", 1, "d"), sha256: sha(d)))
        XCTAssertLessThanOrEqual(c.totalBytes(), 100)
    }

    func testEvictionReachesAcrossRevisionsAndVisuals() {
        let c = cache(budget: 100)
        let a = Data(repeating: 1, count: 60), b = Data(repeating: 2, count: 60)
        XCTAssertTrue(c.store(a, for: key("flow", 1), sha256: sha(a)))
        XCTAssertTrue(c.store(b, for: key("other", 4), sha256: sha(b)))
        XCTAssertNil(c.data(for: key("flow", 1), sha256: sha(a)))
        XCTAssertEqual(c.data(for: key("other", 4), sha256: sha(b)), b)
    }

    func testWhatWasJustStoredIsNeverEvictedByItself() {
        let c = cache(budget: 10)
        let big = Data(repeating: 7, count: 50)
        XCTAssertTrue(c.store(big, for: key(), sha256: sha(big)))
        XCTAssertEqual(c.data(for: key(), sha256: sha(big)), big)
    }

    func testBytesSurviveANewCacheOverTheSameFolder() {
        let bytes = Data("kept".utf8)
        XCTAssertTrue(cache().store(bytes, for: key(), sha256: sha(bytes)))
        XCTAssertEqual(cache().data(for: key(), sha256: sha(bytes)), bytes)
    }

    /// The id and path are the Mac's words; neither can steer a file out of the cache folder.
    func testHostileIdsAndPathsStayInsideTheFolder() {
        let c = cache()
        let bytes = Data("x".utf8)
        XCTAssertFalse(c.store(bytes, for: key("../escape"), sha256: sha(bytes)))
        XCTAssertFalse(c.store(bytes, for: key("Flow"), sha256: sha(bytes)))
        XCTAssertFalse(c.store(bytes, for: key("flow", -1), sha256: sha(bytes)))
        XCTAssertTrue(c.store(bytes, for: key("flow", 1, "../../../escape"), sha256: sha(bytes)))
        let escaped = dir.deletingLastPathComponent().appendingPathComponent("escape")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0
    func next() -> Date {
        lock.withLock { tick += 1; return Date(timeIntervalSince1970: 1_800_000_000 + Double(tick)) }
    }
}
