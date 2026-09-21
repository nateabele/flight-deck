import FleetKit
import Foundation

/// What the index knows about a conversation: its newest name, and which project it
/// belongs to. Defined here rather than beside its consumer so the protocol, the SQLite
/// implementation and `SearchCandidates` all name one type.
struct IndexedConversation: Equatable, Sendable {
    let name: String
    let projectPath: String
    /// `AgentID.rawValue`. A conversation with no open tab still has to resume as the right
    /// agent, and this row is the only record of which one it was.
    let agent: String
}

/// Storage for the searchable half of transcripts.
///
/// A protocol so `SearchModel` can be tested against an in-memory stub while the real thing
/// talks to SQLite. Everything here is synchronous and throwing; callers run it off the main
/// actor.
protocol SearchIndex: AnyObject {
    /// Adds `messages`, and — when `offset` is non-nil — records that `ref.url` has been read
    /// through that byte position.
    ///
    /// Takes the whole `TranscriptRef` rather than a URL plus a project path because the
    /// index now files four facts about a transcript (project, agent, provenance, working
    /// directory) and passing them as loose parameters is how three of them get forgotten at
    /// one of the two call sites.
    ///
    /// `nil` means live ingest: add the rows, do NOT touch this source's read position. The
    /// live watcher starts at end-of-file, so its byte position is the wrong number to record
    /// as indexing progress — recording it would make the backfill start there and silently
    /// never index that conversation's history, which is exactly the history ⌘K exists to
    /// search. An `offset` of 0 means the file restarted and this source's rows are replaced.
    func ingest(_ messages: [IndexedMessage], for ref: TranscriptRef, offset: UInt64?) throws

    /// Where reading `source` should resume. 0 for a file never seen.
    func readOffset(for source: URL) -> UInt64

    /// `query` is an FTS5 MATCH expression from `FTS5Query.match`, never raw user text.
    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit]

    /// Conversation id → its name and project, for rows and for name matching over
    /// conversations that have no open tab.
    func conversationNames() throws -> [String: IndexedConversation]

    /// Records what a conversation is called, which project it belongs to, and which agent
    /// wrote it, so a result row for a conversation with no open tab is still named and
    /// resumable as the right agent.
    func setConversationName(
        _ name: String, projectPath: String, agent: String, for id: String
    ) throws

    /// Drops everything outside the current scope.
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws

    /// Shown in a name-match row when known. Cheap enough to call per visible row.
    func messageCount(forConversation id: String) throws -> Int
}
