import CryptoKit
import Foundation
import Security

/// The short code a user types when they cannot scan the QR.
///
/// Twelve symbols: eleven of entropy (55 bits) and one checksum. The alphabet is Crockford
/// base32 — `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — which omits `I`, `L`, `O` and `U`. The first
/// three are omitted because a code is read off one screen and typed into another device, often
/// from across a room, and `1`/`I`/`l` and `0`/`O` are the errors that produces.
///
/// **55 bits is not the security boundary; the attempt limit is.** Three online guesses against
/// 55 bits is roughly 1 in 10¹⁶ per window, and SPAKE2 is what denies an attacker any offline
/// path. Shortening the code would still be safe on those numbers — it is this long because
/// there is no reason for it to be shorter, not because 55 bits is a computed minimum.
///
/// **The code and the pairing channel's bootstrap PSK must stay independent.** Deriving that
/// PSK from this code looks like free confidentiality and would hand a passive observer an
/// offline attack on these 55 bits, which is the exact thing SPAKE2 is here to prevent.
public struct PairingCode: Equatable, Sendable {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let symbolCount = 12
    private static let entropySymbols = 11

    /// The 55 bits, right-aligned in 7 bytes. This is what SPAKE2 uses as its password, so it
    /// is deliberately *not* derived from the display string: hyphens and case are presentation
    /// and must not change what the two sides prove knowledge of.
    public let secret: Data

    private init(secret: Data) {
        self.secret = secret
    }

    public static func mint() -> PairingCode {
        var bytes = [UInt8](repeating: 0, count: 7)
        // Same reasoning as `FleetDeviceKey.mint()`: a CSPRNG that will not answer is not a
        // condition to degrade around, so trap rather than fall back to something weaker.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        // 7 bytes is 56 bits; the code carries 55. Clear the top bit so the value and its
        // encoding agree — otherwise the 56th bit would be minted, dropped on the way out,
        // and two distinct secrets would render as the same code.
        bytes[0] &= 0x7F
        return PairingCode(secret: Data(bytes))
    }

    public init?(normalizing input: String) {
        let symbols = input.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard symbols.count == Self.symbolCount else { return nil }

        var values: [UInt8] = []
        values.reserveCapacity(Self.symbolCount)
        for character in symbols {
            guard let value = Self.alphabet.firstIndex(of: character) else { return nil }
            values.append(UInt8(value))
        }

        let entropy = Array(values[..<Self.entropySymbols])
        let secret = Self.pack(entropy)
        guard values[Self.entropySymbols] == Self.checkSymbol(for: secret) else { return nil }
        self.init(secret: secret)
    }

    /// What a partially-typed code should look like on screen right now.
    ///
    /// Three jobs, and each of them exists because the field cannot get it for free:
    ///
    /// - **Uppercase.** `.textInputAutocapitalization(.characters)` is a hint to the software
    ///   keyboard. A hardware keyboard, a paste and dictation all ignore it, so the rewrite is
    ///   what actually guarantees the case.
    /// - **Group into `XXXX-XXXX-XXXX`.** The Mac shows hyphens; a field that did not would
    ///   have the user comparing two differently-shaped strings across a room.
    /// - **Map the letters the alphabet omits.** `O` → `0`, `I`/`L` → `1`, per Crockford. The
    ///   alphabet omits them *because* a person reading a code aloud produces them, so
    ///   rejecting them would punish exactly the mistake the alphabet was chosen to absorb.
    ///   `U` is dropped instead: Crockford excludes it to avoid accidental obscenity and it
    ///   stands for no digit.
    ///
    /// Capped at twelve symbols so a stray keystroke past the end cannot invalidate a code
    /// that was already right.
    ///
    /// This is presentation only. `init(normalizing:)` is what decides whether a code is
    /// valid, and it is deliberately not called from here — a field that refused input until
    /// it was complete would reject every prefix of a correct code.
    public static func grouped(partial input: String) -> String {
        var symbols = ""
        for character in input.uppercased() {
            let mapped: Character?
            switch character {
            case "O": mapped = "0"
            case "I", "L": mapped = "1"
            default: mapped = alphabet.contains(character) ? character : nil
            }
            guard let mapped else { continue }
            symbols.append(mapped)
            if symbols.count == symbolCount { break }
        }
        return stride(from: 0, to: symbols.count, by: 4).map {
            String(symbols[symbols.index(symbols.startIndex, offsetBy: $0)...].prefix(4))
        }.joined(separator: "-")
    }

    public var formatted: String {
        let entropy = Self.unpack(secret)
        let symbols = (entropy + [Self.checkSymbol(for: secret)])
            .map { String(Self.alphabet[Int($0)]) }
            .joined()
        let groups = stride(from: 0, to: symbols.count, by: 4).map {
            String(symbols[symbols.index(symbols.startIndex, offsetBy: $0)...]
                .prefix(4))
        }
        return groups.joined(separator: "-")
    }

    /// 11 five-bit symbols, most significant first, into the low 55 bits of 7 bytes.
    private static func pack(_ symbols: [UInt8]) -> Data {
        var value: UInt64 = 0
        for symbol in symbols { value = (value << 5) | UInt64(symbol) }
        var bytes = [UInt8](repeating: 0, count: 7)
        for index in 0..<7 { bytes[6 - index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
        return Data(bytes)
    }

    private static func unpack(_ secret: Data) -> [UInt8] {
        var value: UInt64 = 0
        for byte in secret { value = (value << 8) | UInt64(byte) }
        return (0..<entropySymbols).reversed().map { UInt8((value >> (5 * UInt64($0))) & 0x1F) }
    }

    /// Five bits of SHA-256 over the packed secret.
    ///
    /// Not a cryptographic control — an attacker computes it as easily as we do. It exists so a
    /// mistyped code fails on the phone instead of spending one of three attempts on the Mac to
    /// discover the same thing, and so the phone can say "that code doesn't look right" rather
    /// than "pairing failed", which sends the user somewhere different.
    private static func checkSymbol(for secret: Data) -> UInt8 {
        let digest = SHA256.hash(data: secret)
        return digest.withUnsafeBytes { UInt8($0[0] & 0x1F) }
    }
}
