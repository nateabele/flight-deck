import XCTest
import FleetKit
@testable import FlightDeck

/// The index against a real SQLite file in a temp directory.
///
/// Not a fake: FTS5's tokenizer, prefix matching and `snippet()` are the behaviour under
/// test, and a stub of them would assert nothing about whether search actually works.
final class SQLiteSearchIndexTests: XCTestCase {
    private var directory: URL!
    private var index: SQLiteSearchIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try SQLiteSearchIndex(at: directory.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func source(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func message(
        _ text: String, conversation: String = "c1", at seconds: TimeInterval = 0,
        offset: Int = 0
    ) -> IndexedMessage {
        IndexedMessage(
            conversationID: conversation, role: .user, text: text,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + seconds), offset: offset
        )
    }

    func testAnIngestedMessageIsFoundByAWordInIt() throws {
        try index.ingest(
            [message("don't fire a rename when the session already has the name")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 100
        )

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.conversationID, "c1")
        XCTAssertEqual(hits.first?.projectPath, "/w/fd")
    }

    /// The preview the user asked for: two lines with the matched terms marked. The markers
    /// are sentinels rather than ranges so nothing has to carry a `String.Index` across the
    /// SQLite boundary.
    func testTheSnippetMarksTheMatchedTermWithSentinels() throws {
        try index.ingest(
            [message("don't fire a rename when the session already has the given name")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        let snippet = try XCTUnwrap(
            index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).first?.snippet
        )

        XCTAssertTrue(snippet.contains(SnippetSentinel.open))
        XCTAssertTrue(snippet.contains(SnippetSentinel.close))
        let marked = snippet.split(separator: SnippetSentinel.open)
            .dropFirst().compactMap { $0.split(separator: SnippetSentinel.close).first }
        XCTAssertEqual(marked.map(String.init), ["rename"])
    }

    /// Prefix matching is what makes results narrow while a word is still being typed.
    func testAPrefixQueryMatchesAPartialWord() throws {
        try index.ingest(
            [message("the rename bug")], from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        XCTAssertEqual(try index.search(#""renam"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// The corpus is bounded by the sidebar. A project closed since the last prune must not
    /// leak its conversations into results — and the filter has to live in SQL rather than be
    /// applied to the results afterwards, or enough out-of-scope rows can fill the LIMIT before
    /// the filter ever runs and silently shrink what an in-scope search returns. `limit + 1`
    /// out-of-scope rows against `limit: 1` is what makes that distinction bite: with the
    /// filter applied after LIMIT, a single-slot query has nowhere left for the in-scope hit.
    func testResultsAreConfinedToTheNamedProjects() throws {
        let limit = 1
        for n in 0...limit {
            try index.ingest(
                [message("rename", conversation: "out-\(n)")],
                from: source("out-\(n).jsonl"), projectPath: "/w/other", offset: 1
            )
        }
        try index.ingest(
            [message("rename", conversation: "c1")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: limit)

        XCTAssertEqual(hits.map(\.conversationID), ["c1"])
    }

    /// The builder resumes from this. It must survive the process going away, which is what
    /// makes a cancelled backfill cost nothing on the next launch.
    func testTheReadOffsetRoundTripsAndSurvivesReopening() throws {
        try index.ingest([message("hi")], from: source("a.jsonl"), projectPath: "/w/fd", offset: 4096)
        XCTAssertEqual(index.readOffset(for: source("a.jsonl")), 4096)

        let url = directory.appendingPathComponent("index.sqlite")
        index = nil
        let reopened = try SQLiteSearchIndex(at: url)

        XCTAssertEqual(reopened.readOffset(for: source("a.jsonl")), 4096)
    }

    func testAnUnknownSourceStartsAtZero() {
        XCTAssertEqual(index.readOffset(for: source("never-seen.jsonl")), 0)
    }

    /// A conversation deleted on disk, or a project removed from the sidebar, must stop
    /// producing results — otherwise the index only ever grows and starts answering with
    /// things the user cannot open.
    func testPruningDropsSourcesAndProjectsThatAreNoLongerInScope() throws {
        try index.ingest(
            [message("rename", conversation: "c1")],
            from: source("keep.jsonl"), projectPath: "/w/fd", offset: 1
        )
        try index.ingest(
            [message("rename", conversation: "c2")],
            from: source("drop.jsonl"), projectPath: "/w/gone", offset: 1
        )

        try index.prune(keepingSources: [source("keep.jsonl")], projects: ["/w/fd"])

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd", "/w/gone"], limit: 10)
        XCTAssertEqual(hits.map(\.conversationID), ["c1"])
        XCTAssertEqual(index.readOffset(for: source("drop.jsonl")), 0)
    }

    /// Guards the order `deleteRows` runs its two deletes in. Deleting `message` before
    /// `message_fts` leaves an orphaned FTS posting behind — SQLite reuses the freed rowid for
    /// the next inserted message, so the orphaned posting for the deleted term keeps matching,
    /// and search returns the *new, unrelated* message's conversation and snippet for a query
    /// that should hit nothing. Checking for an empty `snippet()`, the brief's own hint for
    /// this bug, does not catch it: the failure is a wrong result, not an empty one, and only
    /// shows up by checking which conversation actually came back.
    func testDeletingASourceDoesNotLeakItsFreedRowidToAnUnrelatedMessage() throws {
        try index.ingest(
            [message("alpha-unique term", conversation: "cA")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        // Drops source A's row entirely, freeing its rowid for reuse.
        try index.prune(keepingSources: [], projects: [])

        // A different message, on a different source, with unrelated text — the next insert
        // after the table went empty lands on the freed rowid.
        try index.ingest(
            [message("totally different content", conversation: "cB")],
            from: source("b.jsonl"), projectPath: "/w/fd", offset: 1
        )

        XCTAssertEqual(try index.search(#""alpha"*"#, projects: ["/w/fd"], limit: 10), [])
    }

    /// Re-ingesting a file from offset 0 — a transcript replaced under the same path, which
    /// `TailReader`'s `.restartFromZero` policy already handles — must replace its rows
    /// rather than double every message in it.
    func testReingestingFromZeroReplacesRatherThanDuplicates() throws {
        let file = source("a.jsonl")
        try index.ingest([message("rename")], from: file, projectPath: "/w/fd", offset: 50)
        try index.ingest([message("rename")], from: file, projectPath: "/w/fd", offset: 0)

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// Recency orders the transcript tier, so the timestamp has to survive the round trip
    /// intact rather than being approximated by insertion order.
    func testTimestampsRoundTrip() throws {
        try index.ingest(
            [message("rename", at: 1234)], from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        let hit = try XCTUnwrap(index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).first)
        XCTAssertEqual(hit.timestamp.timeIntervalSince1970, 1_800_001_234, accuracy: 0.001)
    }

    /// Opening a file written by an older schema must not throw and must not return
    /// nonsense — the index is a cache, so the answer is to discard and rebuild.
    func testAnIncompatibleSchemaIsDiscardedRatherThanFailingToOpen() throws {
        let url = directory.appendingPathComponent("stale.sqlite")
        try Data("not a sqlite database at all".utf8).write(to: url)

        let rebuilt = try SQLiteSearchIndex(at: url)

        XCTAssertEqual(rebuilt.readOffset(for: source("a.jsonl")), 0)
    }

    /// Backfill and live ingest can both cover the same appended bytes — the live watcher adds
    /// rows without advancing the read position, so the next backfill pass re-reads them. The
    /// uniqueness constraint is what makes that overlap harmless instead of double-counting every
    /// message in it.
    func testIngestingTheSameMessageTwiceYieldsOneHit() throws {
        let message = message("the rename bug")
        try index.ingest([message], from: source("a.jsonl"), projectPath: "/w/fd", offset: nil)
        try index.ingest([message], from: source("a.jsonl"), projectPath: "/w/fd", offset: nil)

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// One transcript record can carry two `text` blocks written with the same timestamp,
    /// so `(conversationID, timestamp)` is not unique — before `TranscriptHit.rowID` existed,
    /// `SearchRanker` built the result id from that pair, both of these rows collapsed to the
    /// same id, and `SearchModel.moveSelection(by:)`'s `firstIndex(id:)` could never advance
    /// past the first one: the selection wedged. Ranking against real duplicate rows out of
    /// SQLite (rather than hand-built `TranscriptHit`s) is what makes this catch a collision
    /// in `rowID` itself, not just in the id string built from it.
    func testDuplicateConversationAndTimestampProduceDistinctResultIDs() throws {
        try index.ingest(
            [
                message("alpha shared-term", conversation: "c1"),
                message("beta shared-term", conversation: "c1"),
            ],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        let hits = try index.search(#""shared"*"#, projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.count, 2, "sanity: both messages matched")

        let results = SearchRanker.rank(names: [], query: "shared", transcripts: hits)
        XCTAssertEqual(
            Set(results.map(\.id)).count, 2,
            "two distinct messages must not collapse to the same result id"
        )
    }

    /// A live ingest must not move the read position, or the backfill would resume from it and
    /// skip everything before — which for an open session is its entire history.
    func testLiveIngestDoesNotAdvanceTheReadOffset() throws {
        try index.ingest([message("hi")], from: source("a.jsonl"), projectPath: "/w/fd", offset: 4096)
        try index.ingest([message("later")], from: source("a.jsonl"), projectPath: "/w/fd", offset: nil)

        XCTAssertEqual(index.readOffset(for: source("a.jsonl")), 4096)
    }

    /// Two writers reach this index in the real app: `SearchIndexBuilder` backfilling from
    /// its own actor, and `ClaudeRuntime`'s live `onMessages` hook ingesting from the main
    /// actor as a session streams. Without `transactionLock`, one writer's `BEGIN IMMEDIATE`
    /// landing while the other's transaction is still open fails with "cannot start a
    /// transaction within a transaction" — silently, because both `ingest` call sites use
    /// `try?` — and the failed writer's entire batch is lost, not partially written, because
    /// the failure is at `BEGIN` itself, before any row is inserted.
    ///
    /// One writer runs detached, the other on the calling thread, each pushing a batch large
    /// enough (many separate prepare/step/reset calls per row) that its transaction stays
    /// open long enough for the other's `BEGIN` to have a real chance of landing inside it.
    func testConcurrentIngestsDoNotLoseEachOthersMessages() async throws {
        let count = 2000
        let detachedBatch = (0..<count).map { message("alpha-\($0)", conversation: "cA") }
        let callerBatch = (0..<count).map { message("beta-\($0)", conversation: "cB") }
        let index = self.index!

        async let detached: Void = Task.detached {
            try? index.ingest(
                detachedBatch, from: self.source("a.jsonl"), projectPath: "/w/fd", offset: nil
            )
        }.value
        try? index.ingest(callerBatch, from: source("b.jsonl"), projectPath: "/w/fd", offset: nil)
        await detached

        XCTAssertEqual(try index.messageCount(forConversation: "cA"), count)
        XCTAssertEqual(try index.messageCount(forConversation: "cB"), count)
    }
}
