import Foundation

/// A diff as the agent proposes it: a quote with its context on `checkpoint`'s plan, the
/// `NoteAnchor` scheme, and the text to put in its place. Not yet a `ThreadDiff`: the validator
/// must first find the quote exactly once (R6).
public struct ProposedThreadDiff: Codable, Equatable, Sendable {
    public var checkpoint: Int
    public var quote: String
    public var prefix: String
    public var suffix: String
    /// The `#` heading the agent read the quote under, as `NoteAnchor.section` is: a tiebreak
    /// for the validator and a label for the card. nil when the agent didn't say.
    public var section: String?
    public var replacement: String

    public init(checkpoint: Int, quote: String, prefix: String = "", suffix: String = "", section: String? = nil,
                replacement: String) {
        self.checkpoint = checkpoint
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.section = section
        self.replacement = replacement
    }
}

/// One thing a turn asks to do to the plan. `makeVisual` and `addAlternate` arrive with visual
/// blocks (P2a).
///
/// Custom `Codable` with a flat `{"op", …}` object, the shape `ThreadActions.schemaJSON` asks
/// the agent for, so the agent's answer and the stored turn read the same. Keys an op doesn't
/// use are absent when stored and null from the agent; both decode. An unknown `op` throws.
public enum ThreadAction: Codable, Equatable, Sendable {
    case proposeDiff(ProposedThreadDiff)
    case addNote(PlanNote)
    case askQuestion(StructuredQuestion)

    private enum Op: String, Codable { case proposeDiff, addNote, askQuestion }
    private enum CodingKeys: String, CodingKey {
        case op, checkpoint, quote, prefix, suffix, section, replacement, id, kind, anchor, note, source, question
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .proposeDiff:
            self = .proposeDiff(ProposedThreadDiff(
                checkpoint: try c.decode(Int.self, forKey: .checkpoint),
                quote: try c.decode(String.self, forKey: .quote),
                prefix: try c.decodeIfPresent(String.self, forKey: .prefix) ?? "",
                suffix: try c.decodeIfPresent(String.self, forKey: .suffix) ?? "",
                section: try c.decodeIfPresent(String.self, forKey: .section),
                replacement: try c.decode(String.self, forKey: .replacement)))
        case .addNote:
            let raw = try c.decode(String.self, forKey: .kind)
            guard let kind = NoteKind(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown note kind \"\(raw)\"")
            }
            // The agent sends no id; a stored note keeps the one it was given, so the note a
            // turn added and the note the tape later holds are the same note. A null note is
            // no words — a Highlight or a Delete — which strict mode makes the agent send.
            self = .addNote(PlanNote(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(), kind: kind,
                                     note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                                     anchor: try c.decodeIfPresent(NoteAnchor.self, forKey: .anchor),
                                     source: (try? c.decodeIfPresent(NoteSource.self, forKey: .source)) ?? nil))
        case .askQuestion:
            self = .askQuestion(try c.decode(StructuredQuestion.self, forKey: .question))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .proposeDiff(let d):
            try c.encode(Op.proposeDiff, forKey: .op)
            try c.encode(d.checkpoint, forKey: .checkpoint)
            try c.encode(d.quote, forKey: .quote)
            try c.encode(d.prefix, forKey: .prefix)
            try c.encode(d.suffix, forKey: .suffix)
            try c.encodeIfPresent(d.section, forKey: .section)
            try c.encode(d.replacement, forKey: .replacement)
        case .addNote(let n):
            try c.encode(Op.addNote, forKey: .op)
            try c.encode(n.id, forKey: .id)
            try c.encode(n.kind, forKey: .kind)
            try c.encode(n.note, forKey: .note)
            try c.encodeIfPresent(n.anchor, forKey: .anchor)
            try c.encodeIfPresent(n.source, forKey: .source)
        case .askQuestion(let q):
            try c.encode(Op.askQuestion, forKey: .op)
            try c.encode(q, forKey: .question)
        }
    }
}

/// One turn's final answer: the reply (markdown, citations as `[cite:<id>]`), what was decided
/// (0–3 lines, empty when nothing was), and the actions.
public struct ThreadAnswer: Codable, Equatable, Sendable {
    public var reply: String
    public var decision: String
    public var actions: [ThreadAction]

    public init(reply: String, decision: String = "", actions: [ThreadAction] = []) {
        self.reply = reply
        self.decision = decision
        self.actions = actions
    }
}

/// The schema a thread turn answers in, and its decoder.
public enum ThreadActions {
    public struct Malformed: Error, Equatable { public let why: String }

    private static let nullableString = #"{"type":["string","null"]}"#
    private static let anchor = #"{"type":["object","null"],"additionalProperties":false,"required":["checkpoint","quote","section","prefix","suffix"],"properties":{"checkpoint":{"type":"integer"},"quote":{"type":"string"},"section":{"type":["string","null"]},"prefix":{"type":"string"},"suffix":{"type":"string"}}}"#
    /// Triage's own question fragment, made nullable for the ops that don't carry one.
    private static let question: String = {
        let head = #"{"type":"object""#
        precondition(Triage.questionItem.hasPrefix(head))
        return #"{"type":["object","null"]"# + Triage.questionItem.dropFirst(head.count)
    }()
    private static let noteKinds = NoteKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")

    /// One flat action object rather than a `oneOf` per op, the shape `Triage.op` already uses:
    /// every strict-mode CLI accepts it, where union support differs between them. Every
    /// property is required and an op's unused ones are null, as strict mode demands.
    private static let action = """
    {"type":"object","additionalProperties":false,
     "required":["op","checkpoint","quote","prefix","suffix","section","replacement","kind","anchor","note","question"],
     "properties":{
      "op":{"type":"string","enum":["proposeDiff","addNote","askQuestion"]},
      "checkpoint":{"type":["integer","null"]},
      "quote":\(nullableString),"prefix":\(nullableString),"suffix":\(nullableString),"section":\(nullableString),"replacement":\(nullableString),
      "kind":{"type":["string","null"],"enum":[\(noteKinds),null]},
      "anchor":\(anchor),
      "note":\(nullableString),
      "question":\(question)}}
    """

    /// Strict-mode schema for `codex exec --output-schema` and `claude --json-schema` (and the
    /// other adapters through their own compat paths), built like `Triage.schemaJSON`.
    public static let schemaJSON = """
    {"type":"object","additionalProperties":false,"required":["reply","decision","actions"],
     "properties":{
      "reply":{"type":"string"},
      "decision":\(nullableString),
      "actions":{"type":["array","null"],"items":\(action)}}}
    """

    private struct Wire: Decodable {
        let reply: String
        let decision: String?
        let actions: [ThreadAction]?
    }

    /// The agent's final answer. Strict, unlike triage's lenient question decode: an action is
    /// applied to the plan, so one that doesn't decode is refused with `why`, which ThreadRunner
    /// feeds back to the agent for its retry, rather than guessed at.
    public static func decode(_ data: Data) throws -> ThreadAnswer {
        let w: Wire
        do { w = try IntakeJSON.decoder.decode(Wire.self, from: data) }
        catch { throw Malformed(why: "not a thread answer: \(error)") }
        return ThreadAnswer(reply: w.reply, decision: w.decision ?? "", actions: w.actions ?? [])
    }
}
