import Foundation
import Network
import Security

/// One paired device: the slot the Mac filed it under, and the secret they share.
///
/// The slot id doubles as the TLS PSK *identity*, which is what lets one listener hold
/// several devices' keys and still know which one connected — and what makes revoking a
/// device exactly "delete this slot's secret" with no other bookkeeping.
public struct FleetDeviceKey: Equatable, Sendable {
    public let slot: UUID
    /// 32 bytes from the system CSPRNG. Never derived from anything the user types: this is
    /// displayed once, in a QR, on a screen the user is looking at (§3), so there is no
    /// password to stretch and nothing to be memorable.
    public let secret: Data

    public init(slot: UUID, secret: Data) {
        self.slot = slot
        self.secret = secret
    }

    public static func mint() -> FleetDeviceKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failure here means the system CSPRNG is unavailable, which is not a condition
        // to paper over with a weaker key — there is no safe fallback, so trap.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return FleetDeviceKey(slot: UUID(), secret: Data(bytes))
    }

    /// The PSK identity blob. The slot's UUID string rather than its raw bytes, so a packet
    /// capture and the paired-devices list in Preferences name the same thing.
    var identity: Data { Data(slot.uuidString.utf8) }
}

/// Builds the `NWParameters` both halves of the fleet socket use.
public enum FleetTLS {
    /// Server side: every currently-paired slot, registered up front.
    public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters {
        let params = parameters(keys: keys)
        // Key rotation restarts the listener on the *same* port on every arm, expiry and
        // revocation (`FleetService.reloadKeys()`). `FleetSocketServer.start` now waits for
        // the old listener's cancellation to be confirmed before rebinding (its
        // `releaseListener()`), which is what actually prevents `EADDRINUSE` against a
        // still-live listener — this flag alone cannot, since two sockets cannot both
        // LISTEN on one port regardless of it. It stays set for the narrower case that
        // confirmation does not cover: a socket the OS is still draining in `TIME_WAIT`
        // from a *previous run* of this process (e.g. a crash or a killed test host), which
        // is exactly what `SO_REUSEADDR` is for.
        params.allowLocalEndpointReuse = true
        return params
    }

    /// Client side: this device's one key.
    public static func clientParameters(key: FleetDeviceKey) -> NWParameters {
        parameters(keys: [key])
    }

    private static func parameters(keys: [FleetDeviceKey]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        for key in keys {
            sec_protocol_options_add_pre_shared_key(
                sec, key.secret.dispatch, key.identity.dispatch
            )
        }

        // Required, and the reason is a trap worth naming: Network.framework's PSK support
        // is the **TLS 1.2** PSK ciphersuite family (`TLS_PSK_WITH_AES_128_GCM_SHA256`,
        // 0x00A8 — Security/CipherSuite.h:197), not TLS 1.3 external PSK. Without this
        // append the handshake offers no suite the peer can agree to and simply hangs; and
        // pinning `sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)` — which
        // looks like obvious hardening — breaks it for the same reason. Do not add that pin.
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: numericCast(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let parameters = NWParameters(tls: tls)
        // The phone roams between networks and the Mac's address changes under it; letting
        // an established connection survive a path change is most of what makes roaming
        // (§3) feel like nothing happened.
        parameters.multipathServiceType = .handover
        return parameters
    }
}

extension Data {
    /// Bridge to the `dispatch_data_t` the `sec_protocol_*` C API takes. `__DispatchData` is
    /// the imported C type; `DispatchData` is Swift's overlay value type, and the cast
    /// between them is the documented way across.
    var dispatch: __DispatchData {
        withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
