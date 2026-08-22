import Foundation
import Network

/// Frame send/receive over one `NWConnection`, shared by both halves.
///
/// WebSocket rather than a bare length prefix over TLS, for two reasons that both bite
/// later: ping/pong keepalive is what keeps a phone's connection alive through a carrier's
/// idle timeout, and a relay (§3, out of scope but designed for) speaks WebSocket
/// everywhere and a bespoke framing nowhere.
enum FleetSocket {
    static func webSocketParameters(_ base: NWParameters) -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        // Answer the peer's pings in the stack rather than in application code: a keepalive
        // that depends on the app being responsive is not a keepalive.
        options.autoReplyPing = true
        base.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return base
    }

    /// `NWProtocolWebSocket`'s automatic HTTP-upgrade handshake needs a URL to build its
    /// Upgrade request from. Handed a bare `.hostPort` endpoint instead — what most callers
    /// here pass — it aborts the connection (`ECONNABORTED`, silently, before `.ready`)
    /// rather than falling back to something host/port alone could satisfy; a plain TLS-PSK
    /// connection built from the identical parameters, minus the WebSocket layer, completes
    /// in single-digit milliseconds, which is what isolates this to the WebSocket handshake
    /// rather than to TLS-PSK or to loopback itself. So `.hostPort` is translated to a `wss`
    /// URL here rather than pushing the workaround onto every call site.
    ///
    /// A `.service` endpoint from an `NWBrowser` is passed through untouched, and that is the
    /// shipped behaviour rather than an assumption: `FleetConnector` has always dialled
    /// browsed services this way, over these same WebSocket parameters. The pairing path
    /// relies on it too — its whole typed flow dials `.service` endpoints.
    static func webSocketEndpoint(for endpoint: NWEndpoint) -> NWEndpoint {
        guard case .hostPort(let host, let port) = endpoint else { return endpoint }
        // IPv6 literals need bracketing to be valid inside a URL authority; every other
        // host form's description is already URL-safe as-is.
        let hostText: String
        switch host {
        case .ipv6:
            hostText = "[\(host)]"
        default:
            hostText = "\(host)"
        }
        guard let url = URL(string: "wss://\(hostText):\(port.rawValue)/") else { return endpoint }
        return .url(url)
    }

    /// `onSent` fires on the connection's own queue once the protocol stack has taken the
    /// frame — win or lose, and after `onError` — and exists for exactly one caller shape:
    /// sending a last frame and then closing the socket.
    ///
    /// That shape needs it because `NWConnection.cancel()` does not wait for a send issued in
    /// the same block, `forceCancel()`'s documentation ("without waiting for pending sends")
    /// notwithstanding. Measured: `PairingListener` rejecting a malformed frame with
    /// `send(...)` on one line and `cancel()` on the next delivered the reject 0 times in 2
    /// runs — inserting a single log line between the two made it arrive every time, which is
    /// what identifies this as a race rather than a frame that was never sent. Cancelling from
    /// here instead is deterministic.
    static func send<Frame: Encodable>(
        _ frame: Frame, over connection: NWConnection, onError: ((Error) -> Void)? = nil,
        onSent: (@Sendable () -> Void)? = nil
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(frame)
        } catch {
            onError?(error)
            onSent?()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { error in
                if let error { onError?(error) }
                onSent?()
            }
        )
    }

    /// Delivers whole messages, repeatedly, until the connection ends. `receiveMessage`
    /// rather than `receive(minimumIncompleteLength:)` because the WebSocket protocol has
    /// already done the framing — reassembling it by hand would be reimplementing it.
    static func receive<Frame: Decodable>(
        _ type: Frame.Type, from connection: NWConnection,
        onFrame: @escaping (Frame) -> Void, onEnd: @escaping (Error?) -> Void
    ) {
        connection.receiveMessage { data, context, _, error in
            if let error {
                onEnd(error)
                return
            }
            if let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                onEnd(nil)
                return
            }
            if let data, !data.isEmpty {
                do {
                    onFrame(try JSONDecoder().decode(Frame.self, from: data))
                } catch {
                    // A frame we cannot parse is a protocol violation, not a transient
                    // hiccup: continuing would leave the two sides silently disagreeing
                    // about state, which is the failure mode the whole resume design
                    // exists to make impossible.
                    onEnd(error)
                    return
                }
            }
            receive(type, from: connection, onFrame: onFrame, onEnd: onEnd)
        }
    }
}
