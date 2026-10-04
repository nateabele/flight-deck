import Foundation

// Wire table (JSON, one frame per message; keys are sorted on encode):
//
//   controller -> host
//     hello     {"t":"hello","v":{major,minor},"caps":[string],"name":string}
//     req       {"t":"req","id":int,"req":{"op":string}}
//   host -> controller
//     helloAck  {"t":"helloAck","v":{major,minor},"caps":[string],"name":string}
//     refused   {"t":"refused","reason":{"kind":"majorVersionMismatch","host":{major,minor}}}
//     reply     {"t":"reply","id":int,"rep":{"op":string,"info":{...}}}
//     err       {"t":"err","id":int,"code":string,"message":string}
//
// `v` is an object, not a "1.0" string, so no peer ever parses a version out of text and a
// minor of 10 cannot sort before 9. Unknown capability strings are dropped on decode; an
// unknown frame tag or `op` throws.
//
// Hand-rolled `t`-tagged Codable, as in FleetKit's PairingFrames: the tag strings are the wire
// contract between a Linux hostd and a Mac controller built months apart, so they are spelled
// out here rather than derived from case names that a refactor could silently rename.

/// `major` is a compatibility break, `minor` an additive change. A host refuses a controller
/// whose major differs; a differing minor is tolerated.
public struct ProtocolVersion: Codable, Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let current = ProtocolVersion(major: 1, minor: 0)

    // Explicit raw values: a Swift rename must not change the wire.
    enum CodingKeys: String, CodingKey {
        case major = "major"
        case minor = "minor"
    }

    public static func < (a: ProtocolVersion, b: ProtocolVersion) -> Bool {
        (a.major, a.minor) < (b.major, b.minor)
    }
}

public enum HostCapability: String, Codable, Sendable {
    case hostInfo = "host.info"
}

extension KeyedDecodingContainer {
    /// Capabilities are the additive half of version skew: a newer peer may advertise one this
    /// build has never heard of. Decoding straight into the closed enum would throw and kill
    /// the whole hello, so read strings and drop the unknown ones.
    fileprivate func decodeCapabilities(forKey key: Key) throws -> [HostCapability] {
        try decode([String].self, forKey: key).compactMap(HostCapability.init(rawValue:))
    }
}

/// Controller → host.
public enum HostClientFrame: Codable, Sendable, Equatable {
    case hello(protocolVersion: ProtocolVersion, capabilities: [HostCapability], controllerName: String)
    case request(id: Int, HostRequest)

    enum CodingKeys: String, CodingKey { case t, v, caps, name, id, req }

    private enum Tag: String, Codable { case hello, req }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v, let caps, let name):
            try c.encode(Tag.hello, forKey: .t)
            try c.encode(v, forKey: .v)
            try c.encode(caps, forKey: .caps)
            try c.encode(name, forKey: .name)
        case .request(let id, let req):
            try c.encode(Tag.req, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(req, forKey: .req)
        }
    }

    /// An unknown tag throws (`Tag` fails to decode) rather than trapping, so a newer peer's
    /// frame costs the receiver one error, not the connection.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .hello:
            self = .hello(
                protocolVersion: try c.decode(ProtocolVersion.self, forKey: .v),
                capabilities: try c.decodeCapabilities(forKey: .caps),
                controllerName: try c.decode(String.self, forKey: .name)
            )
        case .req:
            self = .request(id: try c.decode(Int.self, forKey: .id),
                            try c.decode(HostRequest.self, forKey: .req))
        }
    }
}

/// `{"op":"host.info"}`. Keyed by `op` so later requests can add their own fields beside it.
public enum HostRequest: Codable, Sendable, Equatable {
    case hostInfo

    enum CodingKeys: String, CodingKey { case op }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostInfo: try c.encode(HostCapability.hostInfo, forKey: .op)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(HostCapability.self, forKey: .op) {
        case .hostInfo: self = .hostInfo
        }
    }
}

/// Host → controller.
public enum HostServerFrame: Codable, Sendable, Equatable {
    case helloAck(protocolVersion: ProtocolVersion, capabilities: [HostCapability], hostName: String)
    case refused(reason: HostRefusal)
    case reply(id: Int, HostReply)
    case error(id: Int, code: String, message: String)

    enum CodingKeys: String, CodingKey { case t, v, caps, name, reason, id, rep, code, message }

    private enum Tag: String, Codable { case helloAck, refused, reply, err }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .helloAck(let v, let caps, let name):
            try c.encode(Tag.helloAck, forKey: .t)
            try c.encode(v, forKey: .v)
            try c.encode(caps, forKey: .caps)
            try c.encode(name, forKey: .name)
        case .refused(let reason):
            try c.encode(Tag.refused, forKey: .t)
            try c.encode(reason, forKey: .reason)
        case .reply(let id, let rep):
            try c.encode(Tag.reply, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(rep, forKey: .rep)
        case .error(let id, let code, let message):
            try c.encode(Tag.err, forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .helloAck:
            self = .helloAck(
                protocolVersion: try c.decode(ProtocolVersion.self, forKey: .v),
                capabilities: try c.decodeCapabilities(forKey: .caps),
                hostName: try c.decode(String.self, forKey: .name)
            )
        case .refused:
            self = .refused(reason: try c.decode(HostRefusal.self, forKey: .reason))
        case .reply:
            self = .reply(id: try c.decode(Int.self, forKey: .id),
                          try c.decode(HostReply.self, forKey: .rep))
        case .err:
            self = .error(
                id: try c.decode(Int.self, forKey: .id),
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message)
            )
        }
    }
}

/// `{"op":"host.info","info":{…}}`; `op` echoes the request so a reply is self-describing.
public enum HostReply: Codable, Sendable, Equatable {
    case hostInfo(HostInfo)

    enum CodingKeys: String, CodingKey { case op, info }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hostInfo(let info):
            try c.encode(HostCapability.hostInfo, forKey: .op)
            try c.encode(info, forKey: .info)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(HostCapability.self, forKey: .op) {
        case .hostInfo: self = .hostInfo(try c.decode(HostInfo.self, forKey: .info))
        }
    }
}

/// Why a host closed the door on `hello`. Carries the host's own version so the controller can
/// tell the user which side needs upgrading.
public enum HostRefusal: Codable, Sendable, Equatable {
    case majorVersionMismatch(host: ProtocolVersion)

    enum CodingKeys: String, CodingKey { case kind, host }

    private enum Kind: String, Codable { case majorVersionMismatch }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .majorVersionMismatch(let host):
            try c.encode(Kind.majorVersionMismatch, forKey: .kind)
            try c.encode(host, forKey: .host)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .majorVersionMismatch:
            self = .majorVersionMismatch(host: try c.decode(ProtocolVersion.self, forKey: .host))
        }
    }
}

public enum HostWire {
    /// Sorted keys so the bytes are deterministic (pinned in tests); unescaped slashes so paths
    /// in later frames stay readable on the wire.
    public static func encode<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ t: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(t, from: Data(text.utf8))
    }
}
