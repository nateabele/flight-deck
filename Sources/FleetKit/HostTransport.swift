import Foundation
import Network

/// The parameters a Flight Deck *host* connection uses: the fleet's TLS-PSK (one slot per paired
/// controller) under the fleet's WebSocket framing. Public because the macOS hostd and the
/// controller's `HostLink` both live outside FleetKit, and `FleetSocket` is internal on purpose —
/// exposing the composition rather than its parts keeps a host from being dialled over bare
/// TLS, which the Linux server would answer with handshake silence.
///
/// Both ends offer `FleetTLS.hostSuites` (0xCCAC), not the phone link's 0x00A8, because the
/// Linux hostd's BoringSSL has no 0x00A8 (see `hostSuites`). Mac hosts use the same suite, so
/// a controller has one host transport rather than one per host OS. The phone paths
/// (`FleetTLS.listenerParameters(keys:)` / `clientParameters(key:)`) are untouched.
public enum HostTransport {
    /// Authorizes any paired key but records nothing about which one a peer used, so every
    /// connection on it is anonymous. A host that revokes or names controllers needs the
    /// `identities:` overload below.
    public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters {
        FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: keys, identities: nil, suites: FleetTLS.hostSuites)
        )
    }

    /// The listener a host that must tell its controllers apart builds: the same keys and
    /// suites, plus the PSK selection block that files each peer's offered identity in
    /// `identities` as it shakes hands. The macOS hostd needs this because revocation and
    /// naming are keyed on the slot a connection authenticated as; the overload above
    /// authorizes peers but leaves every connection anonymous.
    public static func listenerParameters(
        keys: [FleetDeviceKey], identities: PeerIdentities
    ) -> NWParameters {
        FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(
                keys: keys, identities: identities.table, suites: FleetTLS.hostSuites
            )
        )
    }

    /// Which paired slot each connection on a host listener authenticated as.
    ///
    /// A public face on `FleetPSKIdentities`, which stays internal so the phone path's table
    /// is not reachable from outside FleetKit. It is the only correct source for the answer:
    /// `sec_protocol_metadata_access_pre_shared_keys` returns every key the *listener* holds,
    /// identically for every peer, which is how `FleetSocketServer` once attributed every
    /// phone to the last-registered slot (see `FleetPSKIdentities`).
    ///
    /// Confined to `queue`, which must be the queue the listener and its connections run on:
    /// the selection block files its record there during the handshake, so reading on the
    /// same queue once the connection is `.ready` needs no lock and has no ordering question.
    public final class PeerIdentities: @unchecked Sendable {
        let table: FleetPSKIdentities

        public init(queue: DispatchQueue) {
            table = FleetPSKIdentities(queue: queue)
        }

        /// The slot `connection`'s handshake offered, or nil when no record exists (a
        /// connection from another listener, or one already asked). Consumes the record, so
        /// ask once per connection and keep the answer. Call on `queue`, after `.ready`.
        public func slot(of connection: NWConnection) -> UUID? {
            guard
                let tls = connection.metadata(definition: NWProtocolTLS.definition)
                    as? NWProtocolTLS.Metadata,
                let identity = table.take(tls.securityProtocolMetadata)
            else { return nil }
            return UUID(uuidString: String(decoding: identity, as: UTF8.self))
        }
    }

    public static func clientParameters(key: FleetDeviceKey) -> NWParameters {
        FleetSocket.webSocketParameters(
            FleetTLS.clientParameters(key: key, suites: FleetTLS.hostSuites)
        )
    }

    /// A `.hostPort` endpoint wrapped as a `wss://` URL; anything else is passed through.
    public static func endpoint(for endpoint: NWEndpoint) -> NWEndpoint {
        FleetSocket.webSocketEndpoint(for: endpoint)
    }
}
