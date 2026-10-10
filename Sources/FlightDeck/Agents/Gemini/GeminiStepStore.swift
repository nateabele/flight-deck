import Foundation
import SQLite3

/// Read-only access to agy's two SQLite stores: a conversation's step store
/// (`conversations/<id>.db`) and the cross-conversation index (`conversation_summaries.db`).
///
/// **Why SQLite at all, when there is a JSONL transcript.** A step that is WAITING on the user's
/// approval, or that was CANCELED, never reaches `transcript_full.jsonl` — agy writes a step to
/// the JSONL only when it reaches a terminal state (agy-tui-facts §2). So "which dialog is open"
/// exists in the step store and nowhere else on disk. And "is a turn running" is in the summaries
/// index (`status`), which agy updates live: `RUNNING` within ~0.4 s of a submit and `IDLE` when
/// the turn ends or is denied (watched at 4 Hz on 2026-10-08).
///
/// **Read-only, always.** Every open is `file:<path>?mode=ro` with `SQLITE_OPEN_READONLY`, so
/// Flight Deck can never write agy's database. A read-only open of a LIVE agy store worked on
/// 2026-10-08 (agy 1.3.1, a WAITING step read while the dialog was on screen). The 2026-10-07
/// probe once saw `SQLITE_CANTOPEN` instead; when that happens every query here answers nil,
/// which reads as "nothing open" / "status unknown" — the refusal direction.
enum GeminiSQLite {
    /// Runs `sql` against `url` read-only and maps every row. nil when the file cannot be opened
    /// or the statement cannot be prepared.
    static func query<T>(_ url: URL, _ sql: String, row: (OpaquePointer) -> T?) -> [T]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        // agy holds a writer on the live store; a reader that hit its lock should wait briefly
        // rather than report "nothing open" on a dialog that is plainly up.
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = row(statement) { rows.append(value) }
        }
        return rows
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let raw = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// A tool call agy is holding for the user's approval.
struct GeminiPendingCall: Equatable, Sendable {
    /// agy's own call id (`call_214537`): stable for the life of the step, so a phone's tap can
    /// be checked against the dialog it was looking at.
    let callID: String
    let tool: String
    /// The call's arguments, as agy wrote them (a JSON object).
    let argumentsJSON: String
    let stepIndex: Int
}

enum GeminiStepStore {
    /// `CORTEX_STEP_STATUS_WAITING` as stored. Observed directly, twice: the 2026-10-07 probe's
    /// pending `write_to_file` and the 2026-10-08 smoke's (`2:132:9` while the dialog was up,
    /// `2:132:7` after the deny). The enum's names are in the binary but their numbers are not
    /// in name order (DONE is 3), so only the observed number is trusted.
    static let waitingStatus: Int32 = 9

    /// The newest step waiting on the user, or nil — including when the store cannot be read.
    static func pendingCall(in store: URL) -> GeminiPendingCall? {
        let rows = GeminiSQLite.query(
            store, "SELECT idx, step_payload FROM steps WHERE status = \(waitingStatus) ORDER BY idx DESC LIMIT 1"
        ) { statement -> GeminiPendingCall? in
            let index = Int(sqlite3_column_int64(statement, 0))
            guard let payload = GeminiSQLite.blob(statement, 1) else { return nil }
            return decodeCall(payload, stepIndex: index)
        }
        return rows?.first
    }

    /// The tool call inside a step payload: top-level field 5, then its field 4, which carries
    /// `1: call id`, `2: tool name`, `3: arguments JSON` (decoded with `protoc --decode_raw`
    /// from agy 1.3.1 stores; no schema ships with agy). A payload that does not have that
    /// shape is not a call this build can name, so it answers nil rather than a guess.
    static func decodeCall(_ payload: Data, stepIndex: Int) -> GeminiPendingCall? {
        guard let step = ProtoWire.message(payload, field: 5),
              let call = ProtoWire.message(step, field: 4),
              let id = ProtoWire.string(call, field: 1), !id.isEmpty,
              let tool = ProtoWire.string(call, field: 2), !tool.isEmpty
        else { return nil }
        return GeminiPendingCall(callID: id, tool: tool,
                                 argumentsJSON: ProtoWire.string(call, field: 3) ?? "{}",
                                 stepIndex: stepIndex)
    }
}

/// One row of `conversation_summaries`, trimmed to what Flight Deck reads.
struct GeminiSummary: Equatable, Sendable {
    let conversationID: UUID
    let title: String
    let workspaces: [String]
    /// `CASCADE_RUN_STATUS_IDLE` / `_RUNNING` / `_BUSY` / `_CANCELING`, verbatim.
    let status: String
    let modified: Date?

    /// RUNNING and BUSY both mean a turn is in flight; CANCELING is a turn on its way out after
    /// an Esc, still not a composer anyone should type into as if idle.
    var isRunning: Bool {
        ["CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING"].contains(status)
    }
}

enum GeminiSummaries {
    static func all(in db: URL) -> [GeminiSummary]? {
        GeminiSQLite.query(db, "SELECT conversation_id, title, workspace_uris, status, last_modified_time FROM conversation_summaries") {
            row($0)
        }
    }

    static func summary(_ id: UUID, in db: URL) -> GeminiSummary? {
        GeminiSQLite.query(db, "SELECT conversation_id, title, workspace_uris, status, last_modified_time FROM conversation_summaries WHERE conversation_id = '\(GeminiPaths.name(id))'") {
            row($0)
        }?.first
    }

    private static func row(_ statement: OpaquePointer) -> GeminiSummary? {
        guard let raw = GeminiSQLite.text(statement, 0), let id = UUID(uuidString: raw) else { return nil }
        return GeminiSummary(
            conversationID: id,
            title: GeminiSQLite.text(statement, 1) ?? "",
            workspaces: workspacePaths(GeminiSQLite.text(statement, 2) ?? "[]"),
            status: GeminiSQLite.text(statement, 3) ?? "",
            modified: GeminiSQLite.text(statement, 4).flatMap(parseTime)
        )
    }

    /// `workspace_uris` is a JSON array of `file://` URIs (`["file:///Users/x/repo"]`).
    static func workspacePaths(_ json: String) -> [String] {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String] else { return [] }
        return array.compactMap { URL(string: $0)?.path }.filter { !$0.isEmpty }
    }

    /// `2026-10-07 22:37:33.685173+00:00`, as Go's database/sql writes a time.
    static func parseTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd HH:mm:ssxxx"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Just enough of the protobuf wire format to walk agy's step payloads: varints, and
/// length-delimited fields read by number. Fixed-width fields are skipped by size.
enum ProtoWire {
    /// The first length-delimited field `field` at this level, or nil.
    static func message(_ data: Data, field: Int) -> Data? {
        var found: Data?
        walk(data) { number, wireType, value in
            if number == field, wireType == 2, found == nil { found = value }
        }
        return found
    }

    static func string(_ data: Data, field: Int) -> String? {
        message(data, field: field).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Calls `visit` for each field at this level. Stops quietly at the first malformed field —
    /// a torn read of a live store must not trap.
    static func walk(_ data: Data, _ visit: (Int, Int, Data?) -> Void) {
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let byte = bytes[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return }
            let number = Int(key >> 3), wireType = Int(key & 7)
            switch wireType {
            case 0: guard varint() != nil else { return }; visit(number, 0, nil)
            case 1: guard i + 8 <= bytes.count else { return }; i += 8; visit(number, 1, nil)
            case 5: guard i + 4 <= bytes.count else { return }; i += 4; visit(number, 5, nil)
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - i) else { return }
                let end = i + Int(length)
                visit(number, 2, Data(bytes[i..<end]))
                i = end
            default: return
            }
        }
    }
}
