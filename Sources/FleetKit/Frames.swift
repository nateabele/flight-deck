import Foundation

/// Why a snapshot arrived. A client that asked to resume and got a snapshot instead needs
/// to know it lost history, because that is the moment any local "since you were away"
/// affordance becomes a lie.
public enum SnapshotReason: String, Codable, Equatable, Sendable {
    /// The client asked for everything (`lastSeq == 0`).
    case initial
    /// The client asked to resume from before the ring's floor.
    case seqTooOld
}

/// Something the client asks the Mac to do.
///
/// `ack` means *dispatched*, not done — see §4. Typing into a pty has no delivery
/// confirmation, so the observable effect always arrives separately as a northbound event.
/// One rule for both agents beats commands whose meaning depends on which agent is behind
/// them.
public enum FleetCommand: Codable, Equatable, Sendable {
    case markRead(id: UUID)
    case markUnread(id: UUID)

    /// Type `text` into tab `id`'s live agent and submit it.
    ///
    /// **A `cmd` and not a `req`, and `FleetRequest`'s own doc comment draws the line.** A
    /// request asks the Mac to *tell* the client something and its whole point is the data
    /// carried back; a command asks the Mac to *do* something, and `ack` means dispatched,
    /// not done — a rule §4 states because typing into a pty has no delivery confirmation.
    /// This is the operation that rule was written for. Its observable effect arrives
    /// separately, as the `.userTurn` the agent writes into its own transcript and the phone
    /// reads back over the history channel.
    ///
    /// Making it a request would mean inventing a second reply payload beside `TimelinePage`,
    /// widening `ServerFrame.page`, and retyping `FleetConnector.pending` — a change across a
    /// shipped channel to carry a boolean the transcript settles anyway. What made a request
    /// tempting is that a `cmd` told the caller nothing; that is closed instead by
    /// `FleetConnector.send(_:then:)`, which correlates the `ack` on the same `cid`.
    ///
    /// `token` is the client's own idempotency key, minted once per composed message. It is
    /// the entire answer to "what if the phone retries" — see `SessionStore.submitPrompt`,
    /// which dedupes on it and acks a repeat without queueing anything.
    case prompt(id: UUID, token: UUID, text: String)

    enum CodingKeys: String, CodingKey { case op, id, token, text }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
        case prompt = "session.prompt"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markRead(let id):
            try c.encode(Op.markRead, forKey: .op)
            try c.encode(id, forKey: .id)
        case .markUnread(let id):
            try c.encode(Op.markUnread, forKey: .op)
            try c.encode(id, forKey: .id)
        case .prompt(let id, let token, let text):
            try c.encode(Op.prompt, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(token, forKey: .token)
            try c.encode(text, forKey: .text)
        }
    }

    /// `op` is read BEFORE `id`, where the two-case version read `id` first. That mattered
    /// not at all while every case had the same one field and matters now: a prompt missing
    /// its `token` must be refused as the *prompt* it claimed to be.
    ///
    /// **`text` is decoded as an ordinary `String` and is never judged here.** An unknown
    /// `op` throws — the phone → Mac direction rule `FleetRequest` states, because a command
    /// that cannot be understood cannot be executed. But a *length* or *content* refusal must
    /// not throw, and the reason is `FleetSocketServer.onUndecodable`: it salvages
    /// `t == "req"` and nothing else, deliberately, so a `cmd` this build cannot parse ends
    /// the socket. A phone that pasted a control character would lose its fleet connection,
    /// reconnect, and — with the text still sitting in its composer — be one tap from doing it
    /// again. So hostile text decodes cleanly and `SessionStore.submitPrompt` refuses it with
    /// an `err` code the phone can render into a sentence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .markRead:
            self = .markRead(id: try c.decode(UUID.self, forKey: .id))
        case .markUnread:
            self = .markUnread(id: try c.decode(UUID.self, forKey: .id))
        case .prompt:
            self = .prompt(
                id: try c.decode(UUID.self, forKey: .id),
                token: try c.decode(UUID.self, forKey: .token),
                text: try c.decode(String.self, forKey: .text)
            )
        }
    }
}

/// Client → Mac.
public enum ClientFrame: Codable, Equatable, Sendable {
    /// The first frame on every socket. TLS-PSK has already established *who* this is, so
    /// this is a resume point rather than a credential. `0` means "I have nothing".
    ///
    /// `device` is what the client *calls itself* — the Mac has no other way to learn it, so
    /// without this a paired phone can only ever be listed under a placeholder. It is a
    /// claim, not a credential: identity is the slot the handshake proved, and a client is
    /// free to send nothing at all, which is what `nil` means.
    case hello(lastSeq: Int, device: String?)
    case cmd(cid: Int, FleetCommand)
    /// Ask, rather than tell. See `FleetRequest` for why this is not a `cmd`.
    case req(cid: Int, FleetRequest)

    enum CodingKeys: String, CodingKey { case t, lastSeq, device, cid }

    private enum Tag: String, Codable { case hello, cmd, req }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let lastSeq, let device):
            try c.encode(Tag.hello, forKey: .t)
            try c.encode(lastSeq, forKey: .lastSeq)
            // `encodeIfPresent`, so a client with no name to claim emits the same two-key
            // frame it always did rather than an explicit `"device":null`.
            try c.encodeIfPresent(device, forKey: .device)
        case .cmd(let cid, let command):
            try c.encode(Tag.cmd, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object rather than nested under an "op" key, so a
            // command reads as one line in a dump. Two keyed containers over one encoder
            // merge into a single JSON object.
            try command.encode(to: encoder)
        case .req(let cid, let request):
            try c.encode(Tag.req, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object, exactly as `cmd` flattens its command: two
            // keyed containers over one encoder merge into a single JSON object, and one
            // request reading as one line is what makes a packet dump usable.
            try request.encode(to: encoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:
            // `decodeIfPresent`, not `decode`: a phone built before `device` existed sends a
            // `hello` without it, and that frame must still attach rather than throw — the
            // Mac would otherwise stop talking to every already-paired device on upgrade.
            self = .hello(lastSeq: try c.decode(Int.self, forKey: .lastSeq),
                          device: try c.decodeIfPresent(String.self, forKey: .device))
        case .cmd:
            self = .cmd(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetCommand(from: decoder))
        case .req:
            self = .req(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetRequest(from: decoder))
        }
    }
}

/// Mac → client. Northbound frames are sequenced; replies to commands are correlated.
public enum ServerFrame: Codable, Equatable, Sendable {
    case snapshot(seq: Int, fleet: FleetSnapshot, reason: SnapshotReason)
    case event(seq: Int, FleetEvent)
    case ack(cid: Int)
    case err(cid: Int, code: String)
    /// The reply to `ClientFrame.req`. Correlated by `cid` and deliberately **not**
    /// sequenced: a history fetch is not fleet state, and giving it a `seq` would let a
    /// client paging back through an hour of transcript move the resume point it hands the
    /// Mac on its next `hello`.
    case page(cid: Int, TimelinePage)

    enum CodingKeys: String, CodingKey { case t, seq, fleet, reason, cid, code, page }

    private enum Tag: String, Codable { case snapshot, ack, err, page }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let seq, let fleet, let reason):
            try c.encode(Tag.snapshot, forKey: .t)
            try c.encode(seq, forKey: .seq)
            try c.encode(fleet, forKey: .fleet)
            try c.encode(reason, forKey: .reason)
        case .event(let seq, let event):
            try c.encode(seq, forKey: .seq)
            // The event supplies its own `t`; the frame adds only the sequence. One flat
            // object per change is what makes a dump readable.
            try event.encode(to: encoder)
        case .ack(let cid):
            try c.encode(Tag.ack, forKey: .t)
            try c.encode(cid, forKey: .cid)
        case .err(let cid, let code):
            try c.encode(Tag.err, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(code, forKey: .code)
        case .page(let cid, let page):
            try c.encode(Tag.page, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(page, forKey: .page)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try the frame's own tags first; anything else is an event's tag, which is why
        // the two namespaces must never collide. `FleetEventTag`'s values are all dotted
        // and these four are not, which keeps that a property rather than a promise.
        if let tag = try? c.decode(Tag.self, forKey: .t) {
            switch tag {
            case .snapshot:
                self = .snapshot(seq: try c.decode(Int.self, forKey: .seq),
                                 fleet: try c.decode(FleetSnapshot.self, forKey: .fleet),
                                 reason: try c.decode(SnapshotReason.self, forKey: .reason))
            case .ack:
                self = .ack(cid: try c.decode(Int.self, forKey: .cid))
            case .err:
                self = .err(cid: try c.decode(Int.self, forKey: .cid),
                            code: try c.decode(String.self, forKey: .code))
            case .page:
                self = .page(cid: try c.decode(Int.self, forKey: .cid),
                             try c.decode(TimelinePage.self, forKey: .page))
            }
            return
        }
        self = .event(seq: try c.decode(Int.self, forKey: .seq),
                      try FleetEvent(from: decoder))
    }
}
