import Foundation

// Ask threads on the fleet wire (planning v2 §10, P1). FleetKit imports Foundation and nothing
// else, so these are wire copies of IntakeKit's thread model, not the model itself: statuses,
// states and kinds stay strings, so a value a later Mac invents never breaks an older phone's
// decode. Every field an older Mac never sends is optional. The phone reaches none of this
// until the detail's `threads` flag is true.

/// Where a thread points, as the phone reads and sends it. The phone sends what it SHOWED — a
/// block index and the rendered phrase, as for a phone note (`intake.note`) — and the Mac builds
/// the real anchor from the markdown source. `section` is the Mac's, for display; the phone
/// leaves it nil. A nil anchor is the whole plan.
public struct WireThreadAnchor: Codable, Equatable, Sendable {
    public var checkpoint: Int?
    public var block: Int?
    public var quote: String?
    public var section: String?

    public init(checkpoint: Int? = nil, block: Int? = nil, quote: String? = nil, section: String? = nil) {
        self.checkpoint = checkpoint; self.block = block; self.quote = quote; self.section = section
    }
}

/// How much is in a thread, for its index row and the fleet list's "needs you" badge.
public struct WireThreadCounts: Codable, Equatable, Sendable {
    public var turns: Int
    public var pendingDiffs: Int
    public var openQuestions: Int

    public init(turns: Int = 0, pendingDiffs: Int = 0, openQuestions: Int = 0) {
        self.turns = turns; self.pendingDiffs = pendingDiffs; self.openQuestions = openQuestions
    }
}

/// One thread's index row, carried on `WireIntakePlan.threads`. `status` is a `ThreadStatus`
/// raw value (open, answering, needsYou, stale, resolved); `excerpt` the latest reply's first
/// words, nil before the first reply. `readsFilesOnly` is true when the thread's agent has no
/// shell (grok, opencode: `HeadlessCommand.threadReadsFilesOnly`), so the thread screen can say
/// so as the Mac's header does; nil otherwise, and from a Mac that predates it.
public struct WireThreadSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var anchor: WireThreadAnchor?
    public var status: String
    public var counts: WireThreadCounts
    public var excerpt: String?
    public var readsFilesOnly: Bool?

    public init(id: UUID, title: String, anchor: WireThreadAnchor? = nil, status: String,
                counts: WireThreadCounts = WireThreadCounts(), excerpt: String? = nil, readsFilesOnly: Bool? = nil) {
        self.id = id; self.title = title; self.anchor = anchor; self.status = status
        self.counts = counts; self.excerpt = excerpt; self.readsFilesOnly = readsFilesOnly
    }
}

/// One turn of a thread's conversation, fetched on demand (`intake.thread.get`), never pushed.
/// `questions` are the turn's `askQuestion` actions, `diffs` the ids of the diffs it proposed
/// (in full on `WireThreadPage.diffs`). `reply`, `decision` and `endedAt` are nil while it runs.
public struct WireThreadTurn: Codable, Equatable, Sendable {
    public var seq: Int
    public var messageID: String
    public var you: String?
    public var answers: [WireStructuredAnswer]?
    public var reply: String?
    public var decision: String?
    public var questions: [WireStructuredQuestion]?
    public var diffs: [UUID]?
    public var errors: [String]
    public var checkpoint: Int
    public var startedAt: Date
    public var endedAt: Date?

    public init(seq: Int, messageID: String, you: String? = nil, answers: [WireStructuredAnswer]? = nil,
                reply: String? = nil, decision: String? = nil, questions: [WireStructuredQuestion]? = nil,
                diffs: [UUID]? = nil, errors: [String] = [], checkpoint: Int, startedAt: Date, endedAt: Date? = nil) {
        self.seq = seq; self.messageID = messageID; self.you = you; self.answers = answers
        self.reply = reply; self.decision = decision; self.questions = questions; self.diffs = diffs
        self.errors = errors; self.checkpoint = checkpoint; self.startedAt = startedAt; self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case seq, messageID, you, answers, reply, decision, questions, diffs, errors, checkpoint, startedAt, endedAt
    }

    /// `errors` and `checkpoint` decode as optional, like every other field here (C-7): a later
    /// Mac that leaves one out must not break the phone's decode of the whole page.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        messageID = try c.decode(String.self, forKey: .messageID)
        you = try c.decodeIfPresent(String.self, forKey: .you)
        answers = try c.decodeIfPresent([WireStructuredAnswer].self, forKey: .answers)
        reply = try c.decodeIfPresent(String.self, forKey: .reply)
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        questions = try c.decodeIfPresent([WireStructuredQuestion].self, forKey: .questions)
        diffs = try c.decodeIfPresent([UUID].self, forKey: .diffs)
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        checkpoint = try c.decodeIfPresent(Int.self, forKey: .checkpoint) ?? 0
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }
}

/// A diff awaiting the human, in full, so the phone draws its gutter bar without a fetch.
/// `blockIndex` is the reader block of `checkpoint`'s plan it sits in (as `WireNote.blockIndex`
/// places a note), nil when the Mac can't place it. `old` is the passage being replaced, as it
/// reads in that plan — the phone shows it on tap and finds it within the block — and `new` its
/// replacement. `state` is a `DiffState` raw value; a `stale` one is refused (`diff_stale`).
public struct WirePendingDiff: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var thread: UUID
    public var checkpoint: Int
    public var blockIndex: Int?
    public var old: String
    public var new: String
    public var state: String

    public init(id: UUID, thread: UUID, checkpoint: Int, blockIndex: Int? = nil, old: String, new: String, state: String) {
        self.id = id; self.thread = thread; self.checkpoint = checkpoint; self.blockIndex = blockIndex
        self.old = old; self.new = new; self.state = state
    }
}

/// The reply to `FleetRequest.intakeThreadGet`: the thread's row, its turns after the request's
/// `since` (all of them when nil), and its diffs.
public struct WireThreadPage: Codable, Equatable, Sendable {
    public var thread: WireThreadSummary
    public var turns: [WireThreadTurn]
    public var diffs: [WirePendingDiff]

    public init(thread: WireThreadSummary, turns: [WireThreadTurn] = [], diffs: [WirePendingDiff] = []) {
        self.thread = thread; self.turns = turns; self.diffs = diffs
    }
}
