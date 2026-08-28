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
    static let schemaVersion = 1

    /// SQLite's own "copy this string, I may free it" sentinel. It is a `#define` casting
    /// -1 to a function pointer, which does not survive into Swift, so it is respelled here.
    /// Without it every bound string is treated as `STATIC` and SQLite reads freed memory.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    private var db: OpaquePointer?

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

    func ingest(
        _ messages: [IndexedMessage], from source: URL, projectPath: String, offset: UInt64?
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            // A restart from byte 0 means the transcript was replaced under the same path.
            // Its old rows describe a file that no longer exists, so they are dropped rather
            // than appended to — otherwise every message in the replacement is doubled. A
            // nil offset (live ingest) must NOT trigger this: it carries no read position at
            // all, so treating it as "0" would wipe out everything the backfill has indexed.
            if offset == .some(0) { try deleteRows(forSource: source) }

            // OR IGNORE: backfill and live ingest can both cover the same appended bytes, and
            // `message_identity` (source, timestamp, text) is what makes that overlap a no-op
            // instead of a duplicate row.
            let insert = try prepare("""
                INSERT OR IGNORE INTO message(conversation_id, project_path, role, kind, timestamp, text, source)
                VALUES (?, ?, ?, 'text', ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            let intoFTS = try prepare("INSERT INTO message_fts(rowid, text) VALUES (?, ?)")
            defer { sqlite3_finalize(intoFTS) }

            for message in messages {
                bind(insert, 1, message.conversationID)
                bind(insert, 2, projectPath)
                bind(insert, 3, message.role.rawValue)
                sqlite3_bind_double(insert, 4, message.timestamp?.timeIntervalSince1970 ?? 0)
                bind(insert, 5, message.text)
                bind(insert, 6, source.path)
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
            if let offset {
                let source_ = try prepare(
                    "INSERT INTO source(path, offset) VALUES (?, ?) "
                    + "ON CONFLICT(path) DO UPDATE SET offset = excluded.offset"
                )
                defer { sqlite3_finalize(source_) }
                bind(source_, 1, source.path)
                sqlite3_bind_int64(source_, 2, Int64(offset))
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
            SELECT m.conversation_id, m.project_path, m.timestamp,
                   snippet(message_fts, 0, char(2), char(3), '…', 24)
            FROM message_fts
            JOIN message m ON m.id = message_fts.rowid
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
            let conversation = text(statement, 0)
            hits.append(TranscriptHit(
                conversationID: conversation,
                projectPath: text(statement, 1),
                // Falls back to the conversation id's leading segment, which is what the
                // sidebar shows for an unnamed conversation too.
                conversationName: names[conversation]?.name ?? String(conversation.prefix(8)),
                snippet: text(statement, 3),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return hits
    }

    func conversationNames() throws -> [String: IndexedConversation] {
        let statement = try prepare("SELECT conversation_id, name, project_path FROM conversation")
        defer { sqlite3_finalize(statement) }
        var names: [String: IndexedConversation] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            names[text(statement, 0)] = IndexedConversation(
                name: text(statement, 1), projectPath: text(statement, 2)
            )
        }
        return names
    }

    func setConversationName(_ name: String, projectPath: String, for id: String) throws {
        let statement = try prepare(
            "INSERT INTO conversation(conversation_id, name, project_path) VALUES (?, ?, ?) "
            + "ON CONFLICT(conversation_id) DO UPDATE SET "
            + "name = excluded.name, project_path = excluded.project_path"
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        bind(statement, 2, name)
        bind(statement, 3, projectPath)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func messageCount(forConversation id: String) throws -> Int {
        let statement = try prepare("SELECT count(*) FROM message WHERE conversation_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
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
        if db != nil { sqlite3_close(db); db = nil }
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
              source TEXT NOT NULL
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
            CREATE TABLE source(path TEXT PRIMARY KEY, offset INTEGER NOT NULL);
            CREATE TABLE conversation(
              conversation_id TEXT PRIMARY KEY, name TEXT NOT NULL, project_path TEXT NOT NULL
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

    private func failure() -> Failure {
        Failure(message: String(cString: sqlite3_errmsg(db)))
    }
}
