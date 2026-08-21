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
/// plan's Task 1. The digits in the prefix are the version, and they are checked before any
/// base64 or JSON decoding happens, so a code from a newer Mac is refused *as* too-new rather
/// than as damaged.
public struct PairingPayload: Equatable, Sendable, Identifiable {
    /// The slot this code was minted for. Present so a presenter can drive a sheet from the
    /// payload itself rather than from a separate boolean — `.sheet(item:)` cannot render
    /// before the value exists, where `.sheet(isPresented:)` plus a companion optional can,
    /// and did: it showed an empty sheet.
    public var id: UUID { key.slot }

    public static let currentVersion = 1
    /// The scheme half of the code. The version is spelled into the prefix — `flightdeck1:` —
    /// and that is load-bearing, not cosmetic: a payload from a newer Mac may rename or retype
    /// fields, so decoding it under this version's schema would fail as *damaged*. The phone
    /// shows different copy for damaged ("show a new code on your Mac") and too-new ("update
    /// the app"), which send the user in opposite directions — so the version has to be
    /// readable without decoding anything.
    private static let scheme = "flightdeck"

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
        // `.sortedKeys` is load-bearing, not tidiness. `JSONEncoder` builds a keyed container
        // as a dictionary and serialises in iteration order, which Swift randomises per
        // process — so two calls could emit the same fields in a different order and produce
        // a different string for the same payload. Both the QR and the typed code are drawn
        // from this, and the first person to run the app watched the code churn in front of
        // them once a second. Decoding never cared about order, which is exactly why this
        // survived every test that round-tripped a payload instead of comparing two encodings.
        //
        // The accompanying test compares fifty encodings. Note that it passes by luck without
        // this line, because within a single process the seed is fixed and the order happens
        // to be stable — which is how it passed once and then failed 48 runs out of 50.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // `try!` is honest here: `Body` is all `Codable` primitives with no custom encoding,
        // so a throw would be a compiler bug rather than a runtime condition to handle.
        let json = try! encoder.encode(body)
        return "\(Self.scheme)\(version):" + json.base64URLEncodedString()
    }

    public init(decoding code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.scheme), let colon = trimmed.firstIndex(of: ":")
        else { throw PairingPayloadError.notAPairingCode }

        let digits = trimmed[
            trimmed.index(trimmed.startIndex, offsetBy: Self.scheme.count)..<colon
        ]
        // Digits only, not merely `Int`-parseable: `Int` accepts a leading `-` or `+`, so
        // without this `flightdeck+1:` would sail past the gate as version 1, and
        // `flightdeck-1:` would be reported as an unsupported version rather than as not a
        // pairing code at all. `encoded()` never emits either, so both are malformed input.
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(digits)
        else { throw PairingPayloadError.notAPairingCode }
        // Before a byte is decoded. A future payload may not parse under this schema at all,
        // and failing it as "damaged" would send the user to show a fresh code when what they
        // actually need is to update the app.
        guard version == Self.currentVersion else {
            throw PairingPayloadError.unsupportedVersion(version)
        }

        guard let json = Data(base64URLEncoded: String(trimmed[trimmed.index(after: colon)...])),
              let body = try? JSONDecoder().decode(Body.self, from: json),
              let secret = Data(base64URLEncoded: body.psk)
        else { throw PairingPayloadError.malformed }
        // The body repeats the version so a hand-edited prefix cannot walk a mismatched body
        // past the gate above.
        guard body.v == version else { throw PairingPayloadError.malformed }

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
