import Foundation

/// What a result *is*, which decides its icon and what activating it does.
public enum SearchResultKind: Equatable, Sendable {
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
public struct TranscriptHit: Codable, Equatable, Sendable {
    /// `message.id` — the FTS table's `content_rowid`. Two messages in the same
    /// conversation can share a timestamp (or carry none at all), so this, not
    /// `(conversationID, timestamp)`, is what the result id is built from.
    public let rowID: Int64
    public let conversationID: String
    public let projectPath: String
    public let conversationName: String
    public let snippet: String
    public let timestamp: Date
    /// Where this message's record starts in its transcript, in bytes, at a line boundary —
    /// which is exactly what `TimelineAnchor.around` takes. This is what lets a hit be
    /// opened rather than only read.
    public let offset: Int

    public init(
        rowID: Int64, conversationID: String, projectPath: String,
        conversationName: String, snippet: String, timestamp: Date, offset: Int
    ) {
        self.rowID = rowID
        self.conversationID = conversationID
        self.projectPath = projectPath
        self.conversationName = conversationName
        self.snippet = snippet
        self.timestamp = timestamp
        self.offset = offset
    }
}

/// A name the ranker may match against: a session, a project, or a past conversation.
///
/// Flattened deliberately — the ranker takes one array rather than reaching into
/// `SessionStore`, which is what keeps it pure and instantly testable.
public struct NameCandidate: Equatable {
    public let id: String
    public let kind: SearchResultKind
    public let name: String
    public let projectPath: String
    public let projectName: String
    /// For a live session this is its transcript's mtime, which moves whenever the agent
    /// writes. There is no per-session activity timestamp in the model, and adding one
    /// would duplicate what the file already records exactly.
    public let lastActivity: Date
    public let conversationID: String?

    public init(
        id: String, kind: SearchResultKind, name: String, projectPath: String,
        projectName: String, lastActivity: Date, conversationID: String?
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.projectPath = projectPath
        self.projectName = projectName
        self.lastActivity = lastActivity
        self.conversationID = conversationID
    }
}

/// A row in the overlay.
public struct SearchResult: Identifiable, Equatable {
    public let id: String
    public let kind: SearchResultKind
    public let title: String
    public let projectName: String
    public let projectPath: String
    public let tier: MatchTier
    public let recency: Date
    /// Where the query matched inside `title`. Empty for transcript hits, whose evidence is
    /// in `snippet` instead.
    public let highlightedRanges: [Range<String.Index>]
    /// The two-line extract, with FTS5 sentinels. nil for name matches.
    public let snippet: String?
    public let conversationID: String?
    /// True for the second and later matches shown from the SAME conversation.
    ///
    /// Transcript hits are grouped: the first row for a conversation carries its `name · project`
    /// heading and the rest are continuations, drawn indented and headless. Without this every
    /// row repeated the same heading, so one chatty conversation read as the same session listed
    /// over and over. It is a display flag only — a continuation is still an independently
    /// selectable row with its own id, so arrow-key navigation is unaffected.
    public var isContinuation: Bool = false
    /// Where this match's message starts in its transcript, in bytes — `TranscriptHit.offset`,
    /// carried through so an activator can ask `TimelineAnchor.around(offset)` for it. `nil`
    /// for a name match, which names no line in particular.
    public let offset: Int?

    public init(
        id: String, kind: SearchResultKind, title: String, projectName: String,
        projectPath: String, tier: MatchTier, recency: Date,
        highlightedRanges: [Range<String.Index>], snippet: String?, conversationID: String?,
        isContinuation: Bool = false, offset: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
        self.tier = tier
        self.recency = recency
        self.highlightedRanges = highlightedRanges
        self.snippet = snippet
        self.conversationID = conversationID
        self.isContinuation = isContinuation
        self.offset = offset
    }
}
