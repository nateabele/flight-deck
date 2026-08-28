import Foundation

/// One thing that happened in a conversation, in the single vocabulary both agents map onto.
///
/// On a channel separate from `AgentEvent` deliberately (spec §6): `AgentEvent` is four cases
/// sized for a sidebar row, and widening it to carry conversation content would drag desktop
/// code through a change it does not need.
///
/// `Hashable` rather than merely `Equatable`, on this and on every type it holds, because the
/// phone pushes an item onto a `NavigationPath` — `NavigationLink(value:)` takes a `Hashable`
/// value and `navigationDestination(for:)` matches on its type. Synthesized, and safe to
/// synthesize: every stored property is a `String`, `Int`, `Bool` or an enum over `String`, so
/// the hash is the value's own content and two items that compare equal cannot hash apart.
public struct TimelineItem: Identifiable, Codable, Hashable, Sendable {
    /// What this row is. `unknown` is not a case any mapper emits — it is what a build
    /// decodes when a newer Mac sends a kind it has not heard of.
    ///
    /// Decoding an unknown value rather than throwing is load-bearing, not lenient:
    /// `FleetSocket.receive` ends the connection on a frame it cannot parse, so a strict
    /// enum here would mean a Mac shipping one new kind silently and permanently
    /// disconnecting every phone built before it. Same rule, same reason, as
    /// `WireSession.agent` being a `String`.
    public enum Kind: String, Codable, Hashable, Sendable {
        case userTurn, assistantText, thinking, toolCall, toolResult, prompt
        /// The harness talking, in a record the agent files under the user's name.
        ///
        /// Claude Code delivers task notifications, `system-reminder`s, slash-command echoes
        /// and `!` shell output as `user` records whose content is wrapper markup. Only some
        /// carry `isMeta` — of 132 task notifications in one real transcript, not one did —
        /// so the record-level flags this mapper already honours do not catch them, and they
        /// rendered as the user's own words under a "You" heading. Attributing a machine's
        /// output to a person is the same harm `isMeta` and `isCompactSummary` are filtered
        /// for; this is the third form of it and the only one with no flag to key on.
        ///
        /// A distinct kind rather than a silent drop, because the content is worth reading —
        /// it just is not the user saying it.
        case systemNotice
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// Whether the agent is still adding to this item.
    ///
    /// **Nothing in this codebase emits `.streaming`, and that is a finding rather than an
    /// omission.** Both agents are observed from the files they write, and neither writes
    /// token deltas — a survey of 494 codex rollouts on the build machine found zero
    /// `*delta*` records, and claude's transcript lands one whole record at a time. The case
    /// ships anyway because a `Status` added after phones shipped is a protocol break, and
    /// slice 2's prompt bridging (spec §9) may want it.
    public enum Status: String, Codable, Hashable, Sendable {
        case streaming, complete
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    /// The renderable content. One shape for six kinds, because the alternative — an
    /// associated-value enum — would need a hand-written codec per case and gives a client
    /// nothing it does not get from optional fields being absent.
    public struct Body: Codable, Hashable, Sendable {
        /// The full text, up to `TimelineLimits.maxItemBytes`. For a `.toolCall` this is the
        /// tool's input, pretty-printed; for a `.toolResult` it is the output.
        ///
        /// **Parse it only where failing to is harmless.** A `.toolCall`'s text is
        /// pretty-printed JSON, and the Mac cuts an oversized body at the byte cap wherever
        /// that lands — mid-object, mid-string, mid-escape. So `truncatedBytes > 0` on a tool
        /// call means the JSON is structurally incomplete *by design*, and a client that
        /// *depends* on decoding it shows nothing for exactly the largest tool inputs, which
        /// are the ones worth reading.
        ///
        /// The phone's detail screen does try: `JSONValue.document(from:)` over this text,
        /// falling back to the plain text on any failure, which is what a truncated body
        /// always produces. That is the shape any reader of this field must take — attempt,
        /// expect failure, render the text — and `truncatedBytes` is shown beside it either
        /// way. What must never appear here is a parse error where the content should be.
        public var text: String
        /// A one-line preview for a list row. Set only where `text` is unfit for one — a
        /// tool call's input is JSON, and `{` is not a useful row. Nil means "use the first
        /// line of `text`", which is right for every prose kind.
        public var summary: String?
        /// The tool's name, for `.toolCall` and `.toolResult`. Nil elsewhere.
        public var tool: String?
        /// The agent's own id for the call this row is, or answers — claude's `tool_use_id`,
        /// codex's `call_id`. This is what pairs a result with its call, and it is
        /// deliberately NOT `id`: the two agents' id spaces have nothing in common, while
        /// `id` has one rule that works for both.
        public var callID: String?
        /// Bytes dropped from `text` at the per-item cap. `0` means whole. A client that
        /// hides this is claiming a truncated file read is a complete one.
        public var truncatedBytes: Int
        /// The source record said this result was an error.
        public var isError: Bool

        public init(
            text: String, summary: String? = nil, tool: String? = nil,
            callID: String? = nil, truncatedBytes: Int = 0, isError: Bool = false
        ) {
            self.text = text
            self.summary = summary
            self.tool = tool
            self.callID = callID
            self.truncatedBytes = truncatedBytes
            self.isError = isError
        }

        enum CodingKeys: String, CodingKey {
            case text, summary, tool, callID, truncatedBytes, isError
        }

        /// Hand-written so the four rarely-set fields are ABSENT rather than null, and so
        /// `truncatedBytes: 0` / `isError: false` cost nothing. A page carries up to 200
        /// bodies; four explicit nulls each is real bytes on a cellular link.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(summary, forKey: .summary)
            try c.encodeIfPresent(tool, forKey: .tool)
            try c.encodeIfPresent(callID, forKey: .callID)
            if truncatedBytes != 0 { try c.encode(truncatedBytes, forKey: .truncatedBytes) }
            if isError { try c.encode(isError, forKey: .isError) }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            tool = try c.decodeIfPresent(String.self, forKey: .tool)
            callID = try c.decodeIfPresent(String.self, forKey: .callID)
            truncatedBytes = try c.decodeIfPresent(Int.self, forKey: .truncatedBytes) ?? 0
            isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        }
    }

    /// Stable across fetches, and unique within one session's transcript.
    ///
    /// `"<byteOffset>#<blockIndex>"` — the offset of the record's line in the file, and the
    /// index of the block within it. Deliberately NOT the agent's own record id: claude's
    /// records carry a `uuid` and codex's `event_msg` records carry nothing at all, so a
    /// natural-id rule would need a per-agent fallback and would still not be uniform. An
    /// append-only file gives every line exactly one offset for its whole life, which is all
    /// "stable" has to mean here.
    ///
    /// The one case that breaks it is a transcript REPLACED rather than appended to, which
    /// shifts every offset. `TimelinePage.reset` is how a client is told that happened; see
    /// `TranscriptPager`.
    public let id: String
    public var kind: Kind
    public var status: Status
    public var body: Body
    /// The record's own timestamp, verbatim, exactly as the agent wrote it (ISO-8601).
    /// Carried as a `String` and never parsed on the Mac: both agents already write a valid
    /// ISO-8601 instant, a `Date` would drag `JSONEncoder`'s date strategy into the wire
    /// contract, and the client is the only side that formats it anyway.
    public var at: String?

    public init(
        id: String, kind: Kind, status: Status, body: Body, at: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.body = body
        self.at = at
    }

    /// The one id rule, in one place, so the two mappers cannot drift.
    public static func identifier(offset: Int, index: Int) -> String { "\(offset)#\(index)" }
}
