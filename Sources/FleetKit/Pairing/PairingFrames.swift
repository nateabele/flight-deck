import Foundation

/// Why the Mac stopped. Sent in the clear, so it says only what the phone needs to choose its
/// next screen — never how close a guess was.
enum PairingRejection: String, Codable, Equatable, Sendable {
    /// The confirmation did not verify. From the Mac's side that is indistinguishable from a
    /// typo, and it costs one of three attempts.
    case badCode
    /// This window's three attempts are gone. A different message from `badCode` because it
    /// sends the user somewhere different: back to the Mac to arm again, not back to the
    /// keyboard.
    case attemptsExhausted
    /// The frame did not make sense at all — a message that is not a curve point, a
    /// confirmation before a PAKE. Not a code guess, so it costs no attempt.
    case malformed
}

/// Phone → Mac, on the pairing channel only.
///
/// **Internal, and that is invariant 3 (spec §6) expressed as visibility.** This vocabulary
/// contains no `hello` and no `cmd`, and no code outside FleetKit can construct any pairing
/// frame at all — so "a bootstrap connection must never reach `SessionStore`" is a property of
/// what can be said on this socket rather than a check somebody has to remember to write.
enum PairingClientFrame: Codable, Equatable, Sendable {
    /// The phone's SPAKE2 message, 32 bytes. First frame on the connection.
    case pake(msg: Data)
    /// `PairingSecrets.initiatorConfirmation`, 32 bytes. Only frame after the Mac's `pake`.
    case confirm(mac: Data)

    enum CodingKeys: String, CodingKey { case t, msg, mac }

    private enum Tag: String, Codable { case pake, confirm }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pake(let msg):
            try c.encode(Tag.pake, forKey: .t)
            try c.encode(msg, forKey: .msg)
        case .confirm(let mac):
            try c.encode(Tag.confirm, forKey: .t)
            try c.encode(mac, forKey: .mac)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .pake: self = .pake(msg: try c.decode(Data.self, forKey: .msg))
        case .confirm: self = .confirm(mac: try c.decode(Data.self, forKey: .mac))
        }
    }
}

/// Mac → phone, on the pairing channel only.
enum PairingServerFrame: Codable, Equatable, Sendable {
    /// The Mac's SPAKE2 message, 32 bytes.
    case pake(msg: Data)
    /// `PairingSecrets.responderConfirmation` plus the sealed device key. Both in one frame
    /// because they are one statement — "here is proof I knew the code, and here is what that
    /// proof was for" — and a phone that received the box without the proof would have to
    /// decide what to do with a key from a Mac that had proved nothing.
    case sealed(mac: Data, box: Data)
    case reject(PairingRejection)

    enum CodingKeys: String, CodingKey { case t, msg, mac, box, reason }

    private enum Tag: String, Codable { case pake, sealed, reject }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pake(let msg):
            try c.encode(Tag.pake, forKey: .t)
            try c.encode(msg, forKey: .msg)
        case .sealed(let mac, let box):
            try c.encode(Tag.sealed, forKey: .t)
            try c.encode(mac, forKey: .mac)
            try c.encode(box, forKey: .box)
        case .reject(let reason):
            try c.encode(Tag.reject, forKey: .t)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .pake:
            self = .pake(msg: try c.decode(Data.self, forKey: .msg))
        case .sealed:
            self = .sealed(
                mac: try c.decode(Data.self, forKey: .mac),
                box: try c.decode(Data.self, forKey: .box)
            )
        case .reject:
            self = .reject(try c.decode(PairingRejection.self, forKey: .reason))
        }
    }
}
