import Foundation
import Network

/// The listener, and one attached-client registry. Knows nothing about what a fleet is —
/// every decision is a closure the app supplies, which is what lets the whole protocol be
/// tested in one process without a store.
///
/// `@unchecked Sendable`: same reasoning as `FleetClient` — Network.framework's handlers are
/// typed `@Sendable`, but every one of them runs on `queue`, so the mutable state they touch
/// (`listener`, `attached`) is confined to that queue rather than shared across threads.
public final class FleetSocketServer: @unchecked Sendable {
    /// How long a peer may hold a completed handshake without sending `hello` before it is
    /// dropped. Settable so the test does not have to wait the production value.
    public var authDeadline: TimeInterval = 5

    /// Answers a client's first frame. Returns the frames to send back — a snapshot, or a
    /// folded replay.
    public var onHello: ((_ client: UUID, _ lastSeq: Int) -> [ServerFrame])?
    /// Answers a command. Returns the single frame to reply with (`ack` or `err`).
    public var onCommand: ((_ client: UUID, _ cid: Int, _ command: FleetCommand) -> ServerFrame)?
    public var onAttachedCountChanged: ((Int) -> Void)?

    private let queue: DispatchQueue
    private var listener: NWListener?
    /// Only clients that have said `hello`. A handshake alone does not make an attachment,
    /// which is what keeps `onAttachedCountChanged` meaningful as "phones watching".
    private var attached: [UUID: NWConnection] = [:]

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// `port: nil` asks the OS for one, which is what the tests use. Returns the port
    /// actually bound, for advertising.
    @discardableResult
    public func start(keys: [FleetDeviceKey], port: NWEndpoint.Port?) throws -> NWEndpoint.Port {
        stop()
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: keys)
        )
        let listener = try port.map { try NWListener(using: parameters, on: $0) }
            ?? NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener

        // `listener.port` goes non-nil the moment the listener has a socket, which is
        // *before* the OS has actually assigned the ephemeral port: in between it reports
        // the `.any` (0) placeholder, and connecting to that port fails immediately with
        // `EADDRNOTAVAIL` rather than any error that looks like "not ready yet". The real
        // port — and the guarantee that something is actually listening — only lands once
        // the listener's state reaches `.ready`, so both conditions have to hold before a
        // caller can be handed a port worth advertising.
        // `nonisolated(unsafe)`: written only from `listener.stateUpdateHandler` and read
        // only from the busy-wait below, both on `queue` (the `.main` default), so this is
        // single-threaded in practice — the same confinement argument as the class's
        // `@unchecked Sendable`, just for a local rather than a stored property.
        nonisolated(unsafe) var isReady = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { isReady = true }
        }
        let deadline = Date().addingTimeInterval(5)
        while (!isReady || listener.port == nil || listener.port == .any), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard isReady, let bound = listener.port, bound != .any else {
            throw FleetSocketError.didNotBind
        }
        return bound
    }

    public func stop() {
        for connection in attached.values { connection.cancel() }
        attached.removeAll()
        listener?.cancel()
        listener = nil
    }

    public func broadcast(_ frame: ServerFrame) {
        for connection in attached.values {
            FleetSocket.send(frame, over: connection)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.start(queue: queue)

        // Drop a peer that completed a handshake and then said nothing. Without this a
        // silent connection holds a slot for as long as the app runs.
        queue.asyncAfter(deadline: .now() + authDeadline) { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.attached[id] == nil else { return }
            connection.cancel()
        }

        FleetSocket.receive(ClientFrame.self, from: connection) { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .hello(let lastSeq):
                if self.attached[id] == nil {
                    self.attached[id] = connection
                    self.onAttachedCountChanged?(self.attached.count)
                }
                for reply in self.onHello?(id, lastSeq) ?? [] {
                    FleetSocket.send(reply, over: connection)
                }
            case .cmd(let cid, let command):
                // A command before `hello` is a client that skipped the handshake step;
                // answering it would let an unattached peer drive the Mac.
                guard self.attached[id] != nil else { return connection.cancel() }
                let reply = self.onCommand?(id, cid, command) ?? .err(cid: cid, code: "unhandled")
                FleetSocket.send(reply, over: connection)
            }
        } onEnd: { [weak self] _ in
            guard let self else { return }
            connection.cancel()
            guard self.attached.removeValue(forKey: id) != nil else { return }
            self.onAttachedCountChanged?(self.attached.count)
        }
    }
}

public enum FleetSocketError: Error {
    case didNotBind
}
