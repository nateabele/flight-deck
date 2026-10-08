import XCTest
import IntakeKit
import FleetKit
import SQLite3
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

    /// A claude-in-the-project-root ref, matching what every test here assumed implicitly
    /// before `ingest` took one — most of these tests are about the message/offset machinery,
    /// not about agent attribution, so their `ref` is deliberately the boring default.
    private func ref(
        _ url: URL, projectPath: String, agent: AgentID = .claude, provenance: String? = nil,
        workingDirectory: String? = nil
    ) -> TranscriptRef {
        TranscriptRef(
            url: url, projectPath: projectPath, accountHome: directory,
            workingDirectory: workingDirectory ?? projectPath, conversationID: "c1",
            agent: agent, provenance: provenance, indexedName: nil, modified: Date()
        )
    }

    func testAnIngestedMessageIsFoundByAWordInIt() throws {
        try index.ingest(
            [message("don't fire a rename when the session already has the name")],
            for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 100
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
            for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
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
            [message("the rename bug")], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
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
                for: ref(source("out-\(n).jsonl"), projectPath: "/w/other"), offset: 1
            )
        }
        try index.ingest(
            [message("rename", conversation: "c1")],
            for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
        )

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: limit)

        XCTAssertEqual(hits.map(\.conversationID), ["c1"])
    }

    /// The builder resumes from this. It must survive the process going away, which is what
    /// makes a cancelled backfill cost nothing on the next launch.
    func testTheReadOffsetRoundTripsAndSurvivesReopening() throws {
        try index.ingest([message("hi")], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 4096)
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
            for: ref(source("keep.jsonl"), projectPath: "/w/fd"), offset: 1
        )
        try index.ingest(
            [message("rename", conversation: "c2")],
            for: ref(source("drop.jsonl"), projectPath: "/w/gone"), offset: 1
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
            for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
        )

        // Drops source A's row entirely, freeing its rowid for reuse.
        try index.prune(keepingSources: [], projects: [])

        // A different message, on a different source, with unrelated text — the next insert
        // after the table went empty lands on the freed rowid.
        try index.ingest(
            [message("totally different content", conversation: "cB")],
            for: ref(source("b.jsonl"), projectPath: "/w/fd"), offset: 1
        )

        XCTAssertEqual(try index.search(#""alpha"*"#, projects: ["/w/fd"], limit: 10), [])
    }

    /// Re-ingesting a file from offset 0 — a transcript replaced under the same path, which
    /// `TailReader`'s `.restartFromZero` policy already handles — must replace its rows
    /// rather than double every message in it.
    func testReingestingFromZeroReplacesRatherThanDuplicates() throws {
        let file = source("a.jsonl")
        try index.ingest([message("rename")], for: ref(file, projectPath: "/w/fd"), offset: 50)
        try index.ingest([message("rename")], for: ref(file, projectPath: "/w/fd"), offset: 0)

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// Recency orders the transcript tier, so the timestamp has to survive the round trip
    /// intact rather than being approximated by insertion order.
    func testTimestampsRoundTrip() throws {
        try index.ingest(
            [message("rename", at: 1234)], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
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
        try index.ingest([message], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: nil)
        try index.ingest([message], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: nil)

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
            for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
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
        try index.ingest([message("hi")], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 4096)
        try index.ingest([message("later")], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: nil)

        XCTAssertEqual(index.readOffset(for: source("a.jsonl")), 4096)
    }

    /// Three writers reach this index in the real app: `SearchIndexBuilder` backfilling from
    /// its own actor, and `ClaudeRuntime` and `CodexRuntime`'s live `onMessages` hooks
    /// ingesting from the main actor as a session streams. Without `transactionLock`, one
    /// writer's `BEGIN IMMEDIATE` landing while another's transaction is still open fails with
    /// "cannot start a transaction within a transaction" — silently, because every `ingest`
    /// call site uses `try?` — and the failed writer's entire batch is lost, not partially
    /// written, because the failure is at `BEGIN` itself, before any row is inserted.
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
                detachedBatch, for: self.ref(self.source("a.jsonl"), projectPath: "/w/fd"),
                offset: nil
            )
        }.value
        try? index.ingest(callerBatch, for: ref(source("b.jsonl"), projectPath: "/w/fd"), offset: nil)
        await detached

        XCTAssertEqual(try index.messageCount(forConversation: "cA"), count)
        XCTAssertEqual(try index.messageCount(forConversation: "cB"), count)
    }

    /// The offset survives the round trip into SQLite and back out on a hit.
    ///
    /// Without this the phone can find a moment and not be able to open it.
    func testSearchReturnsTheOffsetItIngested() throws {
        try index.ingest(
            [message("the rename path", offset: 8192)],
            for: ref(source("conv.jsonl"), projectPath: "/w/fd"), offset: nil
        )

        let hits = try index.search("\"rename\"*", projects: ["/w/fd"], limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].offset, 8192)
    }

    /// A project that has left the sidebar contributes nothing, rather than a hit the Mac
    /// could not honour without silently re-adding it. Asserted at the index, which is where
    /// the scoping actually happens — `FleetService` just passes `openProjectPaths()` through.
    func testSearchIsScopedToOpenProjects() throws {
        try index.ingest(
            [message("the rename path")], for: ref(source("c.jsonl"), projectPath: "/closed"),
            offset: nil
        )

        XCTAssertTrue(try index.search("\"rename\"*", projects: ["/open"], limit: 10).isEmpty)
        XCTAssertEqual(
            try index.search("\"rename\"*", projects: ["/closed"], limit: 10).count, 1
        )
    }

    /// A hit must carry enough to resume the RIGHT agent in the RIGHT directory. Before this,
    /// every hit was implicitly claude-in-the-project-root.
    func testSearchReturnsAgentProvenanceAndWorkingDirectory() throws {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/rollout.jsonl"),
            projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.codex"),
            workingDirectory: "/w/fd/.claude/worktrees/hunt",
            conversationID: "c1",
            agent: .codex,
            provenance: "exec",
            indexedName: nil,
            modified: Date(timeIntervalSince1970: 0)
        )
        try index.ingest(
            [IndexedMessage(
                conversationID: "c1", role: .user, text: "reticulating splines",
                timestamp: Date(timeIntervalSince1970: 10), offset: 0
            )],
            for: ref, offset: 99
        )

        let hits = try index.search("splines", projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].agent, "codex")
        XCTAssertEqual(hits[0].provenance, "exec")
        XCTAssertEqual(hits[0].workingDirectory, "/w/fd/.claude/worktrees/hunt")
        // The value `CodexAdapter.binding(for:)` reads to find the thread's rollout file.
        // Without it, pressing Return on this hit would start a fresh, empty thread instead
        // of resuming the one that was searched for.
        XCTAssertEqual(hits[0].transcriptPath, "/tmp/rollout.jsonl")
    }

    /// `FleetService.openConversation` holds only a conversation id, never a `TranscriptHit` —
    /// this is the lookup that gives it somewhere to resume a codex conversation into.
    func testTranscriptLocationReturnsTheWorkingDirectoryAndTranscriptPathForAKnownConversation() throws {
        try index.ingest(
            [message("reticulating splines", conversation: "c1")],
            for: ref(
                source("rollout.jsonl"), projectPath: "/w/fd", agent: .codex,
                workingDirectory: "/w/fd/.claude/worktrees/hunt"
            ),
            offset: 99
        )

        let location = try XCTUnwrap(index.transcriptLocation(forConversation: "c1"))
        XCTAssertEqual(location.workingDirectory, "/w/fd/.claude/worktrees/hunt")
        XCTAssertEqual(location.transcriptPath, source("rollout.jsonl").path)
        XCTAssertEqual(location.agent, "codex")
    }

    /// A conversation known only from live ingest (no offset to report — the normal case for
    /// a codex thread started since the last backfill) used to leave its source row unwritten
    /// until a backfill eventually reached the same file, so this lookup answered "unknown"
    /// for a conversation whose real directory and agent were known the moment it was ingested.
    /// `ingest` now writes source metadata in the same call as the message rows regardless of
    /// offset, so a live-ingest-only conversation resolves to its real values immediately.
    func testTranscriptLocationReturnsTheRealAgentAndDirectoryForALiveIngestOnlyConversation() throws {
        try index.ingest(
            [message("reticulating splines", conversation: "c1")],
            for: ref(
                source("rollout.jsonl"), projectPath: "/w/fd", agent: .codex,
                workingDirectory: "/w/fd/.claude/worktrees/hunt"
            ),
            offset: nil
        )

        let location = try XCTUnwrap(index.transcriptLocation(forConversation: "c1"))
        XCTAssertEqual(location.workingDirectory, "/w/fd/.claude/worktrees/hunt")
        XCTAssertEqual(location.transcriptPath, source("rollout.jsonl").path)
        XCTAssertEqual(location.agent, "codex")
    }

    /// `search()` hits the same source row `transcriptLocation` does, over the same LEFT
    /// JOIN — the other half of the fix above, proved the way the codex tab this bug actually
    /// affected would surface it: through search results, not the resume lookup.
    func testSearchReturnsTheRealAgentAndDirectoryForALiveIngestOnlyConversation() throws {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/rollout.jsonl"),
            projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.codex"),
            workingDirectory: "/w/fd/.claude/worktrees/hunt",
            conversationID: "c1",
            agent: .codex,
            provenance: nil,
            indexedName: nil,
            modified: Date(timeIntervalSince1970: 0)
        )
        try index.ingest(
            [IndexedMessage(
                conversationID: "c1", role: .user, text: "reticulating splines",
                timestamp: Date(timeIntervalSince1970: 10), offset: 0
            )],
            for: ref, offset: nil
        )

        let hits = try index.search("splines", projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].agent, "codex")
        XCTAssertEqual(hits[0].workingDirectory, "/w/fd/.claude/worktrees/hunt")
    }

    /// The nil-offset branch above must not disturb the offset-bearing path's own overwrite
    /// contract: a re-walk with changed provenance (a thread first seen live, later seen by
    /// the backfill as a stale `exec` run) still replaces the row wholesale, offset included —
    /// not merged column-by-column the way the nil-offset branch updates metadata in place.
    func testARewalkWithAnOffsetStillReplacesProvenanceAndOffsetTogether() throws {
        try index.ingest(
            [message("hi", conversation: "c1")],
            for: ref(source("a.jsonl"), projectPath: "/w/fd", provenance: nil), offset: nil
        )
        try index.ingest(
            [message("later", conversation: "c1")],
            for: ref(source("a.jsonl"), projectPath: "/w/fd", provenance: "exec"), offset: 4096
        )

        XCTAssertEqual(index.readOffset(for: source("a.jsonl")), 4096)
        let hits = try index.search("later", projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.first?.provenance, "exec")
    }

    /// Every other test that reaches the nil-offset `DO UPDATE` arm asserts only `offset` or
    /// only a hit count, never a metadata column by value — so a swapped column in that arm's
    /// `SET` list (`working_directory = excluded.agent`, say) would pass the whole suite. The
    /// ordinary live case this arm exists for is exactly this shape: a thread the backfill
    /// already indexed (an offset-bearing row already on disk) that is now streaming live
    /// (a nil-offset ingest arrives after it).
    func testLiveIngestOverABackfilledRowUpdatesMetadataWithoutDisturbingTheOffset() throws {
        try index.ingest(
            [message("hi", conversation: "c1")],
            for: ref(source("a.jsonl"), projectPath: "/w/fd", agent: .claude, workingDirectory: "/a"),
            offset: 4096
        )
        try index.ingest(
            [message("later", conversation: "c1")],
            for: ref(source("a.jsonl"), projectPath: "/w/fd", agent: .codex, workingDirectory: "/b"),
            offset: nil
        )

        let location = try XCTUnwrap(index.transcriptLocation(forConversation: "c1"))
        XCTAssertEqual(location.agent, "codex")
        XCTAssertEqual(location.workingDirectory, "/b")
        XCTAssertEqual(index.readOffset(for: source("a.jsonl")), 4096)
    }

    func testTranscriptLocationReturnsNilForAConversationWithNoMessages() throws {
        XCTAssertNil(try index.transcriptLocation(forConversation: "never-indexed"))
    }

    /// The divergence `FleetService.openConversation` has to avoid: a naming pass leaves the
    /// `conversation` table unwritten for a conversation it could not name (an
    /// `exec`-provenance codex rollout, say), but `source` — what this lookup reads — is
    /// written for every ingested message regardless of whether naming succeeded.
    func testTranscriptLocationReturnsTheCodexAgentForAConversationTheNamingPassNeverNamed() throws {
        try index.ingest(
            [message("reticulating splines", conversation: "c1")],
            for: ref(source("rollout.jsonl"), projectPath: "/w/fd", agent: .codex),
            offset: 99
        )

        let location = try XCTUnwrap(index.transcriptLocation(forConversation: "c1"))
        XCTAssertEqual(location.agent, "codex")
        XCTAssertTrue(
            try index.conversationNames().isEmpty,
            "sanity: this conversation really was never named"
        )
    }

    /// The v2 file on disk is discarded rather than migrated — the index is derived data and
    /// its whole migration story is "delete it and rebuild". Built as a REAL v2 file (an
    /// actual index, downgraded on disk afterward) rather than two fresh opens of the same
    /// path: two fresh opens exercise no v2 file at all and would pass even if the rebuild
    /// path were completely broken.
    func testOpeningAVersionTwoIndexRebuildsIt() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        var first: SQLiteSearchIndex? = try SQLiteSearchIndex(at: url)
        try first!.ingest(
            [message("rename")], for: ref(source("a.jsonl"), projectPath: "/w/fd"), offset: 1
        )
        XCTAssertEqual(try first!.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
        // Closed before the raw connection below opens the same file: WAL mode gives the two
        // connections separate views of it, and the raw one otherwise hits "disk I/O error"
        // trying to write through the still-open handle's memory-mapped WAL region.
        first = nil

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(db, "UPDATE meta SET value = '2' WHERE key = 'schema_version'", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(db)

        let reopened = try SQLiteSearchIndex(at: url)

        // The v2 rows are gone — the file was discarded and recreated, not migrated in place.
        XCTAssertEqual(try reopened.conversationNames().count, 0)
        XCTAssertEqual(
            try reopened.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 0
        )

        // And the recreated file is a real, usable v3 index, not merely an empty one.
        try reopened.ingest(
            [message("rebuilt")], for: ref(source("b.jsonl"), projectPath: "/w/fd"), offset: 1
        )
        XCTAssertEqual(
            try reopened.search(#""rebuilt"*"#, projects: ["/w/fd"], limit: 10).count, 1
        )
    }
}
