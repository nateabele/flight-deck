import Foundation
import Network
@testable import FleetKit

/// A TCP relay in front of the pairing listener that makes the *handshake* slow, on purpose
/// and to the millisecond.
///
/// It exists because the bug it pins cannot be reproduced by a slow client. The Mac's
/// `newConnectionHandler` fires when TCP connects, before TLS-PSK and before the WebSocket
/// upgrade, so a deadline armed at `accept` is spent on work the peer has no socket to do
/// anything about. Reproducing that needs a peer whose TCP connection reaches the Mac
/// immediately and whose *first TLS byte* arrives much later — which is what a phone on a
/// bad link looks like, and which nothing on the client side can simulate: `NWConnection`
/// starts its handshake the instant its transport is up.
///
/// So this connects upstream the moment it accepts — the Mac sees a live TCP connection at
/// t=0 and arms whatever it arms — and then holds everything the client sends for `delay`
/// before letting the first byte through. Both directions are pumped verbatim afterwards; it
/// is deliberately ignorant of TLS, WebSocket and the pairing protocol alike.
///
/// `@unchecked Sendable` on the same terms as the other helpers here: every mutation happens
/// in a Network.framework callback, and all of them are delivered on `queue`.
final class SlowHandshakeRelay: @unchecked Sendable {
    private let upstreamPort: NWEndpoint.Port
    private let delay: TimeInterval
    private let queue: DispatchQueue = .main
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init(upstream: NWEndpoint.Port, holdingTheFirstBytesFor delay: TimeInterval) {
        self.upstreamPort = upstream
        self.delay = delay
    }

    /// Binds an OS-assigned port and returns it, resolved from `.ready` for the same reason
    /// `PairingListener.bind` does it that way: `listener.port` reports the `.any` placeholder
    /// until the OS assigns a real one, and dialling that fails immediately.
    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp)
            } catch {
                return continuation.resume(throwing: error)
            }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    guard let port = listener.port, port != .any else { return }
                    resumed = true
                    continuation.resume(returning: port)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        for connection in connections { connection.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ downstream: NWConnection) {
        // Upstream is dialled here, not when the first byte arrives: the whole point is that
        // the Mac accepts a connection it will then watch stay unusable.
        let upstream = NWConnection(
            host: "127.0.0.1", port: upstreamPort, using: .tcp
        )
        connections.append(downstream)
        connections.append(upstream)

        // Everything the client sends before the gate opens waits here. In practice that is
        // the TLS ClientHello and nothing else, since the client cannot get further without an
        // answer to it.
        nonisolated(unsafe) var held = Data()
        nonisolated(unsafe) var open = false

        downstream.start(queue: queue)
        upstream.start(queue: queue)
        queue.asyncAfter(deadline: .now() + delay) {
            open = true
            guard !held.isEmpty else { return }
            upstream.send(content: held, completion: .contentProcessed { _ in })
            held = Data()
        }

        pump(from: downstream, to: upstream) { data in
            guard open else {
                held.append(data)
                return nil
            }
            return data
        }
        pump(from: upstream, to: downstream) { $0 }
    }

    /// One direction of the relay. `gate` decides what (if anything) goes out now; returning
    /// `nil` means the bytes were withheld, which only the client-to-Mac direction ever does.
    private func pump(
        from source: NWConnection, to destination: NWConnection,
        through gate: @escaping @Sendable (Data) -> Data?
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty, let forwarded = gate(data) {
                destination.send(content: forwarded, completion: .contentProcessed { _ in })
            }
            guard error == nil, !isComplete else {
                // Either end going away takes the pair with it, so a Mac that hangs up
                // mid-handshake surfaces on the client as its connection ending rather than
                // as a hang that only the test's timeout can tell apart from slowness.
                source.cancel()
                destination.cancel()
                return
            }
            self?.pump(from: source, to: destination, through: gate)
        }
    }
}
