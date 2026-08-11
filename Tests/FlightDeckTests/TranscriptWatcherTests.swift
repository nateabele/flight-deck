import XCTest
@testable import FlightDeck

@MainActor
final class TranscriptWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ title: String, _ sid: UUID) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(sid.uuidString.lowercased())"}"# + "\n"
    }

    /// All these tests prime the watcher with one `drain()` call while the file is still
    /// empty (or missing) before writing the content under test. That mirrors production:
    /// `start()` runs long before `claude` writes anything, so the watcher's first
    /// *successful* look at the file normally finds it empty. See
    /// `testSkipsContentThatExistedBeforeFirstDrain` for the case this priming is standing
    /// in for — a restored session, where the file is already large on the first look.

    func testReportsTitleAppendedAfterStart() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()
        watcher.drain() // prime while empty

        try (line("first", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["first"])
    }

    func testReportsOnlyTheLastTitleInABatch() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()
        watcher.drain() // prime while empty

        try (line("a", sid) + line("b", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["b"])
    }

    func testIgnoresUnrelatedLines() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()
        watcher.drain() // prime while empty

        let noise = #"{"type":"agent-name","agentName":"x","sessionId":"\#(sid.uuidString.lowercased())"}"# + "\n"
        try (noise + "{bad json\n").data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertTrue(seen.isEmpty)
    }

    func testHandlesFileCreatedAfterStart() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("later.jsonl")

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()   // file does not exist yet
        watcher.drain()   // prime: still missing, silent no-op

        FileManager.default.createFile(atPath: url.path, contents: Data())
        watcher.drain()   // prime: exists now but empty — this is the first successful look

        try (line("late", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["late"])
    }

    /// A drain that lands mid-write must not consume the partial line: the next drain
    /// has to see the completed line and report it.
    func testRecoversATitleSplitAcrossTwoDrains() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()
        watcher.drain() // prime while empty

        let full = line("split", sid)                      // includes trailing newline
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)

        try String(full[..<cut]).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertTrue(seen.isEmpty, "a partial line must not be reported")

        try full.data(using: .utf8)!.write(to: url)        // now complete
        watcher.drain()
        XCTAssertEqual(seen, ["split"], "the completed line must be recovered")
    }

    /// Pins the restore bug this exists to fix: a watcher pointed at a transcript that
    /// already contains content (a restored session's prior conversation) must not
    /// replay that content on its first drain — only bytes appended afterward. Without
    /// the seek-to-end seed, the stale title below would be reported and could clobber a
    /// rename made while `claude` wasn't running. See `TranscriptWatcher.drain()`.
    func testSkipsContentThatExistedBeforeFirstDrain() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("existing.jsonl")
        try (line("stale", sid)).data(using: .utf8)!.write(to: url)

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()
        watcher.drain()
        XCTAssertTrue(seen.isEmpty, "pre-existing content must not be replayed")

        try (line("stale", sid) + line("fresh", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["fresh"], "content appended after the seed must still be tailed")
    }
}
