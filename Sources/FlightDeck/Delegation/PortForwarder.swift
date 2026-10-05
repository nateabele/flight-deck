import Foundation
import HostKit
import Network
import OSLog

/// A service's local port forwards (spec §6.2, §7 step 4): one `127.0.0.1:L` listener per
/// port, bound at preflight and held until the reservation is released. Each accepted
/// connection becomes a channel to the host, which dials `127.0.0.1:R` there.
///
/// One per app. It remembers which session holds which local port, so a conflict with
/// Flight Deck's own forward names the session (`LocalPortHolder`).
final class PortForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [UInt16: String] = [:]

    private var holders: LocalPortHolder { LocalPortHolder(ownForward: { [weak self] in self?.session(holding: $0) }) }

    /// The session title holding local port `port` through Flight Deck, if any.
    func session(holding port: UInt16) -> String? {
        lock.withLock { owners[port] }
    }

    /// Binds every mapping's local port and holds it. On any failure it releases what it
    /// had bound before throwing, so a failed preflight leaves nothing listening (Review
    /// Focus 3), and the error names the holder and a free port to try instead.
    func reserve(_ mappings: [PortMapping], session: String) async throws -> PortForwardReservation {
        let reservation = PortForwardReservation(forwarder: self)
        let claimed = Set(mappings.compactMap { if case .fixed(let p) = $0.local { return p } else { return nil } })
        for mapping in mappings {
            let requested: UInt16
            if case .fixed(let p) = mapping.local { requested = p } else { requested = 0 }
            do {
                try await reservation.bind(local: requested, remote: mapping.remote)
            } catch {
                reservation.release()
                if case .posix(.EADDRINUSE)? = error as? NWError {
                    let holder = await holders.holder(of: requested)
                    let suggestion = holders.suggestion(for: requested, claimed: claimed)
                    throw DelegationError.localPortHeld(local: requested, remote: mapping.remote,
                                                        holder: holder, suggestion: suggestion)
                }
                throw DelegationError(code: "port_bind_failed",
                                      message: "cannot listen on localhost:\(requested): \(error); try --port auto:\(mapping.remote)")
            }
        }
        lock.withLock { for f in reservation.forwards { owners[f.local] = session } }
        return reservation
    }

    fileprivate func forget(_ forwards: [PortForward]) {
        lock.withLock { for f in forwards { owners[f.local] = nil } }
    }
}

/// The held listeners of one preflight. Connections that arrive before `startForwarding`
/// wait (accepted, unread) and are served once it is called; `release` closes everything.
final class PortForwardReservation: PortReservation, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "PortForwarder")

    private weak var forwarder: PortForwarder?
    private let queue = DispatchQueue(label: "dev.flightdeck.PortForwarder")
    private let lock = NSLock()
    private var listeners: [(listener: NWListener, forward: PortForward)] = []
    private var pending: [(NWConnection, remote: UInt16)] = []
    private var live: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var connect: (@Sendable (UInt16) -> any ChannelOpening)?
    private var released = false
    /// Left by each listener's `.cancelled`, so `release` can return only once the ports are
    /// really free: a retry right after a 125 must not collide with our own dying listener.
    private let closed = DispatchGroup()

    fileprivate init(forwarder: PortForwarder) {
        self.forwarder = forwarder
    }

    var forwards: [PortForward] { lock.withLock { listeners.map(\.forward) } }

    /// Binds `127.0.0.1:local` (0 = any free port) and returns once the listener is ready,
    /// throwing the bind's `NWError` when it fails. `acceptLocalOnly` plus the loopback
    /// endpoint: a forward must never be reachable from the network.
    fileprivate func bind(local: UInt16, remote: UInt16) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: local) ?? .any)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accepted(conn, remote: remote) }
        closed.enter()
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() {
                        let bound = listener.port?.rawValue ?? local
                        self?.lock.withLock { self?.listeners.append((listener, PortForward(local: bound, remote: remote))) }
                        cont.resume()
                    }
                case .failed(let error), .waiting(let error):
                    // `.waiting` on a listener is a bind that will not succeed by retrying
                    // in any useful time; preflight must fail now, not hang.
                    if once.claim() { cont.resume(throwing: error) }
                    listener.cancel()
                case .cancelled:
                    if once.claim() { cont.resume(throwing: NWError.posix(.ECANCELED)) }
                    self?.closed.leave()
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func startForwarding(_ connect: @escaping @Sendable (UInt16) -> any ChannelOpening) {
        let waiting: [(NWConnection, remote: UInt16)] = lock.withLock {
            guard !released else { return [] }
            self.connect = connect
            defer { pending = [] }
            return pending
        }
        for (conn, remote) in waiting { serve(conn, remote: remote, opening: connect(remote)) }
    }

    func release() {
        let (toClose, conns, running): ([NWListener], [NWConnection], [Task<Void, Never>]) = lock.withLock {
            guard !released else { return ([], [], []) }
            released = true
            defer { pending = []; live = [:]; tasks = []; connect = nil }
            return (listeners.map(\.listener), pending.map(\.0) + live.values, tasks)
        }
        guard !toClose.isEmpty || !conns.isEmpty || !running.isEmpty else { return }
        forwarder?.forget(forwards)
        running.forEach { $0.cancel() }
        conns.forEach { $0.cancel() }
        toClose.forEach { $0.cancel() }
        if closed.wait(timeout: .now() + 2) == .timedOut {
            Self.log.error("port forward listeners did not close within 2s")
        }
    }

    private func accepted(_ conn: NWConnection, remote: UInt16) {
        enum Next { case drop, wait, serve(any ChannelOpening) }
        let next: Next = lock.withLock {
            if released { return .drop }
            guard let connect else { pending.append((conn, remote)); return .wait }
            return .serve(connect(remote))
        }
        switch next {
        case .drop: conn.cancel()
        case .wait: break
        case .serve(let opening): serve(conn, remote: remote, opening: opening)
        }
    }

    /// Pipes one connection through one channel until both directions have ended. Each
    /// direction half-closes the other side at its EOF, so a client that shuts down its write
    /// half still reads the reply; an error in either direction tears down both.
    private func serve(_ conn: NWConnection, remote: UInt16, opening: any ChannelOpening) {
        let key = ObjectIdentifier(conn)
        let task = Task { [weak self] in
            conn.start(queue: self?.queue ?? .global())
            defer {
                conn.cancel()
                self?.lock.withLock { _ = self?.live.removeValue(forKey: key) }
            }
            let channel: any ByteChannel
            do { channel = try await opening.open() } catch {
                Self.log.error("forward to remote port \(remote) could not open a channel: \(String(describing: error))")
                return
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        while let chunk = try await conn.receiveChunk() { try await channel.write(chunk) }
                        await channel.finish()
                    } catch { channel.cancel(); conn.cancel() }
                }
                group.addTask {
                    do {
                        while let chunk = try await channel.read() { try await conn.sendChunk(chunk) }
                        try await conn.sendEOF()
                    } catch { channel.cancel(); conn.cancel() }
                }
                await group.waitForAll()
            }
            if Task.isCancelled { channel.cancel() }
        }
        let alreadyReleased: Bool = lock.withLock {
            if released { return true }
            live[key] = conn
            tasks.append(task)
            return false
        }
        if alreadyReleased { task.cancel(); conn.cancel() }
    }
}

/// Resumes a continuation at most once across a listener's state callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

private extension NWConnection {
    /// The next non-empty bytes, or nil once the peer has closed its write half. An empty,
    /// incomplete read is skipped: written through, it would reach the host as a zero-length
    /// data frame.
    func receiveChunk() async throws -> Data? {
        while true {
            let chunk = try await receiveOnce()
            if chunk?.isEmpty != true { return chunk }
        }
    }

    private func receiveOnce() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    func sendChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Half-close: the peer reads EOF, and can still send.
    func sendEOF() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}
