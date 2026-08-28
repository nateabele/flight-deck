import Foundation
import Network
@testable import FleetKit

/// A hand-written phone side, used by `PairingListenerTests` before `PairingInitiator` exists.
///
/// It stays after `PairingInitiator` lands rather than being replaced by it, and that is the
/// point of it: the spec's §5 amendment is explicit that a *consistent* role or name swap
/// inside `SPAKE2Session` survives any exchange where both ends run the same code, and what
/// catches caller-side mistakes is a second implementation of the **caller**. This one drives
/// the initiator half from the protocol description rather than from `PairingInitiator`, so a
/// listener that answered the wrong role, or assembled its transcript the other way round,
/// fails here rather than agreeing with a mirror of itself.
///
/// Frame plumbing only: it holds no SPAKE2 state. The tests own that, which is what lets them
/// send a confirmation the protocol would never produce.
final class PairingTestClient: @unchecked Sendable {
    var onFrame: ((PairingServerFrame) -> Void)?
    var onEnd: (() -> Void)?
    /// Fired when the socket reaches `.ready` — i.e. the bootstrap TLS-PSK handshake and the
    /// WebSocket upgrade both completed, which is the only externally visible difference
    /// between "a listener answered" and "nothing is on that port". `onEnd` alone cannot tell
    /// those apart: a listener that accepts and then drops the connection ends it too.
    var onReady: (() -> Void)?

    private let endpoint: NWEndpoint
    private var connection: NWConnection?
    private var ended = false

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func start() {
        // The cap production dials with (`PairingInitiator`), passed explicitly rather than
        // defaulted: the default is the FLEET number, sized for a page, and a harness that
        // silently sat 256x above the code it stands in for would make the next test that
        // reasons about this socket's bound reason about the wrong one.
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.pairingClientParameters(),
            maximumMessageSize: PairingListener.maxFrameBytes
        )
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: endpoint), using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        FleetSocket.receive(PairingServerFrame.self, from: connection) { [weak self] frame in
            guard let self, !self.ended else { return }
            self.onFrame?(frame)
        } onEnd: { [weak self] _ in
            self?.finish()
        }
        connection.start(queue: .main)
    }

    func send(_ frame: PairingClientFrame) {
        guard let connection else { return }
        FleetSocket.send(frame, over: connection)
    }

    func stop() {
        ended = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd?()
    }
}

/// A bootstrap connection that can say things the pairing protocol does not contain.
///
/// `PairingTestClient` sends `PairingClientFrame`s, which by construction have no `hello` in
/// them — that is the point of the type. Proving invariant 3 needs the opposite: a peer that
/// puts a *fleet* frame on the pairing socket, which is what a mis-wired client or a hostile
/// one would do. So this encodes `ClientFrame.hello` itself and writes it as a raw WebSocket
/// text message.
final class PairingProbe: @unchecked Sendable {
    /// Fired for any bytes that come back at all — not for any *parseable* frame. The
    /// invariant-3 test fails on this being called; the liveness probe succeeds on it.
    var onAnyReply: (() -> Void)?
    var onEnd: (() -> Void)?

    private let port: NWEndpoint.Port
    /// Whether to open with an honest PAKE message the moment the socket is ready.
    ///
    /// Not a default, because getting it wrong is silent in exactly one direction: the
    /// liveness probe NEEDS the `pake` — a reply is the only thing that tells a live pairing
    /// listener apart from a closed port — while the invariant-3 probe must not send one,
    /// since a `pake` draws an answer by design and the whole assertion there is that nothing
    /// comes back. Written as a default, the second call site inherits the first's needs and
    /// fails for a reason that has nothing to do with the invariant.
    private let opensWithPake: Bool
    private var connection: NWConnection?
    private var ended = false

    init(port: NWEndpoint.Port, opensWithPake: Bool) {
        self.port = port
        self.opensWithPake = opensWithPake
    }

    func start() {
        // The cap production dials with (`PairingInitiator`), passed explicitly rather than
        // defaulted: the default is the FLEET number, sized for a page, and a harness that
        // silently sat 256x above the code it stands in for would make the next test that
        // reasons about this socket's bound reason about the wrong one.
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.pairingClientParameters(),
            maximumMessageSize: PairingListener.maxFrameBytes
        )
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: .hostPort(host: "127.0.0.1", port: port)),
            using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // An honest PAKE message under a code this probe invents. The responder
                // answers with its own message either way — it cannot know the code is wrong
                // until the confirmation that never comes — so this draws a reply out of a
                // live listener without spending an attempt.
                guard let self, self.opensWithPake else { return }
                let session = SPAKE2Session(
                    role: .initiator,
                    myName: PairingChannel.initiatorName,
                    theirName: PairingChannel.responderName
                )
                if let message = try? session.message(for: .mint()) {
                    FleetSocket.send(PairingClientFrame.pake(msg: message), over: connection)
                }
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        receive()
        connection.start(queue: .main)
    }

    /// Raw, rather than `FleetSocket.receive(PairingServerFrame.self, …)`, and the difference
    /// is the difference between this probe catching a mis-wired listener and quietly agreeing
    /// with one. A listener that answered a fleet frame replies with a `ServerFrame`, which
    /// does not decode as a `PairingServerFrame` — so the typed receive reports that decode
    /// failure through `onEnd`, which is indistinguishable from the connection ending, which
    /// is precisely what invariant 3 says should happen. Measured: with the typed receive, the
    /// invariant-3 test PASSED against a listener mutated to decode `ClientFrame` and ack it.
    /// Bytes coming back is the question here; whether they parse is not.
    private func receive() {
        connection?.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.ended else { return }
            if error != nil { return self.finish() }
            let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return self.finish() }
            if let data, !data.isEmpty { self.onAnyReply?() }
            self.receive()
        }
    }

    /// The frame the pairing vocabulary cannot express, written straight onto the socket.
    func sendRawFleetHello() {
        guard let connection,
              let data = try? JSONEncoder().encode(ClientFrame.hello(lastSeq: 0, device: "iPhone"))
        else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    func stop() {
        ended = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd?()
    }
}
