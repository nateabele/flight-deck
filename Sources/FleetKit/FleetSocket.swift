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

    static func send<Frame: Encodable>(
        _ frame: Frame, over connection: NWConnection, onError: ((Error) -> Void)? = nil
    ) {
        let data: Data
        do {
            data = try JSONEncoder().encode(frame)
        } catch {
            onError?(error)
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { error in if let error { onError?(error) } }
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
