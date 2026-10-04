import Foundation

// Admin wire (JSON, one frame per line over the user-only admin socket; keys sorted):
//
//   request  {"t":"status"} | {"t":"arm"} | {"t":"cancelArm"} | {"t":"ls"}
//            {"t":"revoke","slot":uuid}
//   reply    {"t":"status","paired":int,"armedUntil":date?,"listeningPort":int?,"hostName":string}
//            {"t":"armed","code":string,"expiresAt":date}
//            {"t":"controllers","controllers":[{"slot":uuid,"name":string,"pairedAt":date}]}
//            {"t":"ok"} | {"t":"failed","message":string}
//
// Dates are reference-date doubles (HostWire's default), nil optionals are omitted. Tags are
// spelled out for the same reason as HostWire's: a Linux `flightdeck-hostd pair` and a running
// hostd of another build must agree, and a case rename must not change the wire.

public enum AdminRequest: Codable, Sendable, Equatable {
    case status
    case arm
    case cancelArm
    case listControllers
    case revoke(slot: UUID)

    enum CodingKeys: String, CodingKey { case t, slot }

    private enum Tag: String, Codable { case status, arm, cancelArm, ls, revoke }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try c.encode(Tag.status, forKey: .t)
        case .arm: try c.encode(Tag.arm, forKey: .t)
        case .cancelArm: try c.encode(Tag.cancelArm, forKey: .t)
        case .listControllers: try c.encode(Tag.ls, forKey: .t)
        case .revoke(let slot):
            try c.encode(Tag.revoke, forKey: .t)
            try c.encode(slot, forKey: .slot)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .status: self = .status
        case .arm: self = .arm
        case .cancelArm: self = .cancelArm
        case .ls: self = .listControllers
        case .revoke: self = .revoke(slot: try c.decode(UUID.self, forKey: .slot))
        }
    }
}

public struct AdminController: Codable, Sendable, Equatable {
    public let slot: UUID
    public let name: String
    public let pairedAt: Date

    public init(slot: UUID, name: String, pairedAt: Date) {
        self.slot = slot
        self.name = name
        self.pairedAt = pairedAt
    }

    enum CodingKeys: String, CodingKey {
        case slot = "slot"
        case name = "name"
        case pairedAt = "pairedAt"
    }
}

public enum AdminReply: Codable, Sendable, Equatable {
    case status(paired: Int, armedUntil: Date?, listeningPort: Int?, hostName: String)
    /// `code` is `PairingCode.formatted`.
    case armed(code: String, expiresAt: Date)
    case controllers([AdminController])
    case ok
    case failed(String)

    enum CodingKeys: String, CodingKey {
        case t, paired, armedUntil, listeningPort, hostName, code, expiresAt, controllers, message
    }

    private enum Tag: String, Codable { case status, armed, controllers, ok, failed }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let paired, let until, let port, let name):
            try c.encode(Tag.status, forKey: .t)
            try c.encode(paired, forKey: .paired)
            try c.encodeIfPresent(until, forKey: .armedUntil)
            try c.encodeIfPresent(port, forKey: .listeningPort)
            try c.encode(name, forKey: .hostName)
        case .armed(let code, let expiresAt):
            try c.encode(Tag.armed, forKey: .t)
            try c.encode(code, forKey: .code)
            try c.encode(expiresAt, forKey: .expiresAt)
        case .controllers(let list):
            try c.encode(Tag.controllers, forKey: .t)
            try c.encode(list, forKey: .controllers)
        case .ok: try c.encode(Tag.ok, forKey: .t)
        case .failed(let message):
            try c.encode(Tag.failed, forKey: .t)
            try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .status:
            self = .status(paired: try c.decode(Int.self, forKey: .paired),
                           armedUntil: try c.decodeIfPresent(Date.self, forKey: .armedUntil),
                           listeningPort: try c.decodeIfPresent(Int.self, forKey: .listeningPort),
                           hostName: try c.decode(String.self, forKey: .hostName))
        case .armed:
            self = .armed(code: try c.decode(String.self, forKey: .code),
                          expiresAt: try c.decode(Date.self, forKey: .expiresAt))
        case .controllers: self = .controllers(try c.decode([AdminController].self, forKey: .controllers))
        case .ok: self = .ok
        case .failed: self = .failed(try c.decode(String.self, forKey: .message))
        }
    }
}
