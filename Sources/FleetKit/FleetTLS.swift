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

/// Which PSK identity each incoming connection offered, recorded as the handshake happens.
///
/// This exists because there is no way to ask a *finished* connection which key it used.
/// `sec_protocol_metadata_access_pre_shared_keys` returns "the PSKs supported by the local
/// instance" (`SecProtocolMetadata.h:268-283`) — on a listener holding every paired device's
/// key that is *all* of them, in registration order, identically for every peer, which is how
/// `FleetSocketServer.slot(of:)` came to report the last-registered slot no matter who
/// connected. The one moment the answer exists is during the handshake, in the PSK selection
/// block, so it is caught there and looked up afterwards.
///
/// Keyed by the identity of the `sec_protocol_metadata_t` object the selection block is handed:
/// that object is the *same instance* the connection later exposes as
/// `NWProtocolTLS.Metadata.securityProtocolMetadata`, verified by pointer equality on both
/// sides of a real handshake. The metadata is retained alongside its key for exactly that
/// reason — an `ObjectIdentifier` is an address, and an address whose object has been freed can
/// be reissued to a *different* connection's metadata later, which would silently attribute one
/// phone's socket to another phone's slot. Retaining it makes that impossible rather than
/// unlikely.
///
/// `@unchecked Sendable`: the same argument as `FleetSocketServer`, whose queue this shares —
/// every entry point asserts it is on that queue, so this state is confined, not shared.
final class FleetPSKIdentities: @unchecked Sendable {
    /// The queue the selection block is invoked on, and the only queue this may be touched
    /// from. `FleetSocketServer` passes its own, which is what makes a record written during a
    /// handshake visible — with no lock, and with no ordering question — to the frame handling
    /// that later reads it back.
    let queue: DispatchQueue

    private struct Record {
        let key: ObjectIdentifier
        /// Retained solely so `key` cannot go stale. Never dereferenced.
        let metadata: AnyObject
        let identity: Data
    }

    /// Bounded, oldest evicted first: a record is written for every handshake *attempt*,
    /// including ones that go on to fail authentication — the selection block fires before the
    /// peer has proved anything — and only a connection that reaches the server takes its
    /// record back out. Without a bound, refused handshakes would accumulate for the life of
    /// the process.
    private static let capacity = 64
    private var records: [Record] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func record(_ metadata: AnyObject, identity: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        records.append(
            Record(key: ObjectIdentifier(metadata), metadata: metadata, identity: identity)
        )
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    /// Removes and returns the identity offered on `metadata`'s connection. Removing on read is
    /// what keeps this table the size of the handshakes in flight rather than the size of every
    /// connection the process has ever accepted; the caller caches the answer per connection.
    func take(_ metadata: AnyObject) -> Data? {
        dispatchPrecondition(condition: .onQueue(queue))
        let key = ObjectIdentifier(metadata)
        guard let index = records.firstIndex(where: { $0.key == key }) else { return nil }
        return records.remove(at: index).identity
    }

    func removeAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        records.removeAll()
    }
}

/// Builds the `NWParameters` both halves of the fleet socket use.
public enum FleetTLS {
    /// Server side: every currently-paired slot, registered up front.
    ///
    /// Records nothing about *which* slot a given peer negotiated, so a listener built this way
    /// can authorize peers but cannot tell them apart. `FleetSocketServer` calls the overload
    /// below instead; this one remains for callers that only need the trust boundary.
    public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters {
        listenerParameters(keys: keys, identities: nil)
    }

    /// The listener `FleetSocketServer` actually builds: the same keys, plus a PSK selection
    /// block that files each peer's offered identity in `identities` as it shakes hands.
    static func listenerParameters(
        keys: [FleetDeviceKey], identities: FleetPSKIdentities?
    ) -> NWParameters {
        let params = parameters(keys: keys, identities: identities)
        // Key rotation restarts the listener on the *same* port on every arm, expiry and
        // revocation (`FleetService.reloadKeys()`). `FleetSocketServer.start` now waits for
        // the old listener's cancellation to be confirmed before rebinding (its
        // `releaseListenerOnQueue`), which is what actually prevents `EADDRINUSE` against a
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
        parameters(keys: [key], identities: nil)
    }

    private static func parameters(
        keys: [FleetDeviceKey], identities: FleetPSKIdentities?
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        if let identities {
            // `SecProtocolOptions.h:406-420` documents this block from the client's side
            // ("when the client must choose a PSK identity given a hint from its peer"), and
            // that wording is why an earlier note in FOLLOWUPS assumed it was client-only. It
            // is not: installed on listener options it fires once per incoming connection, on
            // `identities.queue`, with the hint carrying the identity the *client* offered —
            // which for a fleet key is the paired slot's UUID (`FleetDeviceKey.identity`).
            // Verified against a real two-key listener before this was written.
            //
            // Completing with the offered identity is the selection the stack makes unaided, so
            // this changes who gets in not at all: a paired identity presented with the wrong
            // secret still fails the handshake (`bad MAC`), and an identity that was never
            // registered still fails it (`unknown PSK identity`) — both exercised directly
            // against this exact block. The identity is a *claim*; the PSK is the credential.
            // So what is filed here is only meaningful for a connection that goes on to
            // complete the handshake, which is the only kind the server ever looks one up for.
            sec_protocol_options_set_pre_shared_key_selection_block(sec, { metadata, hint, complete in
                if let hint {
                    identities.record(metadata, identity: Data(hint as DispatchData))
                }
                complete(hint)
            }, identities.queue)
        }

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
