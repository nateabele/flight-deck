import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// The Linux hostd's listener: TLS 1.2 PSK under WebSocket framing — the same composition
/// FleetKit's `HostTransport` dials from Darwin, rebuilt on swift-nio-ssl because
/// Network.framework does not exist on Linux.
///
/// Keyed by PSK identity, which on the wire is a paired slot's UUID string
/// (`FleetDeviceKey.identity`). An identity `keys()` does not know is refused in the handshake.
final class PSKWebSocketServer: @unchecked Sendable {
    /// One accepted WebSocket. `identity` is the PSK identity the peer authenticated with.
    final class Connection: @unchecked Sendable {
        let identity: String
        private let channel: Channel

        init(identity: String, channel: Channel) {
            self.identity = identity
            self.channel = channel
        }

        func send(text: String) {
            let channel = self.channel
            channel.eventLoop.execute {
                let buffer = channel.allocator.buffer(string: text)
                channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer),
                                      promise: nil)
            }
        }
    }

    private let host: String
    private let port: Int
    private let keys: @Sendable () -> [String: [UInt8]]
    private let onText: @Sendable (Connection, String) -> Void
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init(host: String, port: Int,
         keys: @escaping @Sendable () -> [String: [UInt8]],
         onText: @escaping @Sendable (Connection, String) -> Void) {
        self.host = host
        self.port = port
        self.keys = keys
        self.onText = onText
    }

    /// Binds and returns the bound channel; the caller waits on its `closeFuture`.
    func start() throws -> Channel {
        let keys = self.keys
        let onText = self.onText
        // Built once up front and discarded, so a configuration BoringSSL rejects (a cipher
        // string it has no suite for) fails the daemon at launch rather than every handshake.
        _ = try NIOSSLContext(configuration: Self.tls(keys: keys, into: SlotAttribute()))
        return try ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // A context per connection, not one shared: BoringSSL's PSK callback is handed
                // the SSL object but nothing NIO can map back to a channel, so the only place
                // to catch *which* identity this peer used is a closure that already knows
                // which channel it belongs to.
                let slot = SlotAttribute()
                do {
                    let context = try NIOSSLContext(configuration: Self.tls(keys: keys, into: slot))
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(slot)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 16 << 20,
                    shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                    upgradePipelineHandler: { channel, _ in
                        let connection = Connection(identity: slot.identity ?? "", channel: channel)
                        return channel.pipeline.addHandler(
                            WebSocketFrameHandler(connection: connection, onText: onText))
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
            }
            .bind(host: host, port: port)
            .wait()
    }

    static func tls(keys: @escaping @Sendable () -> [String: [UInt8]],
                    into slot: SlotAttribute) -> TLSConfiguration {
        var tls = TLSConfiguration.makePreSharedKeyConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.maximumTLSVersion = .tlsv12
        // 0xCCAC, the host suite (`FleetTLS.hostSuites` on the Darwin side). Not the phone's
        // PSK-AES128-GCM-SHA256 (0x00A8): BoringSSL does not implement it, and
        // `SSL_CTX_set_cipher_list` rejects the string, which traps NIOSSLContext's init. Pinned
        // to exactly one suite because Darwin cannot stop offering its defaults (0x00A8/A9/AF/AE),
        // so this end is the one that guarantees what gets negotiated.
        tls.cipherSuites = "ECDHE-PSK-CHACHA20-POLY1305"
        tls.pskServerProvider = { context in
            guard let bytes = keys()[context.clientIdentity] else {
                throw UnknownIdentity(identity: context.clientIdentity)
            }
            slot.identity = context.clientIdentity
            return PSKServerIdentityResponse(key: NIOSSLSecureBytes(bytes))
        }
        return tls
    }

    struct UnknownIdentity: Error { let identity: String }
}

/// Holds the PSK identity a connection's handshake authenticated with. A pass-through handler so
/// it lives on the channel's pipeline for exactly the channel's lifetime.
///
/// `@unchecked Sendable`: written once from BoringSSL's PSK callback, which runs on the
/// channel's event loop during the handshake, and read afterwards on that same loop.
final class SlotAttribute: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    var identity: String?

    /// The only handler behind `NIOSSLServerHandler` before the WebSocket upgrade, so without
    /// this a refused handshake (unknown identity, wrong key, no shared suite) leaves no trace.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("handshake \(identity ?? "-"): \(error)\n".utf8))
        context.fireErrorCaught(error)
    }
}

/// Text frames to `onText`; pings answered with pongs (the Darwin side sets `autoReplyPing`, so
/// the two ends keep each other alive symmetrically); a close is echoed and the channel closed.
final class WebSocketFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let connection: PSKWebSocketServer.Connection
    private let onText: @Sendable (PSKWebSocketServer.Connection, String) -> Void

    init(connection: PSKWebSocketServer.Connection,
         onText: @escaping @Sendable (PSKWebSocketServer.Connection, String) -> Void) {
        self.connection = connection
        self.onText = onText
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            onText(connection, data.readString(length: data.readableBytes) ?? "")
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            frame.maskKey = nil
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                bound.value.close(promise: nil)
            }
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("connection \(connection.identity): \(error)\n".utf8))
        context.close(promise: nil)
    }
}
