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

    enum CodingKeys: String, CodingKey { case op, id }

    private enum Op: String, Codable {
        case markRead = "session.markRead"
        case markUnread = "session.markUnread"
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
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        switch try c.decode(Op.self, forKey: .op) {
        case .markRead: self = .markRead(id: id)
        case .markUnread: self = .markUnread(id: id)
        }
    }
}

/// Client → Mac.
public enum ClientFrame: Codable, Equatable, Sendable {
    /// The first frame on every socket. TLS-PSK has already established *who* this is, so
    /// this is a resume point rather than a credential. `0` means "I have nothing".
    case hello(lastSeq: Int)
    case cmd(cid: Int, FleetCommand)

    enum CodingKeys: String, CodingKey { case t, lastSeq, cid }

    private enum Tag: String, Codable { case hello, cmd }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let lastSeq):
            try c.encode(Tag.hello, forKey: .t)
            try c.encode(lastSeq, forKey: .lastSeq)
        case .cmd(let cid, let command):
            try c.encode(Tag.cmd, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object rather than nested under an "op" key, so a
            // command reads as one line in a dump. Two keyed containers over one encoder
            // merge into a single JSON object.
            try command.encode(to: encoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:
            self = .hello(lastSeq: try c.decode(Int.self, forKey: .lastSeq))
        case .cmd:
            self = .cmd(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetCommand(from: decoder))
        }
    }
}

/// Mac → client. Northbound frames are sequenced; replies to commands are correlated.
public enum ServerFrame: Codable, Equatable, Sendable {
    case snapshot(seq: Int, fleet: FleetSnapshot, reason: SnapshotReason)
    case event(seq: Int, FleetEvent)
    case ack(cid: Int)
    case err(cid: Int, code: String)

    enum CodingKeys: String, CodingKey { case t, seq, fleet, reason, cid, code }

    private enum Tag: String, Codable { case snapshot, ack, err }

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
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Try the frame's own tags first; anything else is an event's tag, which is why
        // the two namespaces must never collide. `FleetEventTag`'s values are all dotted
        // and these three are not, which keeps that a property rather than a promise.
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
            }
            return
        }
        self = .event(seq: try c.decode(Int.self, forKey: .seq),
                      try FleetEvent(from: decoder))
    }
}
