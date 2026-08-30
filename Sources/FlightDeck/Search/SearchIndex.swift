import FleetKit
import Foundation

/// The markers `snippet()` wraps matched terms in.
///
/// U+0002 and U+0003 (START OF TEXT / END OF TEXT) rather than something like `<b>`: the
/// text being marked up is arbitrary conversation content, and any printable delimiter is
/// something a message could legitimately contain — an agent discussing HTML would produce
/// snippets that highlight the wrong span. `TranscriptExtractor` cannot emit these because
/// they are control characters, which is what makes them unambiguous.
enum SnippetSentinel {
    static let open: Character = "\u{2}"
    static let close: Character = "\u{3}"
}

/// What the index knows about a conversation: its newest name, and which project it
/// belongs to. Defined here rather than beside its consumer so the protocol, the SQLite
/// implementation and `SearchCandidates` all name one type.
struct IndexedConversation: Equatable, Sendable {
    let name: String
    let projectPath: String
}

/// Storage for the searchable half of transcripts.
///
/// A protocol so `SearchModel` can be tested against an in-memory stub while the real thing
/// talks to SQLite. Everything here is synchronous and throwing; callers run it off the main
/// actor.
protocol SearchIndex: AnyObject {
    /// Adds `messages`, and — when `offset` is non-nil — records that `source` has been read
    /// through that byte position.
    ///
    /// `nil` means live ingest: add the rows, do NOT touch this source's read position. The live
    /// transcript watcher deliberately starts at end-of-file (it exists to catch titles, and skips
    /// the backlog), so its byte position is the wrong number to record as indexing progress —
    /// recording it would make the backfill start there and silently never index that
    /// conversation's history, which is exactly the history ⌘K exists to search.
    ///
    /// An `offset` of 0 means the file restarted and this source's existing rows are replaced.
    func ingest(
        _ messages: [IndexedMessage], from source: URL, projectPath: String, offset: UInt64?
    ) throws

    /// Where reading `source` should resume. 0 for a file never seen.
    func readOffset(for source: URL) -> UInt64

    /// `query` is an FTS5 MATCH expression from `FTS5Query.match`, never raw user text.
    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit]

    /// Conversation id → its name and project, for rows and for name matching over
    /// conversations that have no open tab.
    func conversationNames() throws -> [String: IndexedConversation]

    /// Records what a conversation is called and which project it belongs to, so a result row for
    /// a conversation with no open tab is still named something a person recognises.
    func setConversationName(_ name: String, projectPath: String, for id: String) throws

    /// Drops everything outside the current scope.
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws

    /// Shown in a name-match row when known. Cheap enough to call per visible row.
    func messageCount(forConversation id: String) throws -> Int
}
