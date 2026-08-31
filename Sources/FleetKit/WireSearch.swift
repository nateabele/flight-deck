import Foundation

/// How many transcript hits BM25 selects before recency reorders them (§7).
///
/// Shared rather than duplicated: `SearchModel.transcriptLimit` on the app side is
/// `@MainActor`-isolated, so a socket callback on the Mac cannot read it to clamp a phone's
/// `FleetRequest.search` limit. One constant both sides can see, with no actor hop.
public enum SearchLimits {
    /// How many transcript hits BM25 selects before recency reorders them.
    public static let maxHits = 200
}

/// One conversation the Mac's index knows a name for.
///
/// The phone matches names over these locally, so search over history feels the same as
/// search over open tabs. At a few hundred conversations the whole catalogue is tens of
/// kilobytes, which is why it is shipped rather than queried per keystroke.
public struct WireConversation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let projectPath: String

    public init(id: String, name: String, projectPath: String) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
    }
}

/// The answer to `FleetRequest.conversations`.
///
/// **`sessionActivity` is a request's answer, not fleet state — and, deliberately, not a
/// field on `WireSession`.** The plan originally put a `lastActivity` field there; that is
/// cancelled. `WireSession` is what `FleetProjection` builds, and it is the oracle
/// `FleetReplicator`'s drift check compares its folded mirror against after every batch
/// (`checkForDrift`, `"fleet event log drifted from the store — a mutation recorded no
/// event"`) — a snapshot field that changed with nothing recorded would trip that alarm
/// continuously, since a transcript's mtime moves on every write an agent makes and no fleet
/// event records that. So recency rides this reply instead, exactly the reasoning
/// `WireNewSessionOptions` and `FleetRequest.macEndpoints` give for staying requests rather
/// than snapshot state: correlated by `cid`, nothing entering `FleetSnapshot`, out of the
/// drift check's reach entirely.
///
/// Keyed by `uuidString` rather than `[UUID: Date]` — `Codable`'s synthesized encoding for a
/// non-`String`-keyed dictionary is a flat `[key, value, key, value, ...]` array, which is a
/// wire shape nobody wants to debug.
public struct WireConversationCatalogue: Codable, Equatable, Sendable {
    /// Historical conversations: id, name, project path. Live tabs are not included here —
    /// they are already in `FleetSnapshot` — but their recency is, in `sessionActivity`.
    public let conversations: [WireConversation]
    /// Live tab id (`uuidString`) → its transcript's mtime.
    public let sessionActivity: [String: Date]

    public init(conversations: [WireConversation], sessionActivity: [String: Date]) {
        self.conversations = conversations
        self.sessionActivity = sessionActivity
    }
}

/// How far the Mac has got through its backfill.
///
/// Carried on a search reply rather than pushed as an event: it is only interesting while
/// somebody is looking at a search field, and an event would log it into the resume cursor.
public struct WireIndexingProgress: Codable, Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// The answer to `FleetRequest.search`.
///
/// `hits` arrive in BM25 order and are NOT ranked — ranking happens on the phone, where the
/// name half of the results lives. Merging the two halves anywhere else would mean shipping
/// the phone's fleet to the Mac on every keystroke.
public struct WireSearchHits: Codable, Equatable, Sendable {
    public let hits: [TranscriptHit]
    public let indexing: WireIndexingProgress?

    public init(hits: [TranscriptHit], indexing: WireIndexingProgress?) {
        self.hits = hits
        self.indexing = indexing
    }
}
