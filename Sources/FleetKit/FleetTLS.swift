import Foundation
import Network
import Security

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
        keys: [FleetDeviceKey], identities: FleetPSKIdentities?,
        suites: [tls_ciphersuite_t] = phoneSuites
    ) -> NWParameters {
        let params = parameters(keys: keys, identities: identities, suites: suites)
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
        clientParameters(key: key, suites: phoneSuites)
    }

    /// The same client with a different suite offer. Internal so the only callers that can
    /// pick a suite are FleetKit's own transports (`HostTransport`), never an app call site.
    static func clientParameters(key: FleetDeviceKey, suites: [tls_ciphersuite_t]) -> NWParameters {
        parameters(keys: [key], identities: nil, suites: suites)
    }

    /// What the phone link appends: `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8), its suite since
    /// day one. A named default, so that adding the host path's different suite cannot change
    /// what a phone and a Mac negotiate.
    static let phoneSuites = [
        tls_ciphersuite_t(rawValue: numericCast(TLS_PSK_WITH_AES_128_GCM_SHA256))!
    ]

    /// What a host connection appends: `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC).
    /// It is not 0x00A8 because swift-nio-ssl's BoringSSL, the Linux hostd's TLS stack, does not
    /// implement 0x00A8 at all. Its only PSK suites are 0x008C, 0x008D, 0xC035, 0xC036 and
    /// 0xCCAC, and Darwin's default PSK offer (0x00A8/A9/AF/AE) contains none of them. A host
    /// dialled with the phone's suite fails with `NO_SHARED_CIPHER` on the server and `-9824`
    /// here. Of the shared suites, 0xCCAC is the only AEAD one, and it is the only one with
    /// forward secrecy (ECDHE).
    static let hostSuites = [
        tls_ciphersuite_t(rawValue: numericCast(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!
    ]

    /// The pairing listener's parameters: exactly one PSK, the public bootstrap one.
    ///
    /// A separate function rather than `listenerParameters(keys:)` with the bootstrap key
    /// folded into the array, and that is invariant 1 made structural: there is no argument
    /// anyone can pass to the fleet listener that puts the bootstrap PSK on it.
    public static func pairingListenerParameters() -> NWParameters {
        pairingListenerParameters(profile: .phone)
    }

    /// The same listener for a given pairing profile — `.host` appends 0xCCAC rather than the
    /// phone's 0x00A8. Internal for the reason `clientParameters(key:suites:)` is: only
    /// FleetKit's own pairing types pick a suite. The public phone entry point above routes
    /// through `.phone`, whose suite list is the single 0x00A8 this path always appended, so
    /// the phone's bootstrap offer is byte-for-byte unchanged.
    static func pairingListenerParameters(profile: PairingProfile) -> NWParameters {
        let parameters = bootstrapParameters(suites: ciphersuites(profile.tlsSuites))
        // Same narrow purpose as on the fleet listener: a socket the OS is still draining
        // from a previous run of this process. The pairing listener always takes a fresh
        // OS-assigned port, so it never rebinds one of its own.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// The phone's side of the same channel.
    public static func pairingClientParameters() -> NWParameters {
        pairingClientParameters(profile: .phone)
    }

    /// The initiator's side for a given profile; see `pairingListenerParameters(profile:)`.
    static func pairingClientParameters(profile: PairingProfile) -> NWParameters {
        bootstrapParameters(suites: ciphersuites(profile.tlsSuites))
    }

    /// `PairingProfile` carries IANA numbers because it is compiled on Linux, where
    /// `tls_ciphersuite_t` does not exist. A number Network has no case for is a programming
    /// error in a profile constant, not a runtime condition, so it traps rather than quietly
    /// dropping the suite and leaving a host pairing to fail as handshake silence.
    static func ciphersuites(_ raw: [UInt16]) -> [tls_ciphersuite_t] {
        raw.map { value in
            guard let suite = tls_ciphersuite_t(rawValue: value) else {
                preconditionFailure("not a tls_ciphersuite_t: \(value)")
            }
            return suite
        }
    }

    private static func bootstrapParameters(suites: [tls_ciphersuite_t]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            sec,
            PairingChannel.bootstrapSecret.dispatch,
            PairingChannel.bootstrapIdentity.dispatch
        )
        // Belt-and-braces, not verified-necessary here: deleting this append from this exact
        // function still negotiated 0x00A8 (`TLS_PSK_WITH_AES_128_GCM_SHA256`) over TLS 1.2 in
        // 6ms on Darwin 25.5 — `add_pre_shared_key` appears to enable the suite on its own.
        // Kept because it is harmless, it matches `parameters(keys:identities:suites:)`'s
        // pattern, and it is plausibly load-bearing on the iOS deployment target, where its
        // absence is untested. What *is* verified, by mutation, is the other half of this trap:
        // pinning a TLS 1.3 minimum — which looks like obvious hardening — silently breaks PSK
        // identically, presenting as the handshake silence `PairingChannelTests` documents.
        // Do not add that pin.
        //
        // `suites` is the profile's: `.phone` is exactly the 0x00A8 this always appended, and
        // `.host` is 0xCCAC, which a Linux host's BoringSSL needs (see `FleetTLS.hostSuites`).
        for suite in suites {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }
        // No PSK-selection block, unlike the fleet parameters: with exactly one registered
        // PSK there is no identity to attribute a connection to.
        //
        // No `multipathServiceType` either — but that is no longer what distinguishes these
        // from the fleet parameters, because the fleet ones no longer set it. The reasoning
        // recorded here (a pairing exchange is four frames on one LAN inside a two-minute
        // window, so it has no roaming to survive) is still true and is why this path never
        // had it. See `parameters(keys:identities:suites:)` for why the other path lost it:
        // MPTCP without the entitlement makes a listener drop plain SYNs on Wi-Fi outright.
        return NWParameters(tls: tls)
    }

    private static func parameters(
        keys: [FleetDeviceKey], identities: FleetPSKIdentities?, suites: [tls_ciphersuite_t]
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

        // Belt-and-braces: Network.framework's PSK support is the **TLS 1.2** PSK ciphersuite
        // family (`TLS_PSK_WITH_AES_128_GCM_SHA256`, 0x00A8 — Security/CipherSuite.h:197), not
        // TLS 1.3 external PSK, and this append is meant to guarantee it is offered. Measured
        // on Darwin 25.5, deleting this exact append from `bootstrapParameters()` still
        // negotiated 0x00A8 over TLS 1.2 in 6ms — `add_pre_shared_key` appears to enable the
        // suite on its own here, so the append is not verified-necessary on this OS. Kept
        // anyway: harmless, and untested in its absence on the iOS deployment target. What
        // *is* verified, by mutation, is the other half of this trap: pinning
        // `sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)` — which looks
        // like obvious hardening — silently breaks PSK, presenting as handshake silence
        // rather than `.failed`. Do not add that pin.
        //
        // `suites` is `phoneSuites` (0x00A8) everywhere but `HostTransport`. An appended suite
        // goes *in front of* Darwin's default PSK offer; it does not replace it. A captured
        // ClientHello with `hostSuites` reads `[GREASE, 0xCCAC, 0x00A8, 0x00A9, 0x00AF, 0x00AE]`.
        // The defaults cannot be stripped: `SecProtocolOptions.h` has append-only ciphersuite
        // calls and nothing that clears the set. So the host path cannot *offer* only 0xCCAC.
        // What keeps a host from falling back to 0x00A8 is the other end: the Linux server pins
        // `ECDHE-PSK-CHACHA20-POLY1305` (and BoringSSL has no 0x00A8 to fall back to), and a
        // Darwin host listener built from the same list settles on 0xCCAC. Whether that is the
        // client's order or the listener's winning is not established, since both lists lead
        // with it. `HostTransportLoopbackTests` asserts what actually gets negotiated.
        for suite in suites {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }

        let parameters = NWParameters(tls: tls)

        // **Keepalive, because a fleet connection can die without either end being told.**
        //
        // Nothing above this line detected that. A peer that goes away without a FIN or an RST
        // — the Mac's Wi-Fi renegotiating when the screensaver takes the display, a router
        // dropping an idle NAT entry, an interface changing underneath — leaves `NWConnection`
        // sitting in `.ready` forever. No state change reaches `FleetClient`, so
        // `FleetConnector` never calls `scheduleRetry()`, and a phone in the foreground has no
        // other trigger: its only other recovery path is the redial on returning from the
        // background, which cannot help an app that never left it. The reported symptom was a
        // phone that had to be force-quit to reconnect, every time.
        //
        // The probes are what turn that silence into a `.failed` the existing retry machinery
        // already knows how to handle. ~25s to notice: idle 10s, then three probes 5s apart.
        // Deliberately brisk — this is a LAN, and the cost of a false positive is one
        // handshake, against a session that otherwise never comes back.
        //
        // Not a substitute for the foreground redial and not made redundant by it: a suspended
        // iOS process runs no probes at all, so the two cover different halves and both are
        // needed.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
        }

        // NO `multipathServiceType` HERE. It was `.handover` — so an established connection
        // would survive the phone changing networks, which is most of what made roaming (§3)
        // feel like nothing happened — and it made the Mac unreachable from the phone
        // ENTIRELY, over Wi-Fi, in a way that looked like a firewall for a whole day.
        //
        // MPTCP needs `com.apple.developer.networking.multipath`, which Apple grants by
        // application and which this app does not have. On the phone the property is
        // therefore silently ignored and the connector dials plain TCP; on the Mac the
        // listener honours it. A listener expecting MP_CAPABLE on a multipath-eligible
        // interface DROPS a plain SYN — no RST, no log, no counter.
        //
        // Which is exactly what a capture showed: 46 SYNs from the phone carrying
        // `mss,nop,wscale,TS,sackOK` and no MP_CAPABLE, 0 SYN-ACKs back, `netstat -s -p tcp`
        // completely unmoved while the IP layer's "packets for this host" climbed. The same
        // socket accepted loopback and bridged connections throughout, because MPTCP does not
        // engage on those paths — which is also why the simulator, which is loopback-only,
        // never caught it, and why pf, the Application Firewall, Little Snitch and the
        // local-network grant all had to be cleared one by one before the cause was found.
        //
        // Proven in isolation before removal: two plain-TCP `NWListener`s differing in this
        // one property, on adjacent ports. From the phone's Safari the multipath one hung and
        // the control loaded.
        //
        // Do not restore this without the entitlement on BOTH sides. Roaming is worth having;
        // it is not worth trading every connection for.
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
