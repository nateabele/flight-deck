import Foundation

/// Where in a transcript a client wants to read from.
///
/// Cursors are **byte offsets into the source file, always at a line boundary**, and they are
/// opaque to the client: it never computes one, only echoes back a `start` or an `end` it was
/// given. That is what keeps the file format out of the protocol.
public enum TimelineAnchor: Equatable, Sendable {
    /// The newest records. What opening a session asks for.
    case latest
    /// The records ending immediately before this offset. What scrolling up asks for.
    case before(Int)
    /// Whatever has been appended since this offset. What a screen already open asks for.
    case after(Int)
    /// The records either side of this offset. What opening a search hit asks for.
    case around(Int)

    /// The wire spelling. A table rather than a derivation, for the same reason
    /// `FleetEventTag` is one: a case rename must not silently become a protocol break.
    var name: String {
        switch self {
        case .latest: return "latest"
        case .before: return "before"
        case .after: return "after"
        case .around: return "around"
        }
    }

    var cursor: Int? {
        switch self {
        case .latest: return nil
        case .before(let cursor), .after(let cursor), .around(let cursor): return cursor
        }
    }

    /// Returns nil for a name this build has never heard of, and for a name that needs a
    /// cursor and was sent without one.
    ///
    /// **This is the one place in the timeline vocabulary that deliberately does NOT take
    /// `TimelineItem.Kind`'s decode-unknown-rather-than-throw route, and the difference is
    /// direction.** `Kind` travels Mac → phone and is *rendered*: an unrecognised kind has a
    /// safe fallback, and throwing would let one new Mac disconnect every phone in the field.
    /// An anchor travels phone → Mac and is *executed*: there is no fallback that is not a
    /// wrong answer. Silently reading `"around"` as `.latest` would serve the opposite end of
    /// the file from the one that was asked for, which is the same class of quiet lie
    /// `TimelinePage.reset` exists to prevent. `FleetCommand` refuses an unknown `op` for the
    /// same reason and in the same direction.
    ///
    /// The cost is real and is named here rather than hidden: `FleetSocket.receive` ends the
    /// connection on a frame it cannot parse, so a future phone that invented an anchor once
    /// lost its whole fleet socket over a history fetch — and, because a reconnect's first
    /// frame resets `FleetConnector`'s backoff and an open screen re-issues the same fetch,
    /// lost it again every second, forever. `FleetSocketServer`'s `onUndecodable` hook pays
    /// that cost instead: a `req` this build cannot parse is refused `err`/`unsupported` on
    /// its own `cid` and the loop reads on. It needs no `FleetRequest` case for "a request I
    /// do not understand", which is the reason this was left open — the refusal is made from
    /// the raw bytes, before there is a `FleetRequest` at all.
    init?(name: String, cursor: Int?) {
        switch (name, cursor) {
        case ("latest", _): self = .latest
        case ("before", let cursor?): self = .before(cursor)
        case ("after", let cursor?): self = .after(cursor)
        case ("around", let cursor?): self = .around(cursor)
        default: return nil
        }
    }
}

/// One page of one session's conversation.
public struct TimelinePage: Codable, Equatable, Sendable {
    /// The tab this is about. Echoed back so a client with two fetches in flight can tell
    /// them apart without holding the request beside the `cid`.
    public var session: UUID
    /// In file order, oldest first, for every anchor — including `.before`, where the client
    /// asked for them backwards. Reversing at the reader means every client renders the same
    /// way and nobody has to remember which anchor produced which order.
    public var items: [TimelineItem]
    /// The offset of the first included record's line. Feed it back as `.before(start)` to
    /// page further up.
    public var start: Int
    /// The offset just past the last included record's line. Feed it back as `.after(end)` to
    /// pick up whatever has been appended since.
    public var end: Int
    /// Whether anything precedes `start`. False means the top of the transcript.
    public var hasMore: Bool
    /// The transcript this cursor came from is gone — it shrank, or was replaced. The client
    /// must **discard what it holds** and re-fetch `.latest`; item ids are byte offsets, so
    /// a replaced file makes every held id name a different record.
    ///
    /// The explicit signal is required, not an optimisation, for the same reason §4's
    /// re-snapshot is: silently serving from wherever the file happens to be now is how a
    /// phone ends up confidently displaying a conversation that no longer exists.
    public var reset: Bool

    public init(
        session: UUID, items: [TimelineItem], start: Int, end: Int,
        hasMore: Bool, reset: Bool
    ) {
        self.session = session
        self.items = items
        self.start = start
        self.end = end
        self.hasMore = hasMore
        self.reset = reset
    }

    enum CodingKeys: String, CodingKey { case session, items, start, end, hasMore, reset }

    /// Hand-written for the same reason `TimelineItem.Body`'s is: the two flags are false on
    /// the ordinary page and absent costs less than `false` on a cellular link.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session, forKey: .session)
        try c.encode(items, forKey: .items)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        if hasMore { try c.encode(hasMore, forKey: .hasMore) }
        if reset { try c.encode(reset, forKey: .reset) }
    }

    /// This one travels Mac → phone, so it is the direction where a peer can send something
    /// this build has never heard of. Two properties keep that survivable and both are
    /// deliberate: a keyed container ignores keys it has no case for, so a field added to a
    /// later page decodes here as though it were absent; and `items` carries its unknown
    /// values inside `TimelineItem.Kind`/`.Status`, which decode to `.unknown` rather than
    /// throwing. A page from a newer Mac therefore renders with the parts this build
    /// understands instead of ending the connection.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(UUID.self, forKey: .session)
        items = try c.decode([TimelineItem].self, forKey: .items)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        reset = try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false
    }
}

/// Something the client asks the Mac to **tell** it.
///
/// Separate from `FleetCommand`, which asks the Mac to **do** something. The distinction is
/// load-bearing rather than tidy: a command's reply is `ack`, and `ack` means *dispatched,
/// not done* (spec §4) because typing into a pty has no delivery confirmation. That is the
/// right contract for `markRead` and a wrong one for a page, whose whole point is the data it
/// carries back. Two verbs, two reply shapes.
public enum FleetRequest: Codable, Equatable, Sendable {
    /// `limit` counts source **records**, not items — one record can carry several. Clamped
    /// to `TimelineLimits.maxLimit` by the reader rather than refused here.
    case timeline(session: UUID, anchor: TimelineAnchor, limit: Int)

    /// The rows of project `project`'s New Session menu.
    ///
    /// **A request rather than snapshot state**, for the reason `WireNewSessionOptions`
    /// records: the rows come from preferences, preferences emit no fleet events, and a
    /// snapshot that changes with nothing recorded is what `FleetReplicator`'s drift check
    /// exists to catch. Same shape as `timeline` — ask, get an answer on the `cid`, keep it
    /// out of the log.
    case newSessionOptions(project: UUID)

    /// Every address this Mac can currently be reached on, best-first.
    ///
    /// **A request rather than snapshot state**, for the reason `newSessionOptions` records:
    /// addresses come from the network, the network emits no fleet events, and a snapshot
    /// that changes with nothing recorded is what `FleetReplicator`'s drift check exists to
    /// catch. It is also what the pairing code cannot do on its own — a QR is scanned once
    /// and its addresses are true only on the day it was drawn.
    case macEndpoints

    enum CodingKeys: String, CodingKey { case op, session, anchor, cursor, limit, project }

    private enum Op: String, Codable {
        case timeline = "timeline.page"
        case newSessionOptions = "session.newOptions"
        case macEndpoints = "mac.endpoints"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timeline(let session, let anchor, let limit):
            try c.encode(Op.timeline, forKey: .op)
            try c.encode(session, forKey: .session)
            try c.encode(anchor.name, forKey: .anchor)
            // `encodeIfPresent`: `.latest` genuinely has no cursor, and an explicit null
            // would invite a reader to treat it as offset 0 — the opposite end of the file.
            try c.encodeIfPresent(anchor.cursor, forKey: .cursor)
            try c.encode(limit, forKey: .limit)
        case .newSessionOptions(let project):
            try c.encode(Op.newSessionOptions, forKey: .op)
            try c.encode(project, forKey: .project)
        case .macEndpoints:
            try c.encode(Op.macEndpoints, forKey: .op)
        }
    }

    /// An unrecognised `op` throws, like `FleetCommand`'s and unlike `TimelineItem.Kind`'s.
    /// See `TimelineAnchor.init(name:cursor:)` for the direction argument: a request that
    /// cannot be understood cannot be answered, and guessing at it answers the wrong question.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .timeline:
            let name = try c.decode(String.self, forKey: .anchor)
            let cursor = try c.decodeIfPresent(Int.self, forKey: .cursor)
            guard let anchor = TimelineAnchor(name: name, cursor: cursor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .anchor, in: c,
                    debugDescription: "unknown anchor \"\(name)\""
                        + (cursor == nil ? " (or a cursor was required and absent)" : "")
                )
            }
            self = .timeline(
                session: try c.decode(UUID.self, forKey: .session),
                anchor: anchor,
                limit: try c.decode(Int.self, forKey: .limit)
            )
        case .newSessionOptions:
            self = .newSessionOptions(project: try c.decode(UUID.self, forKey: .project))
        case .macEndpoints:
            self = .macEndpoints
        }
    }
}

/// Why a request did not produce a page.
public enum FleetRequestError: Error, Equatable, Sendable {
    /// The socket went away before the reply arrived. A client that does not surface this
    /// spins forever on a fetch that will never land.
    case disconnected
    /// The Mac answered `err`. Codes this plan produces: `unknown_session` (no such tab),
    /// `no_transcript` (the tab's agent reports no transcript file — a codex thread whose
    /// `thread/start` never returned a path), `unreadable`, `stopped` (the service is gone).
    /// Two more come from the socket rather than the reader and are not this plan's to
    /// produce: `unhandled`, from a Mac whose `onRequest` is not wired at all, and
    /// `unsupported`, from one that could not parse the request. A client must treat any
    /// unrecognised code as "no page".
    ///
    /// **`unreadable` is showable and retryable, and it covers two states on purpose**: a path
    /// that is not there yet — the ordinary state of a claude tab before its first turn — and
    /// a transcript that exists and holds no line boundary to page from, which is what a file
    /// mid-first-record looks like. Render it as "no history yet" and let the next fetch try
    /// again. It deliberately is NOT an empty page: that answer is indistinguishable from a
    /// genuinely empty conversation, so it would have a phone state permanently and falsely
    /// that a conversation with history in it is empty. See `TimelineReadFailure` on the Mac.
    ///
    /// A `String` rather than an enum, and that is the decode-unknown rule in this direction:
    /// `err` travels Mac → phone, so a newer Mac inventing a code must leave an older phone
    /// showing "the Mac said no" rather than failing to parse the frame at all. Same reason
    /// `WireSession.agent` is a `String`.
    ///
    /// The answer channel adds four, all refusals a person can act on: `prompt_changed` (your
    /// Mac has moved on — what is up now is not what you tapped), `not_waiting` (nothing is
    /// blocked on this tab), `unreadable_screen` (the terminal could not be read, or another
    /// injection is resolving — try again in a moment), and `unanswerable` (a shape this Mac
    /// will not drive; see `PromptQuestion.unanswerable`). `unsupported_agent` and
    /// `unknown_session` keep the meanings `FleetCommand.prompt` gave them.
    case server(code: String)
}
