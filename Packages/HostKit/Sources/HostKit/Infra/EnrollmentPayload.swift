import Foundation

/// The one-time enrollment file a cloud machine's user-data writes to tmpfs and
/// `flightdeck-hostd enroll --file` hands to the running `serve`: the controller's slot and
/// secret, minted on the Mac, so the machine is paired before anyone could type a code into it.
///
/// Shared by the controller (which renders it into cloud-init) and hostd (which redeems it), so
/// the two cannot disagree on a key. The JSON is written and read with ISO-8601 dates, which is
/// what a shell-rendered user-data template can produce.
public struct EnrollmentPayload: Codable, Sendable, Equatable {
    public let version: Int
    public let slot: UUID
    /// The 32-byte PSK, as 64 hex characters (either case).
    public let secretHex: String
    public let controllerName: String
    /// How long the machine may sit idle before the controller may stop it; hostd keeps it for
    /// idle reporting.
    public let idleSeconds: Int
    public let issuedAt: Date

    /// User-data stays readable from the metadata service for the machine's whole life, so a
    /// payload is only honoured during the boot that it was written for: thirty minutes covers
    /// a slow image boot plus the hostd download, and anything older is a replay.
    public static let maxAge: TimeInterval = 1800
    /// A cloud VM's clock can run ahead of the Mac's before NTP settles; without this slack a
    /// payload issued "in the future" would be refused on a perfectly healthy boot.
    static let clockSkew: TimeInterval = 300
    static let currentVersion = 1

    public init(version: Int, slot: UUID, secretHex: String, controllerName: String, idleSeconds: Int,
                issuedAt: Date) {
        self.version = version
        self.slot = slot
        self.secretHex = secretHex
        self.controllerName = controllerName
        self.idleSeconds = idleSeconds
        self.issuedAt = issuedAt
    }

    /// The slot and secret to store, or why this payload must not be redeemed. Version first,
    /// so a newer controller's file is reported as such rather than as a malformed one.
    public func validate(now: Date) throws -> (slot: UUID, secret: Data) {
        guard version == Self.currentVersion else { throw EnrollmentError.wrongVersion }
        let age = now.timeIntervalSince(issuedAt)
        guard age >= -Self.clockSkew, age <= Self.maxAge else { throw EnrollmentError.expired }
        guard let secret = Self.bytes(hex: secretHex), secret.count == 32 else { throw EnrollmentError.malformed }
        return (slot, secret)
    }

    private static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

public enum EnrollmentError: Error, Equatable {
    case expired, malformed, wrongVersion
}
