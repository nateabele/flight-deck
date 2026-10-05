import Foundation
import Network

extension DarwinHostPeer {
    /// `HostPeer`'s binary half (contract amendment A6): the host's `ChannelMux` sends its
    /// frames through this, one WebSocket binary message each. Without it the protocol's
    /// default would drop every channel frame silently. Sent on the same `NWConnection` as
    /// `send(text:)`, so text and binary keep their call order on the wire.
    func send(binary: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "channel", metadata: [meta])
        connection.send(content: binary, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}
