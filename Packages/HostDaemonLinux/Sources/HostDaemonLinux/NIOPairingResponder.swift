import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
@_spi(HostPairing) import PairingCore

/// The Linux host's half of a pairing window: FleetKit's `PairingListener`, rebuilt on SwiftNIO
/// because Network.framework does not exist here. **`PairingListener.swift` is the reference and
/// its comments are the requirements**; this file repeats only what differs, and names the
/// listener property each limit mirrors so the two can be read side by side.
///
/// Everything cryptographic is not rebuilt but *shared*: `SPAKE2Session`, `PairingSecrets`, the
/// frames and the bootstrap PSK are FleetKit's own files, compiled into `PairingCore` through
/// symlinks. A port of them would be a second implementation that could disagree by one byte,
/// and every such disagreement presents as "wrong code".
///
/// Always the `.host` profile: a Linux hostd is a host by definition, and the profile's names in
/// the SPAKE2 key are what keep a phone's code from completing here.
///
/// The responder never learns the controller's name — the seal carries this host's name one way
/// only. The controller sends its own name in its first `hello` on the fleet socket.
enum NIOPairingResponder {
    static let profile = PairingProfile.host
    /// `PairingListener.maxAttempts`: three guesses per window, and the limit is the security
    /// boundary, not the code's length.
    static let maxAttempts = 3
    /// `PairingListener.maxPending`: every peer here is unauthenticated.
    static let maxPending = 4
    /// `PairingListener.maxFrameBytes`: the one socket where a stranger can make us allocate.
    static let maxFrameBytes = 16 * 1024
    /// `PairingListener.handshakeDeadline`: accept → TLS-PSK and the WebSocket upgrade done.
    static let handshakeDeadline = TimeAmount.seconds(10)
    /// `PairingListener.firstFrameDeadline`: upgrade done → first frame.
    static let firstFrameDeadline = TimeAmount.seconds(5)
    /// `PairingListener.exchangeDeadline`: a ceiling from accept over the whole connection.
    static let exchangeDeadline = TimeAmount.seconds(30)

    enum Failure: Error, Equatable {
        /// The window's three attempts are spent; the user must arm again.
        case attemptsExhausted
        /// `deadline` passed with no key delivered.
        case windowExpired
    }

    /// Opens one window on `port` and returns once the sealed key is out — from the sealed
    /// frame's own write completion, as `PairingListener.onPaired` fires — or throws when the
    /// window burns or expires. `onListening` fires once the port is bound.
    static func run(
        code: PairingCode, key: FleetDeviceKey, hostName: String, port: Int,
        deadline: TimeInterval = 120, onListening: (@Sendable () -> Void)? = nil
    ) async throws {
        // One thread, so every channel — the listener and each peer — shares one event loop and
        // `Window`'s state is confined to it, the NIO spelling of `PairingListener`'s `queue`.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await serve(group: group, code: code, key: key, hostName: hostName, port: port,
                            deadline: deadline, onListening: onListening)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    private static func serve(
        group: MultiThreadedEventLoopGroup, code: PairingCode, key: FleetDeviceKey,
        hostName: String, port: Int, deadline: TimeInterval,
        onListening: (@Sendable () -> Void)?
    ) async throws {
        let loop = group.next()
        let window = Window(loop: loop, code: code, key: key, hostName: hostName)
        // The bootstrap PSK, and only it — the same constant the Darwin initiator registers,
        // read from the shared `PairingChannel` rather than re-derived here. It is public by
        // design (see that type): what authenticates this exchange is SPAKE2, never the channel.
        let identity = String(decoding: PairingChannel.bootstrapIdentity, as: UTF8.self)
        let secret = [UInt8](PairingChannel.bootstrapSecret)
        let keys: @Sendable () -> [String: [UInt8]] = { [identity: secret] }
        // `PSKWebSocketServer.tls`, so the 0xCCAC pin and TLS 1.2 floor/ceiling live in one place
        // for both Linux listeners. Built once up front for the same reason it is there: a
        // configuration BoringSSL rejects fails the window at launch, not every handshake.
        _ = try NIOSSLContext(configuration: PSKWebSocketServer.tls(keys: keys, into: SlotAttribute()))

        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard let peer = window.accept(channel) else {
                    return channel.close()
                }
                let slot = SlotAttribute()
                do {
                    let context = try NIOSSLContext(
                        configuration: PSKWebSocketServer.tls(keys: keys, into: slot))
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(slot)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: maxFrameBytes,
                    shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                    upgradePipelineHandler: { channel, _ in
                        window.ready(peer)
                        return channel.pipeline.addHandler(PairingFrameHandler(window: window, peer: peer))
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
            }
            .bind(host: "0.0.0.0", port: port)
            .get()
        onListening?()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loop.execute {
                window.open(server: server, continuation: continuation)
                loop.scheduleTask(in: .milliseconds(Int64(deadline * 1000))) {
                    window.finish(.failure(Failure.windowExpired))
                }
            }
        }
    }

    /// One connection's progress through the exchange. Loop-confined, like everything in
    /// `Window`; a class so the deadlines and the frame handler see the same flags.
    final class Peer: @unchecked Sendable {
        let channel: Channel
        /// TLS and the upgrade are done: out from under `handshakeDeadline`.
        var ready = false
        /// A frame arrived: out from under `firstFrameDeadline`.
        var spoken = false
        /// Single-use, as in `PairingListener.sessions`. Held only so `transcript` is reachable.
        var session: SPAKE2Session?
        var secrets: PairingSecrets?
        /// Already handed the sealed key. Further frames are ignored, never answered — a
        /// replayed confirmation must not seal a second key (`PairingListener.paired`).
        var paired = false

        init(channel: Channel) { self.channel = channel }
    }

    /// The window: its attempt budget, its pending pool and its one verdict.
    ///
    /// `@unchecked Sendable` with every member touched only on `loop` — each entry point asserts
    /// it, the discipline `PairingListener` keeps with `dispatchPrecondition`.
    final class Window: @unchecked Sendable {
        let loop: EventLoop
        private let code: PairingCode
        private let key: FleetDeviceKey
        private let hostName: String
        private var peers: [ObjectIdentifier: Peer] = [:]
        private var attemptsSpent = 0
        private var server: Channel?
        private var continuation: CheckedContinuation<Void, Error>?
        /// The verdict, reached once; a deadline or a frame arriving after it changes nothing.
        /// Kept, not just flagged, because peers are accepted from the moment the port binds and
        /// `open` hands over the continuation a moment later — a verdict in between must wait.
        private var verdict: Result<Void, Error>?
        private var finished: Bool { verdict != nil }

        init(loop: EventLoop, code: PairingCode, key: FleetDeviceKey, hostName: String) {
            self.loop = loop
            self.code = code
            self.key = key
            self.hostName = hostName
        }

        func open(server: Channel, continuation: CheckedContinuation<Void, Error>) {
            loop.preconditionInEventLoop()
            self.server = server
            guard let verdict else { return self.continuation = continuation }
            server.close(promise: nil)
            continuation.resume(with: verdict)
        }

        /// The pending cap and the two deadlines armed at accept. `nil` refuses the socket.
        func accept(_ channel: Channel) -> Peer? {
            loop.preconditionInEventLoop()
            guard !finished, peers.count < NIOPairingResponder.maxPending else { return nil }
            let peer = Peer(channel: channel)
            let id = ObjectIdentifier(channel)
            peers[id] = peer
            channel.closeFuture.whenComplete { [self] _ in peers.removeValue(forKey: id) }
            loop.scheduleTask(in: NIOPairingResponder.handshakeDeadline) {
                if !peer.ready { channel.close(promise: nil) }
            }
            loop.scheduleTask(in: NIOPairingResponder.exchangeDeadline) {
                channel.close(promise: nil)
            }
            return peer
        }

        /// The upgrade finished, so the peer could speak: start asking why it has not.
        func ready(_ peer: Peer) {
            loop.preconditionInEventLoop()
            peer.ready = true
            loop.scheduleTask(in: NIOPairingResponder.firstFrameDeadline) {
                if !peer.spoken { peer.channel.close(promise: nil) }
            }
        }

        func handle(_ frame: PairingClientFrame, from peer: Peer) {
            loop.preconditionInEventLoop()
            guard !finished else { return drop(peer) }
            guard !peer.paired else { return }
            guard attemptsSpent < NIOPairingResponder.maxAttempts else {
                return reply(.reject(.attemptsExhausted), to: peer)
            }
            switch frame {
            case .pake(let peerMessage):
                guard peer.session == nil else { return drop(peer) }
                let session = SPAKE2Session(
                    role: .responder,
                    myName: NIOPairingResponder.profile.responderName,
                    theirName: NIOPairingResponder.profile.initiatorName
                )
                do {
                    // Generate before processing — the C context's order — and the transcript
                    // from the session, never assembled here (see `PairingListener.handle`).
                    let mine = try session.message(for: code)
                    let material = try session.keyMaterial(from: peerMessage)
                    peer.session = session
                    peer.secrets = PairingSecrets(keyMaterial: material, transcript: try session.transcript)
                    send(.pake(msg: mine), to: peer)
                } catch {
                    // Not a curve point: not a guess, so no attempt is spent.
                    reply(.reject(.malformed), to: peer)
                }

            case .confirm(let claimed):
                guard let derived = peer.secrets else { return drop(peer) }
                guard PairingSecrets.matches(claimed, derived.initiatorConfirmation) else {
                    attemptsSpent += 1
                    let exhausted = attemptsSpent >= NIOPairingResponder.maxAttempts
                    // The verdict waits on the reject's own write, so the frame that tells the
                    // controller to ask for a new code is out before the window closes under it.
                    reply(.reject(exhausted ? .attemptsExhausted : .badCode), to: peer) { [self] in
                        if exhausted { finish(.failure(Failure.attemptsExhausted)) }
                    }
                    return
                }
                let box: Data
                do {
                    box = try derived.seal(key, macName: hostName)
                } catch {
                    return reply(.reject(.malformed), to: peer)
                }
                peer.paired = true
                peer.session = nil
                peer.secrets = nil
                // Success is the sealed frame's write completing, never the line after the
                // send: tearing the window down first would truncate the one frame the exchange
                // exists to deliver (`PairingListener.onPaired`).
                send(.sealed(mac: derived.responderConfirmation, box: box), to: peer) { [self] in
                    finish(.success(()))
                }
            }
        }

        /// Ends the window with one verdict and closes everything. Called on success only
        /// after the sealed frame's write has completed, so closing that peer here cannot
        /// lose it — NIOSSL sends close_notify behind the bytes already written.
        func finish(_ result: Result<Void, Error>) {
            loop.preconditionInEventLoop()
            guard !finished else { return }
            verdict = result
            for peer in peers.values { peer.channel.close(promise: nil) }
            peers.removeAll()
            server?.close(promise: nil)
            continuation?.resume(with: result)
            continuation = nil
        }

        func drop(_ peer: Peer) {
            loop.preconditionInEventLoop()
            peer.channel.close(promise: nil)
        }

        /// One last frame, then close — never a send followed by a close on the next line.
        private func reply(_ frame: PairingServerFrame, to peer: Peer, then: (@Sendable () -> Void)? = nil) {
            send(frame, to: peer) { [self] in
                drop(peer)
                then?()
            }
        }

        private func send(_ frame: PairingServerFrame, to peer: Peer, onSent: (@Sendable () -> Void)? = nil) {
            guard let data = try? JSONEncoder().encode(frame) else {
                return drop(peer)
            }
            let channel = peer.channel
            let buffer = channel.allocator.buffer(bytes: data)
            let written = channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer))
            guard let onSent else { return }
            written.whenComplete { [self] outcome in
                // A write that failed delivered nothing, so it must not count as delivery:
                // success with an unsent key would tell the operator a controller paired when
                // none did.
                if case .failure = outcome { return drop(peer) }
                onSent()
            }
        }
    }
}

/// Text frames decoded into `PairingClientFrame`; pings answered; a close or anything else
/// ends the connection. A frame that does not decode drops the peer, as `FleetSocket.receive`
/// does on the Darwin side — the pairing vocabulary has no frame that can be refused alone.
final class PairingFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let window: NIOPairingResponder.Window
    private let peer: NIOPairingResponder.Peer

    init(window: NIOPairingResponder.Window, peer: NIOPairingResponder.Peer) {
        self.window = window
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text where frame.fin:
            // Promoted before decoding, as in `PairingListener.accept`: what earns the long
            // deadline is that the peer spoke, not that what it said was any good.
            peer.spoken = true
            var bytes = frame.unmaskedData
            guard let decoded = bytes.readBytes(length: bytes.readableBytes)
                    .flatMap({ try? JSONDecoder().decode(PairingClientFrame.self, from: Data($0)) })
            else { return window.drop(peer) }
            window.handle(decoded, from: peer)
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            // A close, a binary frame, or a fragment: every pairing frame is one small whole text
            // message, so none of these is part of an exchange worth continuing.
            window.drop(peer)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("pairing connection: \(error)\n".utf8))
        context.close(promise: nil)
    }
}
