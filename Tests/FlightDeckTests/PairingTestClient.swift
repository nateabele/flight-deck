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
        let parameters = FleetSocket.webSocketParameters(FleetTLS.pairingClientParameters())
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
