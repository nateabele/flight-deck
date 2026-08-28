import XCTest
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

    /// A cancelled backfill must leave the offsets it did commit, so the next launch
    /// resumes rather than starting over. Nothing here asserts *where* it stopped — only
    /// that stopping is not destructive.
    func testACancelledBuildKeepsWhatItAlreadyCommitted() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        for i in 0..<20 { try write([userLine("rename \(i)")], conversation: "c\(i)", in: folder) }

        let builder = SearchIndexBuilder(index: index)
        let task = Task { await builder.build(entries(folder), progress: { _ in }) }
        task.cancel()
        await task.value

        // Whatever was committed stays committed and is not double-counted on resume.
        let before = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 100).count
        await builder.build(entries(folder), progress: { _ in })
        let after = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 100).count

        XCTAssertGreaterThanOrEqual(after, before)
        XCTAssertEqual(after, 20)
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
