import CryptoKit
import Foundation
import IntakeKit
import SQLite3

/// **OpenCode's history, as the append-only JSONL file every transcript reader in this app
/// already understands.**
///
/// OpenCode keeps nothing on disk that looks like a transcript: messages and their parts are
/// rows in one SQLite database per account (`message`, `part`), updated in place while they
/// stream. Everything in Flight Deck that reads history — `TimelineReader`'s byte-offset pager,
/// ⌘K's backfill, `PromptService`'s tail read — reads lines from a file. Rather than give each
/// of them a second, database-shaped code path, this keeps one derived file per session and
/// the readers stay agent-agnostic.
///
/// **Append-only is the invariant, and it is what the two rules below buy.** The pager hands
/// phones byte offsets, and the search index records them; a file whose prefix changed would
/// make every stored offset point into a different record.
///
/// 1. *Only the longest SETTLED prefix of messages is ever written.* An assistant message is
///    settled when OpenCode has stamped `time.completed` or an error on it. A USER message is
///    settled once a later message exists — not when it exists itself, because OpenCode writes
///    the message row before its parts: a live run mirrored the session's first prompt with
///    `"parts":[]`, and append-only meant it stayed empty forever. OpenCode creates the reply
///    the moment it starts on a prompt, so the wait is the model's first step. A message that is
///    not settled stops the walk, and nothing after it is written until it settles — so a
///    message can never be inserted ahead of one already in the file. The cost is latency (a
///    step's text appears when the step finishes, not token by token); claude's transcript has
///    the same per-record granularity.
///    An assistant step that never completed (its server was killed) is settled by the next
///    step's existence, so one interruption cannot freeze the mirror.
/// 2. *Existing lines are never rewritten.* A sync appends the settled messages whose ids are
///    not in the file yet. A message OpenCode later deletes (an undo/revert) stays in the
///    mirror; that is a stale line, not a moved offset.
///
/// **Permission and question requests are logged here too, as `prompt.asked` /
/// `prompt.resolved` records.** OpenCode does not persist them at all — a pending request
/// lives only in the server's memory (live-probed: restarting the server dropped one) — but
/// both the phone and the Mac derive "what is this tab blocked on" from transcript records
/// (`OpenPrompt.find`), keyed by call id. Writing the request's own id as that call id is what
/// lets the existing derivation, card, and answer token work unchanged.
///
/// Every writer takes an exclusive `flock` on the file, because there are two of them: the
/// runtime (on events) and the search corpus (on backfill, off the main actor).
enum OpenCodeMirror {
    // MARK: - Locations

    /// Where an account's mirrors live, keyed by its database path rather than by a Flight Deck
    /// account id: the search corpus reaches this with nothing but an `AgentAccount.home`, and
    /// the database path is the one thing both sides derive identically.
    static func directory(forDatabase database: URL, root: URL = defaultRoot) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(database.standardizedFileURL.path.utf8))
        let key = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }

    static func url(forSession sessionID: String, database: URL, root: URL = defaultRoot) -> URL {
        directory(forDatabase: database, root: root)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    static var defaultRoot: URL {
        FileSessionPersistence.defaultDirectory()
            .appendingPathComponent("OpenCode", isDirectory: true)
            .appendingPathComponent("mirror", isDirectory: true)
    }

    /// The account's database, found without running `opencode`: the corpus runs off the main
    /// actor during a backfill and must not spawn a process per account to ask. OpenCode names
    /// the file after its release channel — `opencode.db` on `latest`/`beta`/`prod`, else
    /// `opencode-<channel>.db` (read out of 1.18.34's own `Database` layer) — so the stable name
    /// wins when present, and otherwise the most recently written channel database does.
    static func databaseURL(home: URL) -> URL? {
        let dataDirectory = home.appendingPathComponent("opencode", isDirectory: true)
        let stable = dataDirectory.appendingPathComponent("opencode.db")
        if FileManager.default.fileExists(atPath: stable.path) { return stable }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("opencode-") && $0.hasSuffix(".db") }
            .map { dataDirectory.appendingPathComponent($0) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    // MARK: - Writing

    /// Appends every settled message of `sessionID` that the mirror does not have yet, and
    /// returns the lines it appended (for live search indexing).
    @discardableResult
    static func sync(sessionID: String, database: URL, mirror: URL) throws -> [String] {
        let messages = try OpenCodeDatabase(url: database).settledMessages(session: sessionID)
        return try withLockedFile(mirror) { handle, existing in
            let written = writtenMessageIDs(in: existing)
            let fresh = messages.filter { !written.contains($0.id) }.map(\.line)
            guard !fresh.isEmpty else { return [] }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((fresh.joined(separator: "\n") + "\n").utf8))
            return fresh
        }
    }

    /// Appends one already-encoded record — a `prompt.asked` or `prompt.resolved` line.
    static func append(_ line: String, to mirror: URL) throws {
        _ = try withLockedFile(mirror) { handle, _ in
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            return [String]()
        }
    }

    private static func withLockedFile(
        _ url: URL, _ body: (FileHandle, Data) throws -> [String]
    ) throws -> [String] {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            throw OpenCodeError.malformed("could not lock \(url.lastPathComponent)")
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        let existing = try handle.readToEnd() ?? Data()
        return try body(handle, existing)
    }

    /// Message ids already in a mirror. Every message line is written by `messageLine`, which
    /// puts `"id"` right after `"type":"message"` — but this parses rather than pattern-matches,
    /// so a hand-edited or older file degrades to "rewrite nothing that parses".
    static func writtenMessageIDs(in data: Data) -> Set<String> {
        var ids: Set<String> = []
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "message", let id = object["id"] as? String
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    // MARK: - Line encoding

    /// Bytes of a tool's output kept in the mirror. The timeline caps what a phone receives on
    /// its own (`TimelineLimits`), so this only bounds the FILE: one `cat` of a lockfile would
    /// otherwise make the mirror carry megabytes nobody can ever page to.
    static let toolOutputLimit = 16 * 1024

    static func messageLine(id: String, info: [String: Any], parts: [[String: Any]]) -> String {
        var record: [String: Any] = ["type": "message", "id": id]
        record["role"] = info["role"] as? String ?? "assistant"
        if let time = info["time"] as? [String: Any] {
            if let created = time["created"] { record["time"] = created }
            if let completed = time["completed"] { record["completed"] = completed }
        }
        if let error = info["error"] { record["error"] = error }
        if let agent = info["agent"] as? String { record["agent"] = agent }
        if let model = info["modelID"] as? String {
            record["model"] = [info["providerID"] as? String, model].compactMap { $0 }.joined(separator: "/")
        }
        record["parts"] = parts.compactMap(trimmed(part:))
        return OpenCodeEventMapper.encode(record)
    }

    /// What of a part the mirror keeps. Step markers, snapshots and compaction bookkeeping carry
    /// nothing a reader shows; a file part's `url` is dropped because it is routinely a `data:`
    /// URL holding the whole attachment.
    static func trimmed(part: [String: Any]) -> [String: Any]? {
        guard let type = part["type"] as? String else { return nil }
        switch type {
        case "text", "reasoning":
            guard let text = part["text"] as? String, !text.isEmpty else { return nil }
            var out: [String: Any] = ["type": type, "text": text]
            if part["synthetic"] as? Bool == true { out["synthetic"] = true }
            return out
        case "tool":
            var out: [String: Any] = ["type": "tool"]
            out["tool"] = part["tool"] as? String ?? "tool"
            if let callID = part["callID"] { out["callID"] = callID }
            if var state = part["state"] as? [String: Any] {
                state["metadata"] = nil
                state["attachments"] = nil
                if let output = state["output"] as? String, output.utf8.count > toolOutputLimit {
                    state["output"] = String(decoding: output.utf8.prefix(toolOutputLimit), as: UTF8.self)
                    state["truncated"] = output.utf8.count - toolOutputLimit
                }
                out["state"] = state
            }
            return out
        case "file":
            var out: [String: Any] = ["type": "file"]
            if let name = part["filename"] { out["filename"] = name }
            if let mime = part["mime"] { out["mime"] = mime }
            return out
        case "patch":
            return ["type": "patch", "files": part["files"] as? [String] ?? []]
        case "subtask", "agent":
            var out = part
            out["id"] = nil; out["messageID"] = nil; out["sessionID"] = nil
            return out
        default:
            return nil
        }
    }
}

/// Read-only access to one account's `opencode.db`.
///
/// Read-only and short-lived on purpose: OpenCode holds the database in WAL mode with a 5 s
/// busy timeout (read out of its own `PRAGMA`s), so a reader that held a transaction open would
/// stall the server's writes. Every call opens, reads and closes.
struct OpenCodeDatabase {
    let url: URL

    struct Message: Equatable {
        let id: String
        let line: String
    }

    struct SessionRow: Equatable {
        let id: String
        let directory: String
        let title: String
        let parentID: String?
        let updated: Date
    }

    func settledMessages(session: String) throws -> [Message] {
        try withDatabase { db in
            // One read transaction around both queries. In WAL mode each statement otherwise
            // reads its own snapshot, so a message could be judged settled by the second query
            // while its parts were read, by the first, from before they existed — and the
            // mirror is append-only, so that empty line would stay.
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
                throw OpenCodeError.malformed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
            var partsByMessage: [String: [[String: Any]]] = [:]
            try query(db, "SELECT message_id, data FROM part WHERE session_id = ? ORDER BY message_id, id",
                      [session]) { row in
                guard let messageID = row.text(0),
                      let part = row.json(1) else { return }
                partsByMessage[messageID, default: []].append(part)
            }
            var rows: [(id: String, info: [String: Any])] = []
            try query(db, "SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id",
                      [session]) { row in
                guard let id = row.text(0), let info = row.json(1) else { return }
                rows.append((id, info))
            }
            var messages: [Message] = []
            for (index, row) in rows.enumerated() {
                let later = rows[(index + 1)...]
                let laterAssistant = later.contains { $0.info["role"] as? String == "assistant" }
                guard Self.isSettled(row.info, isLast: later.isEmpty, hasLaterAssistant: laterAssistant)
                else { break }
                messages.append(Message(
                    id: row.id,
                    line: OpenCodeMirror.messageLine(id: row.id, info: row.info, parts: partsByMessage[row.id] ?? [])
                ))
            }
            return messages
        }
    }

    /// See `OpenCodeMirror`'s rule 1 for why a user message waits for its successor.
    ///
    /// An assistant message that never got its completion stamp — its server was killed
    /// mid-step — is settled once a LATER assistant message exists: OpenCode runs a session's
    /// steps one at a time, so a newer step means this one is over. Without that, one
    /// interrupted step would stop the walk, and the mirror, for good.
    static func isSettled(_ info: [String: Any], isLast: Bool, hasLaterAssistant: Bool = false) -> Bool {
        if info["role"] as? String == "user" { return !isLast }
        if info["error"] != nil || hasLaterAssistant { return true }
        return (info["time"] as? [String: Any])?["completed"] != nil
    }

    /// Top-level sessions only: a subagent's child session is part of its parent's turn, not a
    /// conversation anyone would search for and resume on its own.
    func topLevelSessions() throws -> [SessionRow] {
        try withDatabase { db in
            var rows: [SessionRow] = []
            try query(db, "SELECT id, directory, title, parent_id, time_updated FROM session "
                      + "WHERE parent_id IS NULL AND time_archived IS NULL", []) { row in
                guard let id = row.text(0), let directory = row.text(1) else { return }
                rows.append(SessionRow(
                    id: id, directory: directory, title: row.text(2) ?? "",
                    parentID: row.text(3),
                    updated: Date(timeIntervalSince1970: Double(row.int(4)) / 1000)
                ))
            }
            return rows
        }
    }

    func session(_ id: String) throws -> SessionRow? {
        try withDatabase { db in
            var found: SessionRow?
            try query(db, "SELECT id, directory, title, parent_id, time_updated FROM session WHERE id = ?",
                      [id]) { row in
                guard let id = row.text(0), let directory = row.text(1) else { return }
                found = SessionRow(
                    id: id, directory: directory, title: row.text(2) ?? "",
                    parentID: row.text(3),
                    updated: Date(timeIntervalSince1970: Double(row.int(4)) / 1000)
                )
            }
            return found
        }
    }

    // MARK: - SQLite plumbing

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: raw)
        }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func json(_ column: Int32) -> [String: Any]? {
            guard let text = text(column) else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw OpenCodeError.unreachable("cannot open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    private func query(
        _ db: OpaquePointer, _ sql: String, _ arguments: [String], _ each: (Row) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OpenCodeError.malformed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { each(Row(statement: statement)); continue }
            if step == SQLITE_DONE { return }
            throw OpenCodeError.malformed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
