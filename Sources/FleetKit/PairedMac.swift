import Foundation

/// The Mac this phone is paired to, as the phone remembers it.
public struct PairedMac: Codable, Equatable, Sendable {
    public var key: FleetDeviceKey
    public var macName: String
    public var serviceName: String
    /// Every REMEMBERED address that has worked, best-first. Updated as the phone learns
    /// better ones — the endpoint from the QR is stale the moment the Mac changes network,
    /// and a phone that only remembered the original would need re-pairing to follow it.
    /// A Mac found via Bonjour is deliberately absent from this list: Bonjour is a
    /// rediscovery mechanism, not a memory, so it is retried on every launch rather than
    /// being written here — see `FleetConnector.Candidate.isRemembered`.
    public var endpoints: [String]
    /// The highest sequence this phone has applied. Persisted so a relaunch resumes instead
    /// of re-downloading the fleet.
    public var lastSeq: Int

    public init(
        key: FleetDeviceKey, macName: String, serviceName: String,
        endpoints: [String], lastSeq: Int = 0
    ) {
        self.key = key
        self.macName = macName
        self.serviceName = serviceName
        self.endpoints = endpoints
        self.lastSeq = lastSeq
    }

    public init(adopting payload: PairingPayload) {
        self.init(
            key: payload.key, macName: payload.macName,
            serviceName: payload.serviceName, endpoints: payload.endpoints
        )
    }

    // `FleetDeviceKey` is deliberately not `Codable` (see `FleetTLS.swift`): a synthesized
    // conformance follows the type into whatever holds it, and a 32-byte secret should only
    // ever be serialized by code that names it. `PairingPayload` contains its `key.secret`
    // the same way, through a private `Body` with an explicit base64url `psk` field — this
    // mirrors that, rather than adding `Codable` to `FleetDeviceKey`'s declaration.
    private struct Body: Codable {
        var slot: UUID
        var secret: String
        var macName: String
        var serviceName: String
        var endpoints: [String]
        var lastSeq: Int
    }

    public init(from decoder: Decoder) throws {
        let body = try Body(from: decoder)
        // A record whose secret is not valid base64url is corrupt, not empty — decode it as
        // a failure rather than silently producing a key with a zero-length (or truncated)
        // secret that would authenticate against nothing.
        guard let secret = Data(base64URLEncoded: body.secret) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "secret is not valid base64url"
            ))
        }
        self.init(
            key: FleetDeviceKey(slot: body.slot, secret: secret),
            macName: body.macName, serviceName: body.serviceName,
            endpoints: body.endpoints, lastSeq: body.lastSeq
        )
    }

    public func encode(to encoder: Encoder) throws {
        try Body(
            slot: key.slot, secret: key.secret.base64URLEncodedString(),
            macName: macName, serviceName: serviceName,
            endpoints: endpoints, lastSeq: lastSeq
        ).encode(to: encoder)
    }
}
