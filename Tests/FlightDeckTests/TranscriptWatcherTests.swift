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

    func testReportsTitleAppendedAfterStart() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()

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

        let full = line("split", sid)                      // includes trailing newline
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)

        try String(full[..<cut]).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertTrue(seen.isEmpty, "a partial line must not be reported")

        try full.data(using: .utf8)!.write(to: url)        // now complete
        watcher.drain()
        XCTAssertEqual(seen, ["split"], "the completed line must be recovered")
    }
}
