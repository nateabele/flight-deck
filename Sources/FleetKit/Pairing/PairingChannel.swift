import CryptoKit
import Foundation

/// The constants the two ends of a pairing exchange must agree on byte for byte.
///
/// One file, shared by both binaries, because every value here is a place where "the Mac and
/// the phone each wrote their own" produces a failure that looks like a wrong code: a
/// different name reaches the SPAKE2 transcript, a different service type finds nothing, a
/// different PSK never completes a handshake. None of those announce themselves as what they
/// are.
public enum PairingChannel {
    /// The pairing listener's own Bonjour service, distinct from the fleet's
    /// `_flightdeck._tcp`. It exists only while a window is armed, so its presence *is* the
    /// "this Mac is pairable right now" signal — see the plan's "Deviations from the spec".
    ///
    /// `flightdeck-pair` is exactly 15 characters, RFC 6763's maximum service label length.
    /// Any future rename must stay at or under that or Bonjour registration fails silently.
    public static let bonjourType = "_flightdeck-pair._tcp"

    /// The TXT key carrying the Mac's display name, so a phone that discovers two armed Macs
    /// can name them. Cosmetic, and treated as such: it is unauthenticated text from the
    /// network until the exchange completes and the seal delivers the real name.
    public static let txtNameKey = "name"

    /// The SPAKE2 names, fixed by role rather than taken from either device.
    ///
    /// SPAKE2 binds both names into its transcript to stop one exchange being replayed into a
    /// different context. Device names cannot serve that here: on the typed path the phone
    /// has not learned the Mac's name yet — that is what the seal delivers — so any
    /// name-derived scheme would have the two sides guessing at each other. Fixed role labels
    /// give a fixed, agreed context, which is all the binding needs to be.
    public static let initiatorName = Data("flightdeck-phone".utf8)
    public static let responderName = Data("flightdeck-mac".utf8)

    /// The bootstrap PSK's identity. Deliberately not a UUID string: `FleetSocketServer`
    /// turns a PSK identity into a paired slot with `UUID(uuidString:)`, and an identity that
    /// parsed would be attributable to a device that does not exist.
    public static let bootstrapIdentity = Data("flightdeck-pairing-bootstrap-v1".utf8)

    /// **Public by design and by construction.** Anyone holding either binary has this, so it
    /// provides no confidentiality whatsoever and nothing in the pairing exchange may depend
    /// on the channel for secrecy — the device key is sealed under the SPAKE2-derived key and
    /// would be equally safe in the clear.
    ///
    /// What it buys is narrower and still worth having: no plaintext frames on the wire for a
    /// passive capture, an IDS or a network log to collect, and no unauthenticated frame
    /// parser reachable with nothing in front of it.
    ///
    /// **It must never be derived from the pairing code** (spec §6). That derivation is the
    /// obvious future "improvement" and it would let a passive observer attack the TLS
    /// handshake offline to recover 55 bits — reintroducing exactly the offline attack SPAKE2
    /// exists to prevent. A hash of a fixed string rather than a 32-byte literal only so the
    /// constant is readable; it is no more secret for being hashed.
    public static let bootstrapSecret = Data(
        SHA256.hash(data: Data("dev.flightdeck.pairing.bootstrap.v1".utf8))
    )
}
