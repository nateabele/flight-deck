import XCTest
@testable import FlightDeck

/// Live sessions index by riding the poll that already exists.
///
/// `TranscriptWatcher` reads and parses every appended line to find titles and subagent
/// counts. Extraction costs one more pass over data already in hand, which is what keeps
/// the conversation you are typing in searchable without a second reader or a second timer.
@MainActor
final class TranscriptWatcherIndexingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-indexing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAppendedConversationTextIsReportedToTheIndexingHook() throws {
        let sessionID = UUID()
        let url = directory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var indexed: [IndexedMessage] = []
        let watcher = TranscriptWatcher(
            sessionID: sessionID, url: url,
            onTitle: { _ in },
            onMessages: { indexed += $0 }
        )
        watcher.drain()   // establishes the start position on the empty file

        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"the rename bug"}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()

        watcher.drain()

        XCTAssertEqual(indexed.map(\.text), ["the rename bug"])
        XCTAssertEqual(indexed.first?.conversationID, sessionID.uuidString.lowercased())
    }

    /// The hook is optional and defaulted, so every existing call site keeps compiling and
    /// keeps costing exactly what it did.
    func testAWatcherWithNoIndexingHookStillReportsTitles() throws {
        let sessionID = UUID()
        let url = directory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var title: String?
        let watcher = TranscriptWatcher(sessionID: sessionID, url: url, onTitle: { title = $0 })
        watcher.drain()

        let line = #"{"type":"custom-title","customTitle":"rename-break","sessionId":"\#(sessionID.uuidString.lowercased())"}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()

        watcher.drain()

        XCTAssertEqual(title, "rename-break")
    }

    /// Catches the failure `testAWatcherWithNoIndexingHookStillReportsTitles` cannot: that
    /// test only proves titles still arrive, not that extraction was skipped. `Scan.read` is
    /// what actually decides whether to pay for `TranscriptExtractor.messages(inObject:)`, so
    /// assert directly against it — `wantsMessages: false` must come back with `messages`
    /// empty even for a line that plainly contains indexable text.
    func testScanReadSkipsExtractionWhenNoIndexingHookIsWanted() throws {
        let sessionID = UUID()
        let url = directory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"the rename bug"}}"#
        try Data((line + "\n").utf8).write(to: url)

        let scan = Scan.read(
            url: url, offset: 0, hasChosenStart: true, sessionID: sessionID, wantsMessages: false
        )

        XCTAssertTrue(scan.messages.isEmpty)
    }
}
