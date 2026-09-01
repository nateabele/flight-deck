import XCTest
import FleetKit
@testable import FlightDeck

/// The one-time walk over transcript history.
///
/// The expensive step in the whole design: 684 MB of JSONL parsed to extract ~34 MB of
/// conversation. Everything asserted here is about making that cost payable once and
/// survivable when interrupted.
final class SearchIndexBuilderTests: XCTestCase {
    private var directory: URL!
    private var index: SQLiteSearchIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try SQLiteSearchIndex(at: directory.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a transcript. `conversation` is the file's basename, matching how claude names
    /// them and how the builder derives a conversation id.
    @discardableResult
    private func write(_ lines: [String], conversation: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(conversation).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func userLine(_ text: String) -> String {
        #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"\#(text)"}}"#
    }

    private func entries(_ folder: URL, project: String = "/w/fd") -> [SearchCorpus.Entry] {
        [SearchCorpus.Entry(projectPath: project, directory: folder)]
    }

    func testEveryTranscriptInScopeIsIndexed() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        try write([userLine("the rename bug")], conversation: "c1", in: folder)
        try write([userLine("something else")], conversation: "c2", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
        XCTAssertEqual(try index.search(#""something"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// The property that makes a second run cheap: a file already read through its end
    /// contributes no new rows.
    func testASecondPassOverUnchangedFilesAddsNothing() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        try write([userLine("the rename bug")], conversation: "c1", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// Only appended bytes are re-read, which is what keeps a growing transcript cheap
    /// rather than re-parsing 23 MB every pass.
    func testOnlyAppendedBytesAreIndexedOnASecondPass() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let url = try write([userLine("first message")], conversation: "c1", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((userLine("second message") + "\n").utf8))
        try handle.close()

        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.search(#""first"*"#, projects: ["/w/fd"], limit: 10).count, 1)
        XCTAssertEqual(try index.search(#""second"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// A cancelled backfill must stop AT the next file boundary — not mid-file, and not
    /// merely "eventually" — and a later resume must complete exactly the rest.
    ///
    /// Cancelling right after `Task { }` races the child actor even starting: with small
    /// fixtures the walk can finish before the cancel is ever observed, which is why the
    /// old version of this test passed under every outcome including cancellation being a
    /// complete no-op. This version cancels the real `Task` from inside a wrapped index's
    /// own `ingest`, the instant the first file's rows actually land — deterministic,
    /// because it is driven by the walk's own progress rather than scheduling luck.
    func testACancelledBuildStopsAtTheNextFileBoundary() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        for i in 0..<5 { try write([userLine("rename \(i)")], conversation: "c\(i)", in: folder) }

        let cancelling = CancellingIndex(wrapping: index)
        let builder = SearchIndexBuilder(index: cancelling)
        let task = Task { await builder.build(entries(folder), progress: { _ in }) }
        cancelling.setCancelTarget(task)
        await task.value

        // Exactly the first file's row landed — proving the walk stopped at the very next
        // file boundary, not "at least one" and not all five.
        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 100).count, 1)

        // Resuming with an uncancelled build completes exactly the rest.
        await builder.build(entries(folder), progress: { _ in })
        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 100).count, 5)
    }

    /// Forwards every call to a real index, but cancels a captured `Task` the moment the
    /// very first `ingest` call lands rows — used to make cancellation-mid-walk
    /// deterministic in a test rather than a race against `Task {}` starting up.
    private final class CancellingIndex: SearchIndex {
        private let wrapped: SearchIndex
        private var target: Task<Void, Never>?
        private var hasCancelled = false

        init(wrapping index: SearchIndex) { wrapped = index }

        func setCancelTarget(_ task: Task<Void, Never>) { target = task }

        func ingest(
            _ messages: [IndexedMessage], from source: URL, projectPath: String, offset: UInt64?
        ) throws {
            try wrapped.ingest(messages, from: source, projectPath: projectPath, offset: offset)
            if !hasCancelled {
                hasCancelled = true
                target?.cancel()
            }
        }

        func readOffset(for source: URL) -> UInt64 { wrapped.readOffset(for: source) }

        func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit] {
            try wrapped.search(query, projects: projects, limit: limit)
        }

        func conversationNames() throws -> [String: IndexedConversation] {
            try wrapped.conversationNames()
        }

        func setConversationName(_ name: String, projectPath: String, for id: String) throws {
            try wrapped.setConversationName(name, projectPath: projectPath, for: id)
        }

        func prune(keepingSources: Set<URL>, projects: Set<String>) throws {
            try wrapped.prune(keepingSources: keepingSources, projects: projects)
        }

        func messageCount(forConversation id: String) throws -> Int {
            try wrapped.messageCount(forConversation: id)
        }
    }

    /// The primary scenario the whole task exists for: a first backfill of a transcript
    /// large enough to span several intra-loop batch commits (`batchSize` is 500, so this
    /// writes 1200 lines — three commits: two full batches and a remainder).
    ///
    /// Every intra-loop commit before this fix passed `offset: 0`, which `SQLiteSearchIndex`
    /// treats as "this source restarted, delete its rows" — so each batch silently deleted
    /// the batch before it, and only the last batch and the final remainder survived. No
    /// smaller fixture forces a second intra-loop commit, which is why nothing else in this
    /// file catches it.
    func testABatchSpanningTranscriptIndexesEveryMessage() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let lines = (0..<1200).map { userLine("message \($0)") }
        try write(lines, conversation: "c1", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.messageCount(forConversation: "c1"), 1200)
    }

    /// A later pass reads only its newly appended lines, not the whole file, so it cannot
    /// see an earlier pass's rename record. Without a guard, its first plain user message —
    /// resolved as a fallback name because this pass's own line set has no rename in it —
    /// would silently overwrite the real name on every later pass.
    func testANameFromAnEarlierPassSurvivesALaterPassWithOnlyUserMessages() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let url = try write(
            [#"{"type":"custom-title","customTitle":"rename-break"}"#, userLine("hello")],
            conversation: "c1", in: folder
        )

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((userLine("a later message, no rename here") + "\n").utf8))
        try handle.close()

        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.conversationNames()["c1"]?.name, "rename-break")
    }

    /// The overlay footer reports this. A search that silently returns nothing while the
    /// index is still filling is worse than one that says it is still reading.
    func testProgressIsReportedAgainstTheTotalFileCount() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        for i in 0..<3 { try write([userLine("m\(i)")], conversation: "c\(i)", in: folder) }

        var seen: [SearchIndexBuilder.Progress] = []
        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { seen.append($0) })

        XCTAssertEqual(seen.last, SearchIndexBuilder.Progress(indexed: 3, total: 3))
        XCTAssertTrue(seen.allSatisfy { $0.total == 3 })
    }

    /// Conversations no longer on disk, and projects no longer in the sidebar, are dropped
    /// at the start of a pass — otherwise the index only grows and starts answering with
    /// things that cannot be opened.
    func testFilesThatHaveDisappearedArePruned() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let doomed = try write([userLine("rename me")], conversation: "c1", in: folder)
        try write([userLine("rename survivor")], conversation: "c2", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })
        try FileManager.default.removeItem(at: doomed)
        await builder.build(entries(folder), progress: { _ in })

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.map(\.conversationID), ["c2"])
    }

    /// `TailReader.lines` omits blank lines, but a blank line's own byte is still consumed —
    /// so the record after it must not silently report an offset that is short by the blank
    /// line's width. Regression for exactly that: before the fix, this walker reconstructed
    /// offsets by summing each *emitted* line's length, which drifts the moment a blank line
    /// is consumed without producing an element.
    func testARecordAfterABlankLineReportsItsTrueOffset() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let first = userLine("first, alpha")
        try write([first, "", userLine("second, beta-unique")], conversation: "c1", in: folder)
        // first's own line, then its newline, then the blank line's newline.
        let expectedOffset = first.utf8.count + 1 + 1

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        let hits = try index.search(#""beta"*"#, projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.offset, expectedOffset)
    }

    /// Names come from the transcript itself, via the same rules the sidebar uses, so a
    /// result row for a conversation with no open tab is still called something meaningful.
    func testConversationNamesAreRecorded() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        try write(
            [#"{"type":"custom-title","customTitle":"rename-break"}"#, userLine("hello")],
            conversation: "c1", in: folder
        )

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.conversationNames()["c1"]?.name, "rename-break")
    }
}
