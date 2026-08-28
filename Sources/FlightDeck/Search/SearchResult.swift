import Foundation

/// What a result *is*, which decides its icon and what activating it does.
enum SearchResultKind: Equatable, Sendable {
    /// A tab open in the deck right now. Activating it selects that tab.
    case session(UUID)
    /// A project in the sidebar. Activating it selects the project's first session.
    case project
    /// A conversation on disk with no tab attached. Activating it resumes into a new tab.
    case conversation(String)
}

/// One match found inside a conversation, straight out of the index.
///
/// `snippet` arrives with the sentinel markers FTS5 was asked for; the view turns those into
/// an `AttributedString`. Keeping them as markers rather than as ranges means the index does
/// not have to reason about `String.Index` across a SQLite boundary.
struct TranscriptHit: Equatable, Sendable {
    /// `message.id` — the FTS table's `content_rowid`. Two messages in the same
    /// conversation can share a timestamp (or carry none at all), so this, not
    /// `(conversationID, timestamp)`, is what the result id is built from.
    let rowID: Int64
    let conversationID: String
    let projectPath: String
    let conversationName: String
    let snippet: String
    let timestamp: Date
}

/// A name the ranker may match against: a session, a project, or a past conversation.
///
/// Flattened deliberately — the ranker takes one array rather than reaching into
/// `SessionStore`, which is what keeps it pure and instantly testable.
struct NameCandidate: Equatable {
    let id: String
    let kind: SearchResultKind
    let name: String
    let projectPath: String
    let projectName: String
    /// For a live session this is its transcript's mtime, which moves whenever the agent
    /// writes. There is no per-session activity timestamp in the model, and adding one
    /// would duplicate what the file already records exactly.
    let lastActivity: Date
    let conversationID: String?
}

/// A row in the overlay.
struct SearchResult: Identifiable, Equatable {
    let id: String
    let kind: SearchResultKind
    let title: String
    let projectName: String
    let projectPath: String
    let tier: MatchTier
    let recency: Date
    /// Where the query matched inside `title`. Empty for transcript hits, whose evidence is
    /// in `snippet` instead.
    let highlightedRanges: [Range<String.Index>]
    /// The two-line extract, with FTS5 sentinels. nil for name matches.
    let snippet: String?
    let conversationID: String?
}
