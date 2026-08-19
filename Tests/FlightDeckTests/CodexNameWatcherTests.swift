import XCTest
@testable import FlightDeck

@MainActor
final class CodexNameWatcherTests: XCTestCase {
    private var dir: URL!
    private var index: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = dir.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ id: UUID, _ name: String) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","thread_name":"\#(name)","updated_at":"2026-08-19T16:47:49.135395Z"}"# + "\n"
    }

    func testRoutesARenameToTheThreadThatOwnsIt() throws {
        let mine = UUID(), theirs = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(mine) { seen.append($0) }
        watcher.drain() // prime

        try (line(theirs, "not mine") + line(mine, "mine")).data(using: .utf8)!.write(to: index)
        watcher.drain()

        XCTAssertEqual(seen, ["mine"], "the index is app-wide and carries threads we never made")
    }

    func testTheLastRenameWins() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()

        try (line(id, "first") + line(id, "second")).data(using: .utf8)!.write(to: index)
        watcher.drain()

        XCTAssertEqual(seen, ["first", "second"])
    }

    func testUnregisteringStopsDelivery() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()
        watcher.unregister(id)
        XCTAssertTrue(watcher.isEmpty)

        try line(id, "after").data(using: .utf8)!.write(to: index)
        watcher.drain()
        XCTAssertEqual(seen, [])
    }

    /// The load-bearing difference from every other watcher in the app. This file is shared
    /// and append-only, so a compaction must NOT replay history: each replayed line would
    /// re-apply a title the thread has since moved past.
    func testACompactedIndexDoesNotReplayStaleTitles() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()

        try (line(id, "old") + line(id, "current")).data(using: .utf8)!.write(to: index)
        watcher.drain()
        XCTAssertEqual(seen, ["old", "current"])

        // Codex compacts the index down to one line per thread.
        try line(id, "current").data(using: .utf8)!.write(to: index)
        watcher.drain()
        XCTAssertEqual(seen, ["old", "current"], "compaction is not news")
    }

    func testGarbageLinesAreIgnored() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()

        let junk = "not json\n" + #"{"id":"not-a-uuid","thread_name":"x"}"# + "\n"
            + #"{"id":"\#(id.uuidString.lowercased())"}"# + "\n"
        try (junk + line(id, "good")).data(using: .utf8)!.write(to: index)
        watcher.drain()

        XCTAssertEqual(seen, ["good"])
    }

    /// Codex honours `CODEX_HOME`; a watcher that ignored it would tail a file codex is not
    /// writing and report nothing, forever, with no error.
    func testTheDefaultPathFollowsCodexHome() {
        let url = CodexNameWatcher.defaultIndexURL
        XCTAssertEqual(url.lastPathComponent, "session_index.jsonl")
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                           URL(fileURLWithPath: home).standardizedFileURL.path)
        } else {
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".codex")
        }
    }
}
