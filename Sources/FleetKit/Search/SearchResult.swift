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
    /// A bare `Date`, against `TimelineItem.at`'s documented reason not to be one — see
    /// `TimelineItem.at`'s doc comment. Safe only while neither end sets a date strategy on
    /// its `JSONEncoder`/`JSONDecoder`; both currently use the bare default, which round-trips
    /// a `Date` as seconds-since-epoch on both sides identically. Setting a strategy anywhere
    /// — on either type, since `JSONEncoder`'s strategy is per-instance, not per-type — would
    /// shift every timestamp on this wire silently, with nothing here to catch it.
    public let timestamp: Date
    /// Where this message's record starts in its transcript, in bytes, at a line boundary —
    /// which is exactly what `TimelineAnchor.around` takes. This is what lets a hit be
    /// opened rather than only read.
    public let offset: Int
    /// Which agent wrote this transcript, as `AgentID.rawValue`.
    ///
    /// **A `String`, not an `AgentID`, because `AgentID` is not in FleetKit** — this module
    /// compiles for iOS and is limited to Foundation/Network/Security, and the phone has no
    /// adapters to name. The desk maps it back with `AgentID(rawValue:)`; a value neither end
    /// recognises degrades to "unknown agent", which is a row without a glyph rather than a
    /// decode failure that would lose every other hit in the frame.
    public let agent: String
    /// codex: `session_meta.payload.source` — "exec", "cli", "vscode". nil for claude.
    /// The only consumer is `SearchRanker`'s `.automated` tier.
    public let provenance: String?
    /// The literal directory this conversation ran in — the project, or one of its worktrees.
    /// Empty when the index predates this field; `SessionStore.openConversation` falls back
    /// to `projectPath` in that case.
    public let workingDirectory: String
    /// The on-disk transcript/rollout file this hit came from. Empty when the index predates
    /// this field. `CodexAdapter.binding(for:)` reads a session's `transcriptPath` to find the
    /// thread's rollout file; without it, resuming a codex search result starts a fresh, empty
    /// thread instead of reopening the conversation the user searched for. Task 3 populates it
    /// from `message.source`; here it only travels with its default.
    public let transcriptPath: String

    public init(
        rowID: Int64, conversationID: String, projectPath: String,
        conversationName: String, snippet: String, timestamp: Date, offset: Int,
        agent: String = "claude", provenance: String? = nil, workingDirectory: String = "",
        transcriptPath: String = ""
    ) {
        self.rowID = rowID
        self.conversationID = conversationID
        self.projectPath = projectPath
        self.conversationName = conversationName
        self.snippet = snippet
        self.timestamp = timestamp
        self.offset = offset
        self.agent = agent
        self.provenance = provenance
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
    }

    /// Hand-written solely so the four fields added after the phone shipped decode as
    /// absent rather than as a thrown error. A synthesised decoder treats a missing
    /// non-optional key as a failure, and `WireSearchHits` decodes its whole array at once —
    /// so one old payload would lose every hit in the frame, not just its new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowID = try c.decode(Int64.self, forKey: .rowID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        projectPath = try c.decode(String.self, forKey: .projectPath)
        conversationName = try c.decode(String.self, forKey: .conversationName)
        snippet = try c.decode(String.self, forKey: .snippet)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        offset = try c.decode(Int.self, forKey: .offset)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        provenance = try c.decodeIfPresent(String.self, forKey: .provenance)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath) ?? ""
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
    /// Which agent this candidate belongs to, as `AgentID.rawValue`. See `TranscriptHit.agent`
    /// for why this is a raw string rather than an `AgentID`.
    public let agent: String
    /// See `TranscriptHit.transcriptPath`. Carried here for the same later-task resume path.
    public let transcriptPath: String

    public init(
        id: String, kind: SearchResultKind, name: String, projectPath: String,
        projectName: String, lastActivity: Date, conversationID: String?,
        agent: String = "claude", transcriptPath: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.projectPath = projectPath
        self.projectName = projectName
        self.lastActivity = lastActivity
        self.conversationID = conversationID
        self.agent = agent
        self.transcriptPath = transcriptPath
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
