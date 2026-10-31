import Foundation

/// A control message for ThreadRunner, one line of `threads/commands.jsonl` (R8). A separate
/// file from the tape's `commands.jsonl` on purpose: any unacked tape command wakes
/// IntakeRunner, whose switch is exhaustive, so a thread message there would wake the round
/// engine for nothing — and an older IntakeRunner would drop it. Only what reaches the plan
/// goes on the tape: `TapeCommand.applyThreadDiff`, and a `note` whose `source` is a thread.
///
/// Custom `Codable` with a flat `{"kind", "thread", …}` object, like `TapeCommand`: two
/// processes share this file, so its shape is fixed here rather than left to the compiler.
/// An unknown `kind` throws, so a line a later build wrote is dropped, never misread.
///
/// - `message`: `messageID` is the sender's id for this message — a phone retry or a canvas
///   redelivery carries the same one, and ThreadRunner runs one turn per id (R9). `source`,
///   `elementID` and `subjectRevision` are the canvas inbox's fields (P2b), nil until then.
/// - `decideDiff` records the human's ✓ or ✗ in the thread. An accept also puts
///   `applyThreadDiff` on the tape; this is how the diff's own state (`threads/`, written only
///   by ThreadRunner) learns of either answer.
/// - `repropose` runs one turn against the newest checkpoint for a stale diff.
public enum ThreadCommand: Codable, Equatable, Sendable {
    case open(ThreadID, ThreadAnchor, title: String, agent: AgentID, model: String, effort: String)
    case message(ThreadID, text: String, messageID: String, source: String?, elementID: String?, subjectRevision: String?)
    case answer(ThreadID, [StructuredAnswer], messageID: String)
    case setAutoAccept(ThreadID, Bool)
    case setAgent(ThreadID, AgentID, model: String, effort: String)
    case resolve(ThreadID)
    case reopen(ThreadID)
    case repropose(ThreadID, diff: UUID)
    case decideDiff(ThreadID, diff: UUID, accept: Bool)

    /// The `messageID` of the first message in a thread the phone opened with `token` (see
    /// `ThreadID.opened(byToken:)`): the token's string, so a retried send runs no second turn.
    public static func firstMessageID(token: UUID) -> String { token.uuidString }

    /// The thread every command addresses.
    public var thread: ThreadID {
        switch self {
        case .open(let t, _, _, _, _, _), .message(let t, _, _, _, _, _), .answer(let t, _, _), .setAutoAccept(let t, _),
             .setAgent(let t, _, _, _), .resolve(let t), .reopen(let t), .repropose(let t, _), .decideDiff(let t, _, _):
            t
        }
    }

    private enum Kind: String, Codable {
        case open, message, answer, setAutoAccept, setAgent, resolve, reopen, repropose, decideDiff
    }
    private enum CodingKeys: String, CodingKey {
        case kind, thread, anchor, title, agent, model, effort, text, messageID, source, elementID, subjectRevision
        case answers, on, diff, accept
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let thread = try c.decode(ThreadID.self, forKey: .thread)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .open:
            self = .open(thread, try c.decodeIfPresent(ThreadAnchor.self, forKey: .anchor) ?? .wholePlan,
                         title: try c.decode(String.self, forKey: .title), agent: try c.decode(AgentID.self, forKey: .agent),
                         model: try c.decode(String.self, forKey: .model), effort: try c.decode(String.self, forKey: .effort))
        case .message:
            self = .message(thread, text: try c.decode(String.self, forKey: .text),
                            messageID: try c.decode(String.self, forKey: .messageID),
                            source: try c.decodeIfPresent(String.self, forKey: .source),
                            elementID: try c.decodeIfPresent(String.self, forKey: .elementID),
                            subjectRevision: try c.decodeIfPresent(String.self, forKey: .subjectRevision))
        case .answer:
            self = .answer(thread, try c.decode([StructuredAnswer].self, forKey: .answers),
                           messageID: try c.decode(String.self, forKey: .messageID))
        case .setAutoAccept:
            self = .setAutoAccept(thread, try c.decode(Bool.self, forKey: .on))
        case .setAgent:
            self = .setAgent(thread, try c.decode(AgentID.self, forKey: .agent),
                             model: try c.decode(String.self, forKey: .model), effort: try c.decode(String.self, forKey: .effort))
        case .resolve: self = .resolve(thread)
        case .reopen: self = .reopen(thread)
        case .repropose: self = .repropose(thread, diff: try c.decode(UUID.self, forKey: .diff))
        case .decideDiff:
            self = .decideDiff(thread, diff: try c.decode(UUID.self, forKey: .diff), accept: try c.decode(Bool.self, forKey: .accept))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(thread, forKey: .thread)
        switch self {
        case .open(_, let anchor, let title, let agent, let model, let effort):
            try c.encode(Kind.open, forKey: .kind)
            try c.encode(anchor, forKey: .anchor)
            try c.encode(title, forKey: .title)
            try c.encode(agent, forKey: .agent)
            try c.encode(model, forKey: .model)
            try c.encode(effort, forKey: .effort)
        case .message(_, let text, let messageID, let source, let elementID, let subjectRevision):
            try c.encode(Kind.message, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(messageID, forKey: .messageID)
            try c.encodeIfPresent(source, forKey: .source)
            try c.encodeIfPresent(elementID, forKey: .elementID)
            try c.encodeIfPresent(subjectRevision, forKey: .subjectRevision)
        case .answer(_, let answers, let messageID):
            try c.encode(Kind.answer, forKey: .kind)
            try c.encode(answers, forKey: .answers)
            try c.encode(messageID, forKey: .messageID)
        case .setAutoAccept(_, let on):
            try c.encode(Kind.setAutoAccept, forKey: .kind)
            try c.encode(on, forKey: .on)
        case .setAgent(_, let agent, let model, let effort):
            try c.encode(Kind.setAgent, forKey: .kind)
            try c.encode(agent, forKey: .agent)
            try c.encode(model, forKey: .model)
            try c.encode(effort, forKey: .effort)
        case .resolve:
            try c.encode(Kind.resolve, forKey: .kind)
        case .reopen:
            try c.encode(Kind.reopen, forKey: .kind)
        case .repropose(_, let diff):
            try c.encode(Kind.repropose, forKey: .kind)
            try c.encode(diff, forKey: .diff)
        case .decideDiff(_, let diff, let accept):
            try c.encode(Kind.decideDiff, forKey: .kind)
            try c.encode(diff, forKey: .diff)
            try c.encode(accept, forKey: .accept)
        }
    }
}

/// One line of `threads/commands.jsonl`: the same `{seq, command}` envelope as the tape's
/// `CommandEnvelope`, so the locked append helper (Stream B) assigns seqs to both files alike
/// and ThreadRunner resumes from `threads/cursor` the way IntakeRunner resumes from
/// `ackedCommandSeq` (R5).
public struct ThreadCommandEnvelope: Codable, Equatable, Sendable {
    public var seq: Int
    public var command: ThreadCommand
    public init(seq: Int, command: ThreadCommand) {
        self.seq = seq
        self.command = command
    }
}
