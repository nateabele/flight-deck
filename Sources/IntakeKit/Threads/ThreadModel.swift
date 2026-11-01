import Foundation

// The ask-thread model (planning v2 §5, P1 Task 0). ThreadRunner is the only writer of
// `threads/` and stores these; the app and the phone only read them, through
// `ThreadStoreReading`. Every shape here is a storage format from the day it lands: a field
// added later is optional, and a renamed case is a file that no longer loads.

/// Names one thread. Codes as a bare UUID string, so a thread id reads the same as a folder
/// name under `threads/`, inside a JSON line, and in a wire field.
public struct ThreadID: Hashable, Codable, Sendable {
    public var raw: UUID

    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public init(raw: UUID) { self.raw = raw }

    /// The thread a phone's `intake.thread.send` with no thread opens: named by the send's token,
    /// so a retry after a lost ack names the same thread and opens no second one. Its first
    /// message's id is `ThreadCommand.firstMessageID(token:)`, for the same reason.
    public static func opened(byToken token: UUID) -> ThreadID { ThreadID(raw: token) }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// Where a thread stands, as the index groups it. `answering` while a turn runs; `needsYou`
/// once a turn ends with a question or a pending diff; `stale` when its pending diff could not
/// be rebased onto a newer round (`PlanRebase`); `resolved` until it is reopened.
public enum ThreadStatus: String, Codable, Sendable {
    case open, answering, needsYou, stale, resolved
}

/// What a thread is about. A nil `note` is the whole plan. `visualID` and `elementID` stay nil
/// until visual blocks (P2a) — they are here now so a canvas thread needs no storage change.
public struct ThreadAnchor: Codable, Equatable, Sendable {
    public var note: NoteAnchor?
    public var visualID: String?
    public var elementID: String?

    public init(note: NoteAnchor? = nil, visualID: String? = nil, elementID: String? = nil) {
        self.note = note
        self.visualID = visualID
        self.elementID = elementID
    }

    public static let wholePlan = ThreadAnchor()
}

/// One thread's header, `threads/<id>/thread.json`. `followsCheckpoint` is the checkpoint its
/// workspace was last built from: a thread follows the newest round, and a mismatch is what
/// makes the next turn rebuild the workspace and draw the "Now reading …" divider.
public struct ThreadRecord: Codable, Equatable, Sendable {
    public var id: ThreadID
    public var title: String
    public var anchor: ThreadAnchor
    public var status: ThreadStatus
    public var agent: AgentID
    public var model: String
    public var effort: String
    public var autoAccept: Bool
    /// The headless session the next turn resumes; nil before the first turn has run.
    public var sessionID: String?
    public var followsCheckpoint: Int
    public var createdAt: Date
    /// A `resolve` folded while a turn was still to run (⌘⇧↩, send and resolve; B-I3): the
    /// thread resolves once its queued turns have ended. Nil on threads written before it.
    public var resolveAfterTurn: Bool?

    public init(id: ThreadID, title: String, anchor: ThreadAnchor, status: ThreadStatus = .open, agent: AgentID,
                model: String, effort: String, autoAccept: Bool = false, sessionID: String? = nil,
                followsCheckpoint: Int, createdAt: Date) {
        self.id = id
        self.title = title
        self.anchor = anchor
        self.status = status
        self.agent = agent
        self.model = model
        self.effort = effort
        self.autoAccept = autoAccept
        self.sessionID = sessionID
        self.followsCheckpoint = followsCheckpoint
        self.createdAt = threadMillisecondRounded(createdAt)
    }
}

/// One turn: what the human sent (`you`, or `answers` to the agent's questions) and what the
/// agent returned. `reply`, `decision` and `endedAt` are nil while the turn runs. `errors` are
/// the validator's refusals of this turn's actions (R6), fed into the next attempt.
/// `messageID` is the sender's id for the message, which is what makes a redelivered message
/// run no second turn.
public struct ThreadTurn: Codable, Equatable, Sendable {
    public var seq: Int
    public var messageID: String
    public var you: String?
    public var answers: [StructuredAnswer]?
    public var reply: String?
    public var decision: String?
    public var actions: [ThreadAction]
    public var errors: [String]
    /// The checkpoint the turn's workspace was built from.
    public var checkpoint: Int
    public var startedAt: Date
    public var endedAt: Date?

    public init(seq: Int, messageID: String, you: String? = nil, answers: [StructuredAnswer]? = nil,
                reply: String? = nil, decision: String? = nil, actions: [ThreadAction] = [], errors: [String] = [],
                checkpoint: Int, startedAt: Date, endedAt: Date? = nil) {
        self.seq = seq
        self.messageID = messageID
        self.you = you
        self.answers = answers
        self.reply = reply
        self.decision = decision
        self.actions = actions
        self.errors = errors
        self.checkpoint = checkpoint
        self.startedAt = threadMillisecondRounded(startedAt)
        self.endedAt = endedAt.map(threadMillisecondRounded)
    }

    private enum CodingKeys: String, CodingKey {
        case seq, messageID, you, answers, reply, decision, actions, errors, checkpoint, startedAt, endedAt
    }

    /// Synthesized but for `actions`, decoded one by one: a turn a later build wrote may hold an
    /// action this build has no case for (P2a's `makeVisual`), and failing the whole turn would
    /// drop the thread's reply from the panel. The action is left out; the reply stays.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        messageID = try c.decode(String.self, forKey: .messageID)
        you = try c.decodeIfPresent(String.self, forKey: .you)
        answers = try c.decodeIfPresent([StructuredAnswer].self, forKey: .answers)
        reply = try c.decodeIfPresent(String.self, forKey: .reply)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        actions = try c.decodeIfPresent([Lossy<ThreadAction>].self, forKey: .actions)?.compactMap(\.value) ?? []
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        checkpoint = try c.decode(Int.self, forKey: .checkpoint)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }
}

/// A diff's lifecycle. `stale`: a newer round landed and the diff could not be rebased onto it
/// (`PlanRebase`) — it is never applied as a guess, only re-proposed.
public enum DiffState: String, Codable, Sendable {
    case pending, accepted, rejected, stale
}

/// A diff a turn proposed, once the validator found its quote exactly once (R6). `anchor` is
/// where `old` sits on `checkpoint`'s effective plan, located the way a note is.
public struct ThreadDiff: Codable, Equatable, Sendable {
    public var id: UUID
    public var thread: ThreadID
    /// The `ThreadTurn.seq` that proposed it, so the conversation can show a diff in its turn;
    /// nil when no turn is known.
    public var turn: Int?
    public var checkpoint: Int
    public var anchor: NoteAnchor
    public var old: String
    public var new: String
    public var state: DiffState

    public init(id: UUID = UUID(), thread: ThreadID, turn: Int? = nil, checkpoint: Int, anchor: NoteAnchor, old: String,
                new: String, state: DiffState = .pending) {
        self.id = id
        self.thread = thread
        self.turn = turn
        self.checkpoint = checkpoint
        self.anchor = anchor
        self.old = old
        self.new = new
        self.state = state
    }
}

/// What the app and the phone read of `threads/`. ThreadRunner's store is the writer and
/// conforms (Stream A); the Mac UI and the phone projection code against this, with a fake
/// until then.
public protocol ThreadStoreReading {
    func threads() -> [ThreadRecord]
    func turns(_ id: ThreadID) -> [ThreadTurn]
    func diffs(_ id: ThreadID) -> [ThreadDiff]
    /// What the thread's agent is doing while a turn runs — "reading §3", "running rg …",
    /// "thinking" (R2: the reply itself lands only when the turn ends). nil when no turn runs.
    func activity(_ id: ThreadID) -> String?
}

/// A reader with no threads: what the Mac UI and the phone projection read until ThreadRunner's
/// store exists, and a starting point for a test's fake.
public struct EmptyThreadStore: ThreadStoreReading, Sendable {
    public init() {}
    public func threads() -> [ThreadRecord] { [] }
    public func turns(_ id: ThreadID) -> [ThreadTurn] { [] }
    public func diffs(_ id: ThreadID) -> [ThreadDiff] { [] }
    public func activity(_ id: ThreadID) -> String? { nil }
}

/// One element of a list, or nil where it failed to decode, so one unknown entry costs only
/// itself.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// `IntakeJSON` keeps only milliseconds, so a sub-millisecond `Date()` would not equal itself
/// after a save and load — the same rounding `Checkpoint` and `Tape` apply.
func threadMillisecondRounded(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
}
