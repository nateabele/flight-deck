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

    /// Most of these tests prime the watcher with one `drain()` call while the file is
    /// still empty (or missing) before writing the content under test, so that what they
    /// assert about is unambiguously *appended* bytes. The two cases that decide where a
    /// watcher starts reading at all are pinned separately:
    /// `testSkipsContentThatExistedBeforeFirstDrain` (a restored session, whose file is
    /// already large on the first look, must not be replayed) and
    /// `testReportsATitleInAFileThatDidNotExistAtStart` (a fresh session, whose file is
    /// created by `claude` with content already in it, must not be skipped).

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

    /// The counterpart to `testSkipsContentThatExistedBeforeFirstDrain`, and the case
    /// production actually hits on every new session.
    ///
    /// `claude` buffers its startup records and does not create the transcript until it
    /// first has something to persist — for a session renamed before its first turn, that
    /// is the `/rename` itself. So the file does not appear empty and then grow, as
    /// `testHandlesFileCreatedAfterStart` has it: it springs into existence with the rename
    /// record already inside. Seeking past that on the first successful look swallowed the
    /// record, which is why the *first* `/rename` of a session never reached the sidebar
    /// while every later one did.
    ///
    /// Note the deliberately missing prime between creation and content: the file is made
    /// and filled in one step, exactly as `claude` does it, so the watcher never gets a
    /// look at it empty.
    func testReportsATitleInAFileThatDidNotExistAtStart() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("born-with-content.jsonl")

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()
        watcher.drain()   // first look: `claude` is still booting, nothing on disk yet
        XCTAssertTrue(seen.isEmpty, "a missing file reports nothing")

        try (line("first", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["first"], "a file created after we started watching is ours from byte 0")
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
