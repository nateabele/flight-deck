import Foundation
import Network
import Security

/// Who is on the other end of one socket.
public struct FleetAttachment: Equatable, Sendable {
    /// This connection. Unique per socket, so two phones sharing a slot are still distinct.
    public let id: UUID
    /// The paired slot the TLS layer negotiated, when it will say. `nil` means the identity
    /// could not be read back — the connection is still authenticated (it could not have
    /// completed a handshake otherwise), it just cannot be attributed to a named device.
    public let slot: UUID?
}

/// The listener, and one attached-client registry. Knows nothing about what a fleet is —
/// every decision is a closure the app supplies, which is what lets the whole protocol be
/// tested in one process without a store.
///
/// `@unchecked Sendable`: same reasoning as `FleetClient` — Network.framework's handlers are
/// typed `@Sendable`, but every one of them runs on `queue`, so the mutable state they touch
/// (`listener`, `attached`) is confined to that queue rather than shared across threads.
///
/// Invariant: every caller-supplied closure (`onHello`, `onCommand`,
/// `onAttachedCountChanged`) is invoked on `queue`, enforced at each invocation site with
/// `dispatchPrecondition(condition: .onQueue(queue))`.
public final class FleetSocketServer: @unchecked Sendable {
    /// How long a peer may hold a completed handshake without sending `hello` before it is
    /// dropped. Settable so the test does not have to wait the production value.
    public var authDeadline: TimeInterval = 5

    /// Answers a client's first frame. Returns the frames to send back — a snapshot, or a
    /// folded replay.
    public var onHello: ((_ client: FleetAttachment, _ lastSeq: Int) -> [ServerFrame])?
    /// Answers a command. Returns the single frame to reply with (`ack` or `err`).
    public var onCommand: (
        (_ client: FleetAttachment, _ cid: Int, _ command: FleetCommand) -> ServerFrame
    )?
    public var onAttachedCountChanged: ((Int) -> Void)?

    /// How many accepted-but-not-yet-`hello`'d connections may be outstanding at once.
    /// Each has completed a TLS-PSK handshake — it cannot be a stranger — so this bounds a
    /// paired-but-misbehaving device opening connections faster than `authDeadline` reaps
    /// them, not an unauthenticated one.
    private let maxPending = 16

    private let queue: DispatchQueue
    private var listener: NWListener?
    /// Only clients that have said `hello`. A handshake alone does not make an attachment,
    /// which is what keeps `onAttachedCountChanged` meaningful as "phones watching".
    private var attached: [UUID: NWConnection] = [:]
    /// Every accepted connection that has not yet said `hello`, so `stop()` has something to
    /// cancel for it. Without this, a connection accepted mid-handshake — key rotation
    /// restarts the listener on every arm, expiry, and revocation, so this is routine, not
    /// theoretical — has no reference left holding it once the server is gone: its own
    /// `authDeadline` closure captures `self` and `connection` weakly, so a deallocated
    /// server's deadline firing does nothing, and the receive loop's strong capture of
    /// `connection` keeps the socket alive with nothing left able to cancel it.
    private var pending: [UUID: NWConnection] = [:]

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// `port: nil` asks the OS for one, which is what the tests use. Returns the port
    /// actually bound, for advertising.
    ///
    /// `async` rather than a busy-wait: this is started from the main actor in the app, where
    /// blocking the calling thread for up to five seconds waiting for a bind is a visible UI
    /// stall, not a background hiccup.
    @discardableResult
    public func start(keys: [FleetDeviceKey], port: NWEndpoint.Port?) async throws -> NWEndpoint.Port {
        // `stop()`'s `listener?.cancel()` is fire-and-forget — Network.framework releases the
        // port asynchronously, on its own schedule. `reloadKeys()` restarts this listener on
        // the *same* port on every arm, expiry and revocation, so this is not a hypothetical
        // race: cancelling and immediately rebinding regularly lost it outright, with
        // `EADDRINUSE` surfacing before the state handler below ever saw `.waiting` — two
        // sockets cannot both be LISTENing on one port at once, `allowLocalEndpointReuse`
        // notwithstanding (that flag is about reusing a port stuck in TIME_WAIT, not about a
        // still-live listener). `releaseListener()` waits for the OS to actually confirm the
        // old listener is gone before this one tries to bind.
        await releaseListener()
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: keys)
        )
        let listener = try port.map { try NWListener(using: parameters, on: $0) }
            ?? NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener

        // Awaiting the state handler rather than pumping a run loop: `listener.port` goes
        // non-nil the moment the listener has a socket, which is *before* the OS has
        // actually assigned the ephemeral port — in between it reports the `.any` (0)
        // placeholder, and connecting to that port fails immediately with `EADDRNOTAVAIL`.
        // The real port, and the guarantee that something is actually listening, only land
        // once the listener's state reaches `.ready`.
        //
        // A continuation must be resumed exactly once or the program traps, and
        // `stateUpdateHandler` fires repeatedly (`.setup`, `.waiting`, `.ready`, and
        // potentially `.failed`/`.cancelled` later) — hence the `resumed` guard.
        let bound: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            // `nonisolated(unsafe)`: written and read only from `stateUpdateHandler` and the
            // bind-timeout work item below, both of which Network.framework/`queue` always
            // invoke serially on `queue` — the same single-queue confinement argument as the
            // class's `@unchecked Sendable` — but the compiler cannot see that a `@Sendable`
            // closure calls back onto one queue, hence the flag.
            nonisolated(unsafe) var resumed = false
            // Forward-declared: the state handler below cancels it, and Swift requires the
            // variable to exist lexically before a closure can reference it, even though the
            // work item itself is only constructed after `listener.start`. Both closures run
            // on `queue`, which is what keeps `resumed` (and this) safe without a lock.
            nonisolated(unsafe) var timeout: DispatchWorkItem!
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    // `.any` (0) is the placeholder `listener.port` can report in the moment
                    // before the OS assigns the real ephemeral port; without this guard a
                    // `.ready` caught in that window would resume success with an unusable
                    // port instead of waiting for a real one.
                    guard let port = listener.port, port != .any else { return }
                    resumed = true
                    // Cancelled on every resume path, not just this one: a bind that
                    // succeeds (or fails) immediately must not leave the listener and this
                    // continuation retained by a work item that still has five seconds left
                    // to run — see the doc comment on `timeout` below.
                    timeout.cancel()
                    continuation.resume(returning: port)
                case .failed(let error):
                    resumed = true
                    timeout.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    timeout.cancel()
                    continuation.resume(throwing: FleetSocketError.didNotBind)
                default:
                    break
                }
            }
            listener.start(queue: queue)

            // Bounded on purpose. `.waiting` is Network.framework's "this may resolve itself"
            // state — a port not yet released by the listener we just stopped is the ordinary
            // way in, since a key rotation rebinds the same port. Without this, `start()`
            // never returns and the listener silently never comes up; the busy-wait this
            // replaced had a five-second bound and dropping it was a regression.
            //
            // A `DispatchWorkItem` rather than a bare closure so the success/failure paths
            // above can cancel it: a bare closure handed to `asyncAfter` has nothing to
            // cancel, so it would fire five seconds after every successful bind, no-op
            // against `resumed`, but keep this listener and continuation alive until then —
            // and `reloadKeys()` now calls `start` on every arm, expiry and revocation, so
            // those overlapping retentions stopped being theoretical the moment pairing
            // landed.
            timeout = DispatchWorkItem { [weak listener] in
                guard !resumed else { return }
                resumed = true
                listener?.cancel()
                continuation.resume(throwing: FleetSocketError.didNotBind)
            }
            queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        }
        return bound
    }

    public func stop() {
        cancelConnections()
        listener?.cancel()
        listener = nil
    }

    /// Shared by `stop()` and `releaseListener()`: every attached and pending connection
    /// belongs to the listener being torn down, so both paths must drop the same two
    /// dictionaries or one of them would leak sockets the other already forgot about.
    private func cancelConnections() {
        for connection in attached.values { connection.cancel() }
        attached.removeAll()
        for connection in pending.values { connection.cancel() }
        pending.removeAll()
    }

    /// `start()`'s replacement for a bare `stop()`: waits for the OS to confirm the old
    /// listener is actually gone before returning, so the caller's rebind on the same port
    /// (routine — `reloadKeys()` does this on every arm, expiry and revocation) does not race
    /// a cancellation that is still in flight. See the comment at `start()`'s call site.
    private func releaseListener() async {
        cancelConnections()
        guard let listener else { return }
        self.listener = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Same single-resume hazard as the bind continuation above, and the same fix:
            // `.cancelled` and `.failed` can each fire, and firing twice would trap.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .cancelled, .failed:
                    resumed = true
                    continuation.resume()
                default:
                    break
                }
            }
            listener.cancel()
        }
    }

    public func broadcast(_ frame: ServerFrame) {
        for connection in attached.values {
            FleetSocket.send(frame, over: connection)
        }
    }

    /// Recovers the PSK identity TLS negotiated, which is the paired slot's UUID.
    ///
    /// The alternative — having the client name its own slot in `hello` — would let a
    /// client mislabel which of the user's phones is attached. It cannot forge access
    /// either way (TLS already proved it holds a paired key), so this is about attribution,
    /// not authorization.
    private func slot(of connection: NWConnection) -> UUID? {
        guard
            let tls = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return nil }
        var identity: Data?
        sec_protocol_metadata_access_pre_shared_keys(tls.securityProtocolMetadata) { _, pskIdentity in
            identity = Data(pskIdentity as DispatchData)
        }
        guard let identity else { return nil }
        return UUID(uuidString: String(decoding: identity, as: UTF8.self))
    }

    private func accept(_ connection: NWConnection) {
        // Each entry here has, at most, completed a TLS-PSK handshake — it cannot be a
        // stranger, since that handshake requires holding a paired key. So this bounds a
        // paired-but-misbehaving device opening connections faster than `authDeadline`
        // reaps them, not an unauthenticated one: `authDeadline` already bounds how long
        // any one of them lingers, but nothing previously bounded how many could pile up
        // in that window at once.
        guard pending.count < maxPending else {
            connection.cancel()
            return
        }
        let id = UUID()
        pending[id] = connection
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
            // Every closure this type invokes is called on `queue`, and every current consumer
            // treats that as "the main actor" — one of them mutates the app's session store.
            // `init(queue:)` enforces neither serial-ness nor main-ness, so a caller passing a
            // concurrent or background queue would turn those into silent races rather than a
            // compile error. Fail on the first connection instead.
            dispatchPrecondition(condition: .onQueue(self.queue))
            let attachment = FleetAttachment(id: id, slot: self.slot(of: connection))
            switch frame {
            case .hello(let lastSeq):
                if self.attached[id] == nil {
                    self.pending.removeValue(forKey: id)
                    self.attached[id] = connection
                    self.onAttachedCountChanged?(self.attached.count)
                }
                for reply in self.onHello?(attachment, lastSeq) ?? [] {
                    FleetSocket.send(reply, over: connection)
                }
            case .cmd(let cid, let command):
                // A command before `hello` is a client that skipped the handshake step;
                // answering it would let an unattached peer drive the Mac.
                guard self.attached[id] != nil else { return connection.cancel() }
                let reply = self.onCommand?(attachment, cid, command) ?? .err(cid: cid, code: "unhandled")
                FleetSocket.send(reply, over: connection)
            }
        } onEnd: { [weak self] _ in
            guard let self else { return }
            // Every closure this type invokes is called on `queue`, and every current consumer
            // treats that as "the main actor" — one of them mutates the app's session store.
            // `init(queue:)` enforces neither serial-ness nor main-ness, so a caller passing a
            // concurrent or background queue would turn those into silent races rather than a
            // compile error. Fail on the first connection instead.
            dispatchPrecondition(condition: .onQueue(self.queue))
            connection.cancel()
            self.pending.removeValue(forKey: id)
            guard self.attached.removeValue(forKey: id) != nil else { return }
            self.onAttachedCountChanged?(self.attached.count)
        }
    }
}

public enum FleetSocketError: Error {
    case didNotBind
}
