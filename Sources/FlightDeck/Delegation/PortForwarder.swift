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
    private let timeWaitRetries: Int
    private let retryInterval: Duration

    /// `timeWaitRetries` × `retryInterval` should cover the kernel's TIME_WAIT (2 × MSL, 30 s
    /// on macOS); only tests shorten it.
    init(timeWaitRetries: Int = 30, retryInterval: Duration = .seconds(1)) {
        self.timeWaitRetries = timeWaitRetries
        self.retryInterval = retryInterval
    }

    private var holders: LocalPortHolder { LocalPortHolder(ownForward: { [weak self] in self?.session(holding: $0) }) }

    /// The session title holding local port `port` through Flight Deck, if any.
    func session(holding port: UInt16) -> String? {
        lock.withLock { owners[port] }
    }

    /// Binds every mapping's local port and holds it. On any failure it releases what it
    /// had bound, and waits for those listeners to close, before throwing: a failed preflight
    /// leaves nothing listening (Review Focus 3), so the retry the error suggests cannot hit
    /// our own dying listener. The error names the holder and a free port to try instead.
    func reserve(_ mappings: [PortMapping], session: String) async throws -> PortForwardReservation {
        let reservation = PortForwardReservation(forwarder: self)
        let claimed = Set(mappings.compactMap { if case .fixed(let p) = $0.local { return p } else { return nil } })
        do {
            for mapping in mappings {
                let requested: UInt16
                if case .fixed(let p) = mapping.local { requested = p } else { requested = 0 }
                try await bind(reservation, local: requested, remote: mapping.remote, claimed: claimed)
            }
        } catch {
            reservation.release()
            await reservation.released()
            throw error
        }
        lock.withLock { for f in reservation.forwards { owners[f.local] = session } }
        return reservation
    }

    /// One bind, retried while the port is in TIME_WAIT. Network framework cannot bind over a
    /// TIME_WAIT another program left (measured), and a dev server the user just stopped
    /// leaves one for 30 s. Nothing listens then, so the conflict message would blame "another
    /// process" that does not exist. "Nothing listens" is the same four-address probe the
    /// host uses: lsof alone cannot see another user's sockets, and would make a real
    /// conflict wait out 30 s of retries.
    private func bind(_ reservation: PortForwardReservation, local: UInt16, remote: UInt16,
                      claimed: Set<UInt16>) async throws {
        var retries = 0
        while true {
            do {
                try await reservation.bind(local: local, remote: remote)
                return
            } catch {
                if error is CancellationError { throw error }
                guard case .posix(.EADDRINUSE)? = error as? NWError else {
                    throw DelegationError(code: "port_bind_failed",
                                          message: "cannot listen on localhost:\(local): \(error) — try --port auto:\(remote)")
                }
                let holder = await holders.holder(of: local)
                if holder != .free {
                    throw DelegationError.localPortHeld(local: local, remote: remote, holder: holder,
                                                        suggestion: holders.suggestion(for: local, claimed: claimed))
                }
                guard retries < timeWaitRetries else {
                    throw DelegationError.localPortInTimeWait(local: local, remote: remote)
                }
                retries += 1
                try await Task.sleep(for: retryInterval)
            }
        }
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
    /// Each served connection and its task, under one key, added together before the task
    /// can run and removed together by the task's own exit. Kept apart, a connection that
    /// finished before it was registered stayed registered forever, and `tasks` grew by one
    /// per connection for the life of the service.
    private var live: [ObjectIdentifier: NWConnection] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var connect: (@Sendable (UInt16) -> any ChannelOpening)?
    private var isReleased = false
    /// Entered per listener and left at its `.cancelled`, for `released()`.
    private let closed = DispatchGroup()

    fileprivate init(forwarder: PortForwarder) {
        self.forwarder = forwarder
    }

    /// Connections being served and their tasks; both drain to zero as connections end.
    var bookkeeping: (live: Int, tasks: Int) { lock.withLock { (live.count, tasks.count) } }

    /// Returns once every listener this reservation bound has closed, and its port is free
    /// again. `release()` does not wait: it is called from the main actor, on tab close.
    func released() async {
        await withCheckedContinuation { cont in closed.notify(queue: queue) { cont.resume() } }
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
            guard !isReleased else { return [] }
            self.connect = connect
            defer { pending = [] }
            return pending
        }
        for (conn, remote) in waiting { serve(conn, remote: remote, opening: connect(remote)) }
    }

    /// Cancels every listener and connection without waiting for them to close; await
    /// `released()` when the port must be free on return.
    func release() {
        let (toClose, conns, running): ([NWListener], [NWConnection], [Task<Void, Never>]) = lock.withLock {
            guard !isReleased else { return ([], [], []) }
            isReleased = true
            defer { pending = []; live = [:]; tasks = [:]; connect = nil }
            return (listeners.map(\.listener), pending.map(\.0) + live.values, Array(tasks.values))
        }
        forwarder?.forget(forwards)
        running.forEach { $0.cancel() }
        conns.forEach { $0.cancel() }
        toClose.forEach { $0.cancel() }
    }

    private func accepted(_ conn: NWConnection, remote: UInt16) {
        enum Next { case drop, wait, serve(@Sendable (UInt16) -> any ChannelOpening) }
        let next: Next = lock.withLock {
            if isReleased { return .drop }
            guard let connect else { pending.append((conn, remote)); return .wait }
            return .serve(connect)
        }
        switch next {
        case .drop: conn.cancel()
        case .wait: break
        // Outside the lock: `connect` is the caller's code, and may take any lock of its own.
        case .serve(let connect): serve(conn, remote: remote, opening: connect(remote))
        }
    }

    /// Pipes one connection through one channel until both directions have ended. Each
    /// direction half-closes the other side at its EOF, so a client that shuts down its write
    /// half still reads the reply; an error in either direction tears down both.
    private func serve(_ conn: NWConnection, remote: UInt16, opening: any ChannelOpening) {
        let key = ObjectIdentifier(conn)
        // The task is created under the lock, so its exit (which takes the lock) cannot run
        // before both entries exist.
        let started: Bool = lock.withLock {
            if isReleased { return false }
            live[key] = conn
            tasks[key] = Task { [weak self, queue] in
                defer {
                    conn.cancel()
                    self?.lock.withLock {
                        _ = self?.live.removeValue(forKey: key)
                        _ = self?.tasks.removeValue(forKey: key)
                    }
                }
                conn.start(queue: queue)
                await Self.pipe(conn, remote: remote, opening: opening)
            }
            return true
        }
        if !started { conn.cancel() }
    }

    private static func pipe(_ conn: NWConnection, remote: UInt16, opening: any ChannelOpening) async {
        let channel: any ByteChannel
        do { channel = try await opening.open() } catch {
            log.error("forward to remote port \(remote) could not open a channel: \(String(describing: error))")
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    var complete = false
                    while !complete {
                        let (chunk, end) = try await conn.receiveChunk()
                        if !chunk.isEmpty { try await channel.write(chunk) }
                        complete = end
                    }
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
}

/// Resumes a continuation at most once across a listener's state callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

private extension NWConnection {
    /// The next bytes (possibly empty), and whether the peer has closed its write half. The
    /// two come together: the final bytes often arrive *with* the completion, and asking
    /// again after it fails rather than repeating it, which used to cancel the channel and
    /// drop the reply in the other direction. An empty chunk is not written through, where it
    /// would reach the host as a zero-length data frame.
    func receiveChunk() async throws -> (Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { cont in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data ?? Data(), isComplete)) }
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
