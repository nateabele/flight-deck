import Foundation
import HostKit
import NIOCore
import NIOWebSocket

/// Whole binary WebSocket messages (delegation's `ChannelMux` frames) to `onBinary`; every
/// other frame passes on to `WebSocketFrameHandler`. Sits behind the aggregator, so a binary
/// message a controller fragmented arrives whole, under the same byte cap as text.
///
/// A separate handler rather than a case in `WebSocketFrameHandler` so a server built without
/// `onBinary` keeps dropping binary exactly as it did before delegation.
final class BinaryFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = WebSocketFrame

    private let connection: PSKWebSocketServer.Connection
    private let onBinary: @Sendable (PSKWebSocketServer.Connection, Data) -> Void

    init(connection: PSKWebSocketServer.Connection,
         onBinary: @escaping @Sendable (PSKWebSocketServer.Connection, Data) -> Void) {
        self.connection = connection
        self.onBinary = onBinary
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .binary else { return context.fireChannelRead(data) }
        var bytes = frame.unmaskedData
        onBinary(connection, Data(bytes.readBytes(length: bytes.readableBytes) ?? []))
    }
}

extension NIOHostPeer {
    /// `HostPeer`'s binary half (contract amendment A6): the host's `ChannelMux` sends through
    /// this. Without it the protocol's default would drop every channel frame silently.
    func send(binary: Data) { connection.send(binary: binary) }
}
