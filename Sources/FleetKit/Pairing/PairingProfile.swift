import Foundation

/// Which pairing this is. SPAKE2 binds both names into the derived key, so two profiles with
/// different names cannot complete against each other even with the right code — that is what
/// stops a code shown for a host from pairing a phone, and the reverse.
///
/// Foundation-only and free of Network on purpose: the Linux hostd compiles this file directly
/// (Packages/HostDaemonLinux/Sources/PairingCore is a symlink farm), so it must not grow imports.
public struct PairingProfile: Sendable, Equatable {
    public let bonjourType: String
    public let initiatorName: Data
    public let responderName: Data
    /// The TLS 1.2 PSK suites the bootstrap channel appends, as IANA numbers. Raw `UInt16`
    /// rather than `tls_ciphersuite_t` because that type is Network's and this file is compiled
    /// on Linux; `FleetTLS.pairingListenerParameters(profile:)` maps them. They equal
    /// `FleetTLS.phoneSuites` / `hostSuites` (pinned by `PairingProfileTests`), and they differ
    /// for the same reason those do: a Linux host's BoringSSL has no 0x00A8, so a host pairing
    /// on the phone's suite fails its handshake with `NO_SHARED_CIPHER` before SPAKE2 starts.
    public let tlsSuites: [UInt16]

    /// The shipped phone pairing, unchanged: the same service type, names and suite every
    /// paired phone already speaks. Changing any of them strands every phone in the field.
    public static let phone = PairingProfile(
        bonjourType: "_flightdeck-pair._tcp",
        initiatorName: Data("flightdeck-phone".utf8),
        responderName: Data("flightdeck-mac".utf8),
        tlsSuites: [0x00A8]  // TLS_PSK_WITH_AES_128_GCM_SHA256
    )

    /// A controller pairing a host. `fd-host-pair` is 12 characters, inside RFC 6763's 15.
    public static let host = PairingProfile(
        bonjourType: "_fd-host-pair._tcp",
        initiatorName: Data("flightdeck-controller".utf8),
        responderName: Data("flightdeck-host".utf8),
        tlsSuites: [0xCCAC]  // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
    )
}
