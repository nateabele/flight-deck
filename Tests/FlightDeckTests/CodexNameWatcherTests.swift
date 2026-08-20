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

    /// The index is derived from a home the caller names — a watcher pointed at the wrong
    /// `CODEX_HOME` tails a file codex is not writing and reports nothing, forever, with no
    /// error. This pins the fallback the account-less callers get; the per-account half, and
    /// why reading `CODEX_HOME` out of Flight Deck's own environment here was a bug, are in
    /// `AccountObservationRootTests`.
    func testTheDefaultPathIsTheBuiltInHomesIndex() {
        let url = CodexNameWatcher.defaultIndexURL
        XCTAssertEqual(url, CodexNameWatcher.indexURL(forHome: AgentID.codex.builtInHome))
        XCTAssertEqual(url.lastPathComponent, "session_index.jsonl")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".codex")
    }
}
