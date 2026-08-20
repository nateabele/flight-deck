import Foundation

public enum PairingPayloadError: Error, Equatable {
    case notAPairingCode
    case unsupportedVersion(Int)
    case malformed
}

/// What the QR on the Mac's screen carries, and the only thing that ever crosses between
/// the two devices out of band.
///
/// `flightdeck1:` + base64url of a small JSON object. Not a URL, deliberately — see the
/// plan's Task 1. The prefix carries the version too, so a phone can reject a code it does
/// not understand before decoding a byte of it.
public struct PairingPayload: Equatable, Sendable {
    public static let currentVersion = 1
    private static let prefix = "flightdeck1:"

    public var version: Int
    public var key: FleetDeviceKey
    /// Shown on the phone so the user can tell two Macs apart. Cosmetic; identity is the key.
    public var macName: String
    /// The Bonjour instance name to look for on a LAN.
    public var serviceName: String
    /// Every address the Mac could see for itself when the QR was drawn, best first. These
    /// are *candidates* to race, not an address to trust: the key identifies the Mac, and by
    /// the time the phone leaves the room every one of these may be wrong.
    public var endpoints: [String]

    public init(
        version: Int = PairingPayload.currentVersion,
        key: FleetDeviceKey, macName: String, serviceName: String, endpoints: [String]
    ) {
        self.version = version
        self.key = key
        self.macName = macName
        self.serviceName = serviceName
        self.endpoints = endpoints
    }

    private struct Body: Codable {
        var v: Int
        var slot: UUID
        var psk: String
        var name: String
        var svc: String
        var eps: [String]
    }

    public func encoded() -> String {
        let body = Body(
            v: version, slot: key.slot, psk: key.secret.base64URLEncodedString(),
            name: macName, svc: serviceName, eps: endpoints
        )
        // `try!` is honest here: `Body` is all `Codable` primitives with no custom encoding,
        // so a throw would be a compiler bug rather than a runtime condition to handle.
        let json = try! JSONEncoder().encode(body)
        return Self.prefix + json.base64URLEncodedString()
    }

    public init(decoding code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { throw PairingPayloadError.notAPairingCode }
        guard let json = Data(base64URLEncoded: String(trimmed.dropFirst(Self.prefix.count))),
              let body = try? JSONDecoder().decode(Body.self, from: json),
              let secret = Data(base64URLEncoded: body.psk)
        else { throw PairingPayloadError.malformed }
        guard body.v == Self.currentVersion else {
            throw PairingPayloadError.unsupportedVersion(body.v)
        }
        self.init(
            version: body.v,
            key: FleetDeviceKey(slot: body.slot, secret: secret),
            macName: body.name, serviceName: body.svc, endpoints: body.eps
        )
    }
}

extension Data {
    /// base64url (RFC 4648 §5): no `+`, `/` or `=`, so the whole code survives being typed,
    /// pasted, or read aloud without escaping.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }
}
