import Foundation

public enum PairingPayloadError: Error, Equatable {
    case notAPairingCode
    case unsupportedVersion(Int)
    case malformed
}

/// What the QR on the Mac's screen carries, and the only thing that ever crosses between
/// the two devices out of band.
///
/// `FD2-` + Crockford base32 of a packed byte record. Not a URL, deliberately — see the
/// plan's Task 1. The digits in the prefix are the version, and they are checked before a
/// byte is decoded, so a code from a newer Mac is refused *as* too-new rather than as damaged.
public struct PairingPayload: Equatable, Sendable, Identifiable {
    /// The slot this code was minted for. Present so a presenter can drive a sheet from the
    /// payload itself rather than from a separate boolean — `.sheet(item:)` cannot render
    /// before the value exists, where `.sheet(isPresented:)` plus a companion optional can,
    /// and did: it showed an empty sheet.
    public var id: UUID { key.slot }

    public static let currentVersion = 2
    /// The scheme half of the code, with the version spelled into it — `FD2-`.
    ///
    /// Two letters and a digit rather than `flightdeck2:`, and the QR does benefit: `F`, `D`,
    /// the digits and `-` are in QR's *alphanumeric* charset where lowercase and `:` are not,
    /// so an all-uppercase code encodes at roughly two symbols per 11 bits instead of one per
    /// 8. Re-measured on the payload `PairingCodeImageTests` uses, at correction level `M`:
    /// `FD2-<body>` is **45 modules**, the same body lowercased behind `fd2-` is **53**, and
    /// v1's `flightdeck1:<base64>` is **65**. So the case is worth 8 modules and the 98-byte
    /// packed record is worth 20 — the record is the larger win, but not the only one. (An
    /// earlier revision of this comment claimed both cases came out identically at "39
    /// modules"; neither number reproduces, and the figure it quoted was a CoreImage *extent*
    /// rather than a module count. See `PairingCodeImageTests.modules(of:)` for that
    /// distinction, which is two modules wide.)
    ///
    /// Uppercase would stay regardless: the body is Crockford base32, which is only
    /// unambiguous in one case, and the short code beside this QR is read aloud across a room
    /// and typed by hand.
    ///
    /// The version stays in the prefix, and that is load-bearing exactly as it was in v1: a
    /// payload from a newer Mac may pack fields this version cannot parse, so decoding it
    /// under this schema would fail as *damaged*. The phone shows different copy for damaged
    /// ("show a new code on your Mac") and too-new ("update the app"), which send the user in
    /// opposite directions.
    private static let prefix = "FD"
    /// One byte of length prefix per name, so 255 is the format's ceiling. 64 is the policy:
    /// `FleetService.derivedServiceName` already caps at 24 plus a suffix, and a Mac name
    /// longer than 64 bytes is being displayed on a phone, where it will be truncated anyway.
    private static let maxNameBytes = 64

    public var version: Int
    public var key: FleetDeviceKey
    /// Shown on the phone so the user can tell two Macs apart. Cosmetic; identity is the key.
    ///
    /// Carried in the QR rather than learned from the connection: `FleetSnapshot` has no Mac
    /// identity in it at all — only projects — so nothing else ever tells the phone what to
    /// call this machine.
    public var macName: String
    /// The Bonjour instance name to look for on a LAN.
    ///
    /// Also carried rather than derived. `FleetService.serviceName` is a sanitised host name
    /// plus a per-install suffix, and `FleetConnector.startBrowsing` matches browse results
    /// against exactly that string — a phone without it cannot rediscover its Mac after a
    /// restart, so dropping it to save bytes would cost reconnection.
    public var serviceName: String
    /// Every address the Mac could see for itself when the QR was drawn, best first. These
    /// are *candidates* to race, not an address to trust: the key identifies the Mac, and by
    /// the time the phone leaves the room every one of these may be wrong.
    ///
    /// Only the first usable one survives the encoding — the rest are Bonjour's job, and the
    /// remembered-endpoint race exists for reconnects rather than for pairing.
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

    public func encoded() -> String {
        var bytes = Data()
        // `clamping`, so a caller that sets an out-of-range `version` on this public property
        // gets a code the prefix gate will reject rather than a trap inside the encoder.
        bytes.append(UInt8(clamping: version))
        bytes.append(contentsOf: withUnsafeBytes(of: key.slot.uuid) { Data($0) })
        bytes.append(key.secret)
        bytes.append(Self.packedEndpoint(endpoints.first))
        bytes.append(Self.packedName(serviceName))
        bytes.append(Self.packedName(macName))
        // No sorted-keys hazard here, unlike v1's JSON: this walks a fixed field order, so two
        // encodings of one payload are identical by construction rather than by a serializer
        // option somebody has to remember. `testEncodingTheSamePayloadTwiceGivesTheSameString`
        // still guards it, because the property matters more than the mechanism.
        return "\(Self.prefix)\(version)-" + bytes.crockfordBase32EncodedString()
    }

    /// IPv4 and port, or six zero bytes when there is nothing usable to pack.
    ///
    /// IPv4 only, matching `LocalEndpoints`: a link-local IPv6 address needs a zone index to
    /// be dialable and would pack a candidate that can never connect. A Mac with no routable
    /// v4 address still produces a scannable code — the phone finds it over Bonjour.
    private static func packedEndpoint(_ text: String?) -> Data {
        guard let text,
              let colon = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: colon)...])
        else { return Data(repeating: 0, count: 6) }
        let octets = text[..<colon].split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return Data(repeating: 0, count: 6) }
        return Data(octets) + Data([UInt8(port >> 8), UInt8(port & 0xFF)])
    }

    private static func unpackedEndpoint(_ bytes: Data) -> [String] {
        let octets = [UInt8](bytes.prefix(4))
        let port = UInt16(bytes[bytes.startIndex + 4]) << 8 | UInt16(bytes[bytes.startIndex + 5])
        guard octets.contains(where: { $0 != 0 }) || port != 0 else { return [] }
        return ["\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3]):\(port)"]
    }

    /// A one-byte length followed by UTF-8, truncated on a *scalar* boundary.
    ///
    /// `String.prefix(_:)` counts characters, not bytes, so it cannot overflow the length byte
    /// on its own — but a 64-character name of emoji is 256 bytes. Truncating the UTF-8 by
    /// bytes instead would split a scalar and produce a name that fails to decode. So this
    /// drops whole characters until the encoding fits.
    private static func packedName(_ name: String) -> Data {
        var trimmed = String(name.prefix(maxNameBytes))
        while Data(trimmed.utf8).count > 255 { trimmed = String(trimmed.dropLast()) }
        let utf8 = Data(trimmed.utf8)
        return Data([UInt8(utf8.count)]) + utf8
    }

    public init(decoding code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix(Self.prefix), let dash = trimmed.firstIndex(of: "-")
        else { throw PairingPayloadError.notAPairingCode }

        let digits = trimmed[
            trimmed.index(trimmed.startIndex, offsetBy: Self.prefix.count)..<dash
        ]
        // Digits only, not merely `Int`-parseable: `Int` accepts a leading `-` or `+`, so
        // without this `FD+2-…` would sail past the gate as version 2.
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(digits)
        else { throw PairingPayloadError.notAPairingCode }
        // Before a byte is decoded — see `prefix`.
        guard version == Self.currentVersion else {
            throw PairingPayloadError.unsupportedVersion(version)
        }

        guard let bytes = Data(crockfordBase32: String(trimmed[trimmed.index(after: dash)...])),
              bytes.count >= 56
        else { throw PairingPayloadError.malformed }
        // The body repeats the version so a hand-edited prefix cannot walk a mismatched body
        // past the gate above.
        guard Int(bytes[0]) == version else { throw PairingPayloadError.malformed }

        let slotBytes = [UInt8](bytes[1..<17])
        let slot = UUID(uuid: (
            slotBytes[0], slotBytes[1], slotBytes[2], slotBytes[3],
            slotBytes[4], slotBytes[5], slotBytes[6], slotBytes[7],
            slotBytes[8], slotBytes[9], slotBytes[10], slotBytes[11],
            slotBytes[12], slotBytes[13], slotBytes[14], slotBytes[15]
        ))
        // `Data(...)`, not the bare slice: a slice of `bytes` keeps a non-zero `startIndex`,
        // and a 32-byte secret indexed from 17 is a trap for the next caller who subscripts it.
        let secret = Data(bytes[17..<49])
        let endpoints = Self.unpackedEndpoint(bytes[49..<55])

        var cursor = 55
        guard let serviceName = Self.readName(from: bytes, cursor: &cursor),
              let macName = Self.readName(from: bytes, cursor: &cursor),
              // Nothing may follow the mac name. Trailing bytes cannot produce a wrong key —
              // every field this record means is already read by the time the cursor gets
              // here — so this is robustness rather than safety. What it buys is that "a
              // string this decoder accepts" and "a string this encoder writes" stay the same
              // set: without it, a record with anything appended decodes as if it were clean,
              // which is the shape that lets a genuinely damaged code look scannable and a
              // future field appended here be silently ignored instead of reported as
              // damaged. The base32 body has no bits to spare either way — a length that does
              // not divide evenly is dropped by `Data(crockfordBase32:)`, so every valid code
              // lands exactly on `bytes.count`.
              cursor == bytes.count
        else { throw PairingPayloadError.malformed }

        self.init(
            version: version, key: FleetDeviceKey(slot: slot, secret: secret),
            macName: macName, serviceName: serviceName, endpoints: endpoints
        )
    }

    /// One length-prefixed name, advancing `cursor`. `nil` for a length that runs off the end
    /// or bytes that are not UTF-8 — both of which mean the code is damaged rather than short.
    private static func readName(from bytes: Data, cursor: inout Int) -> String? {
        guard cursor < bytes.count else { return nil }
        let length = Int(bytes[cursor])
        cursor += 1
        guard cursor + length <= bytes.count else { return nil }
        let name = String(data: Data(bytes[cursor..<(cursor + length)]), encoding: .utf8)
        cursor += length
        return name
    }
}

extension Data {
    /// Crockford base32 — `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, the same alphabet
    /// `PairingCode` uses, and for a different reason worth naming: there it survives being
    /// read aloud; here it keeps the QR inside its *alphanumeric* encoding mode, which is
    /// roughly a third denser than byte mode for the same content. base64url would not — it
    /// has lowercase in it.
    ///
    /// No padding character. The final symbol carries whatever bits are left, shifted up, so
    /// the length of the string determines the length of the data and nothing has to be
    /// stripped on the way back.
    public func crockfordBase32EncodedString() -> String {
        var out = ""
        out.reserveCapacity((count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in self {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(Data.crockfordAlphabet[(buffer >> bits) & 0x1F])
                // Masked every drain, so `buffer` never accumulates high bits it will not use
                // — over a long payload an unmasked accumulator overflows `Int`.
                buffer &= (1 << bits) - 1
            }
        }
        if bits > 0 { out.append(Data.crockfordAlphabet[(buffer << (5 - bits)) & 0x1F]) }
        return out
    }

    public init?(crockfordBase32 text: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count * 5 / 8)
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = Data.crockfordAlphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        self = Data(bytes)
    }

    fileprivate static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// base64url (RFC 4648 §5): no `+`, `/` or `=`, so the whole code survives being typed,
    /// pasted, or read aloud without escaping. Still what `PairedMac` serialises its secret
    /// with; the pairing code itself moved to base32 above, for the QR's sake.
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
