import FleetKit
import Foundation
import SQLite3

/// FTS5 over conversation text.
///
/// **Why SQLite rather than an index of our own.** `snippet()` returns exactly the
/// two-line, term-marked extract the overlay row is specified to show, `bm25()` ranks, and
/// prefix queries work — all of it battle-tested, all of it in the system library, no
/// dependency to vendor. The alternative was roughly six hundred lines of tokenizer,
/// postings list, prefix walk and snippet extraction, every one of them easy to get subtly
/// wrong and none of them this app's business.
///
/// **Why the file is disposable.** It is a cache of data that lives in `~/.claude/projects`,
/// never a source of truth. So the entire migration and corruption story is "delete it and
/// rebuild", which is what `schemaVersion` and the open path below implement. Anything that
/// made this file precious would be a design error.
///
/// This is the only file in the app that sees a `sqlite3*`.
final class SQLiteSearchIndex: SearchIndex {
    /// Bump on any schema change. A mismatch deletes the file — see `init`.
    static let schemaVersion = 3

    /// SQLite's own "copy this string, I may free it" sentinel. It is a `#define` casting
    /// -1 to a function pointer, which does not survive into Swift, so it is respelled here.
    /// Without it every bound string is treated as `STATIC` and SQLite reads freed memory.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    private var db: OpaquePointer?

    /// Serialises exactly the `BEGIN IMMEDIATE ... COMMIT` spans: the body of `ingest` and
    /// the delete loop in `prune`. Nothing else takes it — `setConversationName` writes
    /// outside it, and `prune`'s two `SELECT`s that build `doomed` run outside it too, so a
    /// concurrent `ingest` can change what they're computed against. Neither is a lock gap
    /// to close: `setConversationName` is a single autocommit statement SQLite already
    /// serialises internally, and a `doomed` set computed a moment stale just self-heals on
    /// the next `prune` pass. Widening the lock to cover them would be solving a problem
    /// that does not exist; if a future write here stops self-healing, it needs the lock too.
    ///
    /// Three writers reach this class now: `SearchIndexBuilder`, backfilling from its own
    /// actor, and `ClaudeRuntime` and `CodexRuntime`'s live `onMessages` hooks, both ingesting
    /// from the main actor as a session streams. `SQLITE_OPEN_FULLMUTEX` (see `open`) makes
    /// any *one* sqlite3 API call safe to issue from any of those threads, but `BEGIN
    /// IMMEDIATE ... COMMIT` below is many calls treated as one unit — without this lock, one
    /// writer's `BEGIN IMMEDIATE` landing while another's transaction is still open fails with
    /// "cannot start a transaction within a transaction", which the `try?` at every call site
    /// swallows. That is silent loss, not corruption: SQLite still has exactly one open
    /// transaction on the handle, belonging to whichever writer got there first, and the
    /// failed writer's entire batch — none of it, since the failure is at `BEGIN` itself,
    /// before any row is written — never lands. See
    /// `testConcurrentIngestsDoNotLoseEachOthersMessages`.
    private let transactionLock = NSLock()

    struct Failure: Error { let message: String }

    init(at url: URL) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Two attempts, deliberately. A file that is corrupt, truncated, or written by an
        // older schema is discarded and rebuilt rather than reported: the index holds
        // nothing that is not derivable from transcripts on disk, so losing it costs one
        // backfill and never costs data.
        if try (try? open(url)) == nil || !isCurrentSchema() {
            close()
            try? FileManager.default.removeItem(at: url)
            try open(url)
            try createSchema()
        }
    }

    deinit { close() }

    // MARK: - Ingest

    func ingest(_ messages: [IndexedMessage], for ref: TranscriptRef, offset: UInt64?) throws {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            // A restart from byte 0 means the transcript was replaced under the same path.
            // Its old rows describe a file that no longer exists, so they are dropped rather
            // than appended to — otherwise every message in the replacement is doubled. A
            // nil offset (live ingest) must NOT trigger this: it carries no read position at
            // all, so treating it as "0" would wipe out everything the backfill has indexed.
            if offset == .some(0) { try deleteRows(forSource: ref.url) }

            // OR IGNORE: backfill and live ingest can both cover the same appended bytes, and
            // `message_identity` (source, timestamp, text) is what makes that overlap a no-op
            // instead of a duplicate row.
            let insert = try prepare("""
                INSERT OR IGNORE INTO message(conversation_id, project_path, role, kind, timestamp, text, source, offset)
                VALUES (?, ?, ?, 'text', ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            let intoFTS = try prepare("INSERT INTO message_fts(rowid, text) VALUES (?, ?)")
            defer { sqlite3_finalize(intoFTS) }

            for message in messages {
                bind(insert, 1, message.conversationID)
                bind(insert, 2, ref.projectPath)
                bind(insert, 3, message.role.rawValue)
                sqlite3_bind_double(insert, 4, message.timestamp?.timeIntervalSince1970 ?? 0)
                bind(insert, 5, message.text)
                bind(insert, 6, ref.url.path)
                sqlite3_bind_int64(insert, 7, Int64(message.offset))
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
                let inserted = sqlite3_changes(db) > 0
                sqlite3_reset(insert)

                // `content='message'` makes the FTS table external-content: it stores no
                // text of its own and is NOT populated by the insert above. Keeping it in
                // step by hand — rather than by triggers — is what lets one prepared
                // statement pair serve the whole batch.
                //
                // Only mirror rows that were really inserted. `INSERT OR IGNORE` leaves
                // `last_insert_rowid()` pointing at the PREVIOUS successful insert when it
                // ignores one, so mirroring unconditionally would attach a second FTS row to
                // the preceding message and return that message twice for every matching
                // search.
                if inserted {
                    sqlite3_bind_int64(intoFTS, 1, sqlite3_last_insert_rowid(db))
                    bind(intoFTS, 2, message.text)
                    guard sqlite3_step(intoFTS) == SQLITE_DONE else { throw failure() }
                    sqlite3_reset(intoFTS)
                }
            }

            // Live ingest (nil offset) must not touch the read position — see the doc
            // comment on the protocol member for why recording it would silently skip a
            // conversation's entire backfilled history.
            //
            // `INSERT OR REPLACE`, not an `ON CONFLICT DO UPDATE`, because every column here
            // is written every time: a re-walk of a file whose codex provenance changed (or
            // whose agent binding otherwise moved) must overwrite the stale value rather than
            // leave it stuck at whatever the first ingest happened to see.
            if let offset {
                let source_ = try prepare(
                    "INSERT OR REPLACE INTO source(path, offset, agent, provenance, working_directory) "
                    + "VALUES (?, ?, ?, ?, ?)"
                )
                defer { sqlite3_finalize(source_) }
                bind(source_, 1, ref.url.path)
                sqlite3_bind_int64(source_, 2, Int64(offset))
                bind(source_, 3, ref.agent.rawValue)
                if let provenance = ref.provenance {
                    bind(source_, 4, provenance)
                } else {
                    sqlite3_bind_null(source_, 4)
                }
                bind(source_, 5, ref.workingDirectory)
                guard sqlite3_step(source_) == SQLITE_DONE else { throw failure() }
            } else {
                // A nil offset means "no read position to report", not "no metadata to
                // report" — `ref.agent`, `ref.provenance` and `ref.workingDirectory` are
                // known the moment a tab attaches, regardless of how far its watcher has
                // read. Leaving this row unwritten until a backfill eventually reaches the
                // same file is what let a conversation known only from live ingest — the
                // normal case for a codex thread started since the last backfill — answer
                // every `LEFT JOIN` against it with NULL, which both `search()` and
                // `transcriptLocation` default to "claude": the conversation the user just
                // had resumed as the wrong agent.
                //
                // `0` binds only into the row this INSERT creates; an existing row keeps
                // whatever `readOffset(for:)` already reports, because `ON CONFLICT DO
                // UPDATE` here names every column except `offset`. Writing 0 unconditionally
                // (an `INSERT OR REPLACE`, say) would reset a backfilled file's read position
                // and send the next pass back to reading it from the top.
                //
                // The columns this DOES name are overwritten every time, on an existing row
                // as much as a new one — deliberately, not just as a side effect of reusing
                // one statement for both. This reaches every shipped agent, not only codex: a
                // session the backfill already indexed, now streaming live, has its
                // `working_directory` overwritten on every batch, because the live tab's own
                // value is a first-hand answer to "where is this conversation right now" and
                // the backfill's is not — a session moved into a worktree since the last walk
                // should read as being there, not where it used to be. The same overwrite
                // nulls `provenance` for a codex thread the backfill had recorded as `exec`:
                // once it is a live `codex resume` TUI, `exec` is no longer true, and this
                // runtime's own `ingest` call (see `CodexRuntime.attach`) never claims
                // otherwise.
                let source_ = try prepare("""
                    INSERT INTO source(path, offset, agent, provenance, working_directory)
                    VALUES (?, 0, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                      agent = excluded.agent, provenance = excluded.provenance,
                      working_directory = excluded.working_directory
                    """)
                defer { sqlite3_finalize(source_) }
                bind(source_, 1, ref.url.path)
                bind(source_, 2, ref.agent.rawValue)
                if let provenance = ref.provenance {
                    bind(source_, 3, provenance)
                } else {
                    sqlite3_bind_null(source_, 3)
                }
                bind(source_, 4, ref.workingDirectory)
                guard sqlite3_step(source_) == SQLITE_DONE else { throw failure() }
            }

            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func readOffset(for source: URL) -> UInt64 {
        guard let statement = try? prepare("SELECT offset FROM source WHERE path = ?") else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return UInt64(max(0, sqlite3_column_int64(statement, 0)))
    }

    // MARK: - Query

    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit] {
        guard !projects.isEmpty else { return [] }

        // The project filter is in SQL rather than applied to the results afterwards. Doing
        // it after LIMIT would let a project that has left the sidebar consume slots in the
        // 200 and silently shrink what the user sees.
        let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ", ")
        let statement = try prepare("""
            SELECT m.id, m.conversation_id, m.project_path, m.timestamp, m.offset, m.source,
                   snippet(message_fts, 0, char(2), char(3), '…', 24),
                   s.agent, s.provenance, s.working_directory
            FROM message_fts
            JOIN message m ON m.id = message_fts.rowid
            -- LEFT JOIN, not JOIN: `ingest` now writes a source row's metadata in the same
            -- commit as every message row it inserts, offset-bearing or not (see its
            -- offset-less branch), so this protects only an index written before that was
            -- true — a message row that really did outlive its source row. An inner join
            -- would make such an old row's hits vanish outright instead of falling back to
            -- the NULL defaults below.
            LEFT JOIN source s ON s.path = m.source
            WHERE message_fts MATCH ? AND m.project_path IN (\(placeholders))
            ORDER BY bm25(message_fts)
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, query)
        for (offset, project) in projects.enumerated() {
            bind(statement, Int32(2 + offset), project)
        }
        sqlite3_bind_int(statement, Int32(2 + projects.count), Int32(limit))

        let names = try conversationNames()
        var hits: [TranscriptHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let conversation = text(statement, 1)
            hits.append(TranscriptHit(
                rowID: sqlite3_column_int64(statement, 0),
                conversationID: conversation,
                projectPath: text(statement, 2),
                // Falls back to the conversation id's leading segment, which is what the
                // sidebar shows for an unnamed conversation too.
                conversationName: names[conversation]?.name ?? String(conversation.prefix(8)),
                snippet: text(statement, 6),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                offset: Int(sqlite3_column_int64(statement, 4)),
                // Defaults to "claude" when NULL: `ingest` now writes a source row alongside
                // every message row it inserts (see the LEFT JOIN above), so NULL here means
                // only a row written before that was true, and every one of those really was
                // claude.
                agent: optionalText(statement, 7) ?? "claude",
                provenance: optionalText(statement, 8),
                workingDirectory: text(statement, 9),
                // `m.source`, not `s.path`: `s.path` comes through the LEFT JOIN and is NULL
                // whenever a hit's source row is missing (see that LEFT JOIN's own comment),
                // which would make `CodexAdapter.resumeCommand` treat the hit as having no
                // transcript and start a fresh, empty thread instead of resuming the one that
                // was searched for. `m.source` is on the inner-joined row and is never NULL.
                transcriptPath: text(statement, 5)
            ))
        }
        return hits
    }

    func conversationNames() throws -> [String: IndexedConversation] {
        let statement = try prepare(
            "SELECT conversation_id, name, project_path, agent FROM conversation"
        )
        defer { sqlite3_finalize(statement) }
        var names: [String: IndexedConversation] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            names[text(statement, 0)] = IndexedConversation(
                name: text(statement, 1), projectPath: text(statement, 2), agent: text(statement, 3)
            )
        }
        return names
    }

    func setConversationName(
        _ name: String, projectPath: String, agent: String, for id: String
    ) throws {
        let statement = try prepare(
            "INSERT INTO conversation(conversation_id, name, project_path, agent) VALUES (?, ?, ?, ?) "
            + "ON CONFLICT(conversation_id) DO UPDATE SET "
            + "name = excluded.name, project_path = excluded.project_path, agent = excluded.agent"
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        bind(statement, 2, name)
        bind(statement, 3, projectPath)
        bind(statement, 4, agent)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func messageCount(forConversation id: String) throws -> Int {
        let statement = try prepare("SELECT count(*) FROM message WHERE conversation_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func transcriptLocation(
        forConversation id: String
    ) throws -> (workingDirectory: String, transcriptPath: String, agent: String)? {
        // LEFT JOIN, not JOIN: `s.working_directory` and `s.agent` may still be missing for a
        // message written before `ingest` grew its offset-less metadata write (see `search`'s
        // own LEFT JOIN above), and an absent one means "unknown" here rather than "no such
        // conversation" — `m.source` alone is enough to answer that. `LIMIT 1` rests on how
        // the corpus walk writes rows, not on a schema constraint: every message a given
        // ingest pass files carries the source path it was read from, so one conversation
        // never straddles two sources in practice, and the first row is the whole answer.
        let statement = try prepare("""
            SELECT m.source, s.working_directory, s.agent
            FROM message m
            LEFT JOIN source s ON s.path = m.source
            WHERE m.conversation_id = ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (
            workingDirectory: text(statement, 1),
            transcriptPath: text(statement, 0),
            // Same NULL default `search` applies to this column, and for the same reason: a
            // message row can outlive its `source` row being written, and every source
            // predating this column really was claude.
            agent: optionalText(statement, 2) ?? "claude"
        )
    }

    // MARK: - Prune

    func prune(keepingSources: Set<URL>, projects: Set<String>) throws {
        let statement = try prepare("SELECT DISTINCT source, project_path FROM message")
        var doomed: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = text(statement, 0)
            let project = text(statement, 1)
            if !keepingSources.contains(URL(fileURLWithPath: path)) || !projects.contains(project) {
                doomed.insert(path)
            }
        }
        sqlite3_finalize(statement)

        // Also sweep `source` rows whose file is gone but which contributed no messages —
        // an empty or all-tool transcript. Left behind, they would make the builder skip a
        // file it has never actually indexed if the path were ever reused.
        let orphans = try prepare("SELECT path FROM source")
        while sqlite3_step(orphans) == SQLITE_ROW {
            let path = text(orphans, 0)
            if !keepingSources.contains(URL(fileURLWithPath: path)) { doomed.insert(path) }
        }
        sqlite3_finalize(orphans)

        guard !doomed.isEmpty else { return }
        transactionLock.lock()
        defer { transactionLock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            for path in doomed { try deleteRows(forSource: URL(fileURLWithPath: path)) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Deletes a source's messages, its FTS rows, and its read position.
    ///
    /// The FTS rows go first and by rowid: `message_fts` is external-content, so deleting
    /// from `message` alone leaves the index pointing at rows that no longer exist and
    /// `snippet()` starts returning empty strings for surviving matches.
    private func deleteRows(forSource source: URL) throws {
        let statement = try prepare("""
            DELETE FROM message_fts
            WHERE rowid IN (SELECT id FROM message WHERE source = ?)
            """)
        bind(statement, 1, source.path)
        guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw failure() }
        sqlite3_finalize(statement)

        for sql in ["DELETE FROM message WHERE source = ?", "DELETE FROM source WHERE path = ?"] {
            let statement = try prepare(sql)
            bind(statement, 1, source.path)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement); throw failure()
            }
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Connection

    private func open(_ url: URL) throws {
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else { throw failure() }
        // WAL so a backfill writing on a background task cannot block the overlay's read.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
    }

    private func close() {
        // `_v2`: a plain `sqlite3_close` fails outright on SQLITE_BUSY (an outstanding
        // finalized-but-not-yet-reclaimed statement), which would leak the handle here and
        // leave the file locked while `init` goes on to delete and reopen it. `_v2` instead
        // defers the actual close until every statement finalizes, and always succeeds from
        // the caller's point of view — so `db` is always safe to nil out immediately after.
        if db != nil { sqlite3_close_v2(db); db = nil }
    }

    private func isCurrentSchema() throws -> Bool {
        guard let statement = try? prepare("SELECT value FROM meta WHERE key = 'schema_version'")
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return Int(text(statement, 0)) == Self.schemaVersion
    }

    private func createSchema() throws {
        try exec("""
            CREATE TABLE message(
              id INTEGER PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              project_path TEXT NOT NULL,
              role TEXT NOT NULL,
              kind TEXT NOT NULL,
              timestamp REAL NOT NULL,
              text TEXT NOT NULL,
              source TEXT NOT NULL,
              offset INTEGER NOT NULL
            );
            CREATE INDEX message_by_source ON message(source);
            CREATE INDEX message_by_conversation ON message(conversation_id);
            -- Makes double-ingest a no-op rather than a duplicate row: backfill and live
            -- ingest can both cover the same appended bytes (see the `ingest` doc comment),
            -- and this is what makes that overlap harmless instead of double-counting every
            -- message in it.
            CREATE UNIQUE INDEX message_identity ON message(source, timestamp, text);
            CREATE VIRTUAL TABLE message_fts USING fts5(
              text, content='message', content_rowid='id', tokenize='unicode61'
            );
            -- agent/provenance/working_directory live HERE rather than on `message`: a
            -- transcript file has exactly one of each, so this is where they normalise.
            -- Repeating them per message would cost three columns across hundreds of
            -- thousands of rows to answer a question that is per-file.
            CREATE TABLE source(
              path TEXT PRIMARY KEY,
              offset INTEGER NOT NULL,
              agent TEXT NOT NULL,
              provenance TEXT,
              working_directory TEXT NOT NULL
            );
            CREATE TABLE conversation(
              conversation_id TEXT PRIMARY KEY, name TEXT NOT NULL,
              project_path TEXT NOT NULL, agent TEXT NOT NULL
            );
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO meta(key, value) VALUES ('schema_version', '\(Self.schemaVersion)');
            """)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ column: Int32, _ value: String) {
        sqlite3_bind_text(statement, column, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }

    /// Distinguishes NULL from an empty string, unlike `text(_:_:)` — needed for
    /// `provenance`, where "no provenance recorded" and "recorded as empty" are different
    /// facts, and for `agent`, whose NULL/non-NULL split decides whether the "claude" default
    /// applies.
    private func optionalText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private func failure() -> Failure {
        Failure(message: String(cString: sqlite3_errmsg(db)))
    }
}
