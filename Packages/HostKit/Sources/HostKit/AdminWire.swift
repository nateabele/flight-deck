import Foundation

// Admin wire (JSON, one frame per line over the user-only admin socket; keys sorted):
//
//   request  {"t":"status"} | {"t":"arm"} | {"t":"cancelArm"} | {"t":"ls"}
//            {"t":"revoke","slot":uuid}
//            {"t":"enroll","payload":EnrollmentPayload}
//            {"t":"keepAwake"} | {"t":"setKeepAwake","on":bool}
//   reply    {"t":"status","paired":int,"armedUntil":date?,"listeningPort":int?,"hostName":string}
//            {"t":"armed","code":string,"expiresAt":date,"pairingPort":int?}
//            {"t":"controllers","controllers":[{"slot":uuid,"name":string,"pairedAt":date}]}
//            {"t":"keepAwake","enabled":bool,"holding":bool,"power":"ac"|"battery"|"unknown"}
//            {"t":"ok"} | {"t":"failed","message":string}
//
// `keepAwake`/`setKeepAwake` (both answered by the `keepAwake` reply) came after the first
// release: a hostd from before them answers `failed("bad request")`, and a Linux hostd, which
// has no display to keep on, answers `failed` with its reason.
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
    /// Adds the payload's controller to the running hostd's store. Through the admin socket,
    /// not by writing `controllers.json`, because `serve` reads that file once at start and
    /// would never see a key written behind its back.
    case enroll(EnrollmentPayload)
    /// Reads "keep this Mac awake while plugged in" and whether it is holding now.
    case keepAwake
    /// Sets it, persists it in the host's state root, and answers like `keepAwake`.
    case setKeepAwake(Bool)

    enum CodingKeys: String, CodingKey { case t, slot, payload, on }

    private enum Tag: String, Codable { case status, arm, cancelArm, ls, revoke, enroll, keepAwake, setKeepAwake }

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
        case .enroll(let payload):
            try c.encode(Tag.enroll, forKey: .t)
            try c.encode(payload, forKey: .payload)
        case .keepAwake: try c.encode(Tag.keepAwake, forKey: .t)
        case .setKeepAwake(let on):
            try c.encode(Tag.setKeepAwake, forKey: .t)
            try c.encode(on, forKey: .on)
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
        case .enroll: self = .enroll(try c.decode(EnrollmentPayload.self, forKey: .payload))
        case .keepAwake: self = .keepAwake
        case .setKeepAwake: self = .setKeepAwake(try c.decode(Bool.self, forKey: .on))
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
    /// `code` is `PairingCode.formatted`. `pairingPort` is the port the window's listener
    /// actually bound, so the host can show it when it is not the 47411 a controller assumes
    /// for a typed address. Optional, and omitted when nil, because it was added after the
    /// first release: an older peer's reply decodes as nil and an older decoder ignores the key.
    case armed(code: String, expiresAt: Date, pairingPort: Int? = nil)
    case controllers([AdminController])
    case keepAwake(KeepAwakeStatus)
    case ok
    case failed(String)

    enum CodingKeys: String, CodingKey {
        case t, paired, armedUntil, listeningPort, hostName, code, expiresAt, pairingPort, controllers, message
        case enabled, holding, power
    }

    private enum Tag: String, Codable { case status, armed, controllers, keepAwake, ok, failed }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let paired, let until, let port, let name):
            try c.encode(Tag.status, forKey: .t)
            try c.encode(paired, forKey: .paired)
            try c.encodeIfPresent(until, forKey: .armedUntil)
            try c.encodeIfPresent(port, forKey: .listeningPort)
            try c.encode(name, forKey: .hostName)
        case .armed(let code, let expiresAt, let pairingPort):
            try c.encode(Tag.armed, forKey: .t)
            try c.encode(code, forKey: .code)
            try c.encode(expiresAt, forKey: .expiresAt)
            try c.encodeIfPresent(pairingPort, forKey: .pairingPort)
        case .controllers(let list):
            try c.encode(Tag.controllers, forKey: .t)
            try c.encode(list, forKey: .controllers)
        case .keepAwake(let status):
            try c.encode(Tag.keepAwake, forKey: .t)
            try c.encode(status.enabled, forKey: .enabled)
            try c.encode(status.holding, forKey: .holding)
            try c.encode(status.power, forKey: .power)
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
                          expiresAt: try c.decode(Date.self, forKey: .expiresAt),
                          pairingPort: try c.decodeIfPresent(Int.self, forKey: .pairingPort))
        case .controllers: self = .controllers(try c.decode([AdminController].self, forKey: .controllers))
        case .keepAwake:
            self = .keepAwake(KeepAwakeStatus(enabled: try c.decode(Bool.self, forKey: .enabled),
                                              holding: try c.decode(Bool.self, forKey: .holding),
                                              power: try c.decode(PowerSource.self, forKey: .power)))
        case .ok: self = .ok
        case .failed: self = .failed(try c.decode(String.self, forKey: .message))
        }
    }
}
