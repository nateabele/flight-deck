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
    public static func listenerParameters(keys: [FleetDeviceKey]) -> NWParameters {
        FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: keys, identities: nil, suites: FleetTLS.hostSuites)
        )
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
