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
    /// What the client called itself in its `hello`. `nil` means it claimed nothing.
    ///
    /// Not the same kind of fact as `slot`, and the difference matters to anyone reading a
    /// consumer of this type: `slot` is *authenticated* — it comes out of the TLS-PSK
    /// handshake, so it is what this peer provably is. `name` is merely *claimed* — the
    /// client typed it onto the wire, and nothing checks it. Display it, never authorize on
    /// it.
    public let name: String?
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
/// `onAttachedSlotsChanged`) is invoked on `queue`, enforced at each invocation site with
/// `dispatchPrecondition(condition: .onQueue(queue))`.
///
/// That confinement is a coincidence of `queue`'s default (`.main`, called from a
/// `@MainActor` consumer) unless it is actually enforced: `init(queue:)` accepts any
/// `DispatchQueue`, and a caller that supplies a custom one while still calling
/// `stop()`/`broadcast()` from `@MainActor` would get real data races on `listener`,
/// `attached` and `pending` — with zero compiler signal, since `@unchecked Sendable` is a
/// promise, not a check. `stop()` and `broadcast()` are synchronous, so each asserts
/// `dispatchPrecondition(condition: .onQueue(queue))` as its first line — the same discipline
/// `FleetConnector` applies to its own entry points, for the same reason: two sibling types
/// confined to one queue should not disagree about who is responsible for proving it.
/// `start()` cannot use that same assertion: it is a plain `nonisolated async` method, and
/// Swift's concurrency runtime does not preserve a caller's queue across one of those — so it
/// forces its own work onto `queue` via `queue.async` instead of trusting the caller got
/// there first. See `start()`'s own doc comment for why the more obvious fix (hopping onto
/// `queue` with a continuation, then asserting) does not work either.
public final class FleetSocketServer: @unchecked Sendable {
    /// The service the phone browses for. One constant, referenced by both ends, because a
    /// service type that differs by a character between advertiser and browser fails by
    /// finding nothing — which is indistinguishable from being on the wrong network.
    public static let bonjourType = "_flightdeck._tcp"

    /// How long a peer may hold a completed handshake without sending `hello` before it is
    /// dropped — measured from `.ready`, the moment the TLS-PSK handshake and the WebSocket
    /// upgrade have both finished and the socket can actually carry a frame.
    ///
    /// "Measured from `.ready`" is the whole of a bug this used to have. The sentence above
    /// described the intent correctly and `accept` implemented something else: `accept` fires
    /// when TCP connects, so arming this there spent the five seconds on a handshake the peer
    /// cannot hurry and during which it has no socket to say `hello` on. The identical shape on
    /// `PairingListener` was measured against a booted simulator — the phone's flow reported
    /// `flow:failed_connect @5.273s, error server closed session with no notification`, a live
    /// pairing cut off mid-upgrade — and this is the listener a *paired* phone reconnects
    /// through, where the same slow first handshake presents as a phone that pairs and then
    /// cannot attach, with no error at either end because the Mac simply hangs up.
    /// `handshakeDeadline` now covers the phase before `.ready`.
    ///
    /// Five seconds is generous for what it actually bounds: `FleetClient` sends `hello` from
    /// `stateUpdateHandler`'s `.ready` with nothing in between, so this is one queued send.
    ///
    /// Settable so the test does not have to wait the production value.
    public var authDeadline: TimeInterval = 5

    /// How long a peer may hold one of the `maxPending` slots **before its socket is even
    /// usable** — from `accept`, which fires at TCP connect, to `.ready`.
    ///
    /// Ten seconds, and the number is picked so the Mac is never the side that gives up first
    /// on a slow-but-live phone. `FleetConnector.raceTimeout` gives the phone's whole reconnect
    /// race — every candidate's TCP connect, TLS-PSK, WebSocket upgrade, `hello` and the
    /// snapshot that answers it — 8 seconds, after which it tears the racers down and backs
    /// off. A peer that has not reached `.ready` here by ten has therefore already abandoned
    /// its own attempt, and anything this drops was lost anyway. (`PairingListener`'s
    /// `handshakeDeadline` is also 10, but justified against its own client's 8-second
    /// `PairingInitiator.exchangeTimeout`: same number, separate reason, and invariant 4 keeps
    /// the two listeners' deadlines independent.)
    ///
    /// It is a separate number rather than a longer `authDeadline` because it is the one that
    /// bounds the *unauthenticated* phase. Everything past `.ready` held a paired key to get
    /// there; everything before it has proved nothing beyond completing a TCP handshake. So
    /// this is what a stranger on the LAN can occupy — see `maxPending` — and lengthening the
    /// deadline that peers *have* earned would not have fixed the hang-up anyway.
    ///
    /// Ten is the price of not cutting off real phones, and it is paid on the one phase where
    /// no better signal exists: nothing about a TCP connection distinguishes a phone on a bad
    /// link from a squatter.
    ///
    /// Settable so the test does not have to wait the production value.
    public var handshakeDeadline: TimeInterval = 10

    /// Answers a client's first frame. Returns the frames to send back — a snapshot, or a
    /// folded replay.
    public var onHello: ((_ client: FleetAttachment, _ lastSeq: Int) -> [ServerFrame])?
    /// Answers a command. Returns the single frame to reply with (`ack` or `err`).
    public var onCommand: (
        (_ client: FleetAttachment, _ cid: Int, _ command: FleetCommand) -> ServerFrame
    )?
    /// Answers a request. Unlike `onCommand`, the answer comes back through `reply` rather
    /// than as a return value, and that difference is forced rather than stylistic: a command
    /// is dispatched on the way out of the frame handler, while a page is a file read that
    /// would otherwise block `queue` — which in production is the main queue.
    ///
    /// `reply` must be called on `queue`, and it asserts that. It answers at most once —
    /// a second call is dropped rather than trusted — and calling it after the connection has
    /// ended is safe and does nothing, because a phone can leave inside the moment a page
    /// takes to read and that is the ordinary case, not an error.
    public var onRequest: (
        (_ client: FleetAttachment, _ cid: Int, _ request: FleetRequest,
         _ reply: @escaping (ServerFrame) -> Void) -> Void
    )?
    /// The paired slots currently attached — a set, not a count, because a count is the
    /// wrong signal for a UI that needs per-slot truth: with two phones attached, only one
    /// disconnecting must still update the survivor's own row. Fired wherever `attached`
    /// changes, including inside `cancelConnections()` — a listener restart (every arm,
    /// expiry and revocation calls one) drops every attachment at once, and that drop is as
    /// much a change as any single connection ending.
    public var onAttachedSlotsChanged: ((Set<UUID>) -> Void)?

    /// How many accepted-but-not-yet-`hello`'d connections may be outstanding at once.
    ///
    /// This used to say every entry has completed a TLS-PSK handshake and so cannot be a
    /// stranger. That is true of the entries past `.ready` and false of the rest: `pending` is
    /// filed in `accept`, which fires when TCP connects, before any handshake has happened. So
    /// the pool holds two populations — authenticated peers that have not said `hello` yet,
    /// reaped by `authDeadline`, and anonymous sockets that have not handshaken at all, reaped
    /// by `handshakeDeadline` — and it is the second that decides what sixteen slots are worth
    /// to someone holding no key.
    private let maxPending = 16

    private let queue: DispatchQueue
    private var listener: NWListener?
    /// Only clients that have said `hello`. A handshake alone does not make an attachment,
    /// which is what keeps `onAttachedSlotsChanged` meaningful as "phones watching".
    private var attached: [UUID: NWConnection] = [:]
    /// Every accepted connection that has not yet said `hello`, so `stop()` has something to
    /// cancel for it. Without this, a connection accepted mid-handshake — key rotation
    /// restarts the listener on every arm, expiry, and revocation, so this is routine, not
    /// theoretical — has no reference left holding it once the server is gone: its own
    /// `authDeadline` closure captures `self` and `connection` weakly, so a deallocated
    /// server's deadline firing does nothing, and the receive loop's strong capture of
    /// `connection` keeps the socket alive with nothing left able to cancel it.
    private var pending: [UUID: NWConnection] = [:]
    /// Connections whose socket has become usable — TLS-PSK done, WebSocket upgrade done — and
    /// which are therefore out from under `handshakeDeadline` and into `authDeadline`.
    ///
    /// A `Set` rather than a cancelled timer because `DispatchQueue.asyncAfter` cannot be
    /// cancelled: the deadline has to recognise on its own that the connection outgrew it. A
    /// set rather than a read of `NWConnection.state` because what the deadline must know is
    /// whether *this* connection reached `.ready`, and after a `drop` there is no connection
    /// left to ask.
    private var ready: Set<UUID> = []
    /// The paired slot each connection turned out to belong to, by connection id. Resolved
    /// once, from `identities`, the first time a connection's slot is asked for, and kept
    /// because the identity log is a handshake-time record that is consumed on read — see
    /// `slot(of:id:)`.
    private var slots: [UUID: UUID] = [:]
    /// The name each connection claimed in its `hello`, by connection id. Kept for the life
    /// of the connection so a later `cmd` on the same socket is attributed exactly as its
    /// `hello` was — a client says who it is once, not on every frame.
    private var names: [UUID: String] = [:]
    /// What each peer's handshake said it was. Written by the PSK selection block that
    /// `FleetTLS.listenerParameters(keys:identities:)` installs, on this same `queue`.
    private let identities: FleetPSKIdentities

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        self.identities = FleetPSKIdentities(queue: queue)
    }

    /// `port: nil` asks the OS for one, which is what the tests use. Returns the port
    /// actually bound, for advertising.
    ///
    /// `async` rather than a busy-wait: this is started from the main actor in the app, where
    /// blocking the calling thread for up to five seconds waiting for a bind is a visible UI
    /// stall, not a background hiccup.
    ///
    /// The whole body runs inside one `queue.async`, bridged back to `async`/`await` by a
    /// single outer continuation — not, as `stop()`/`broadcast()` do, a bare
    /// `dispatchPrecondition` at the top. That was tried first and traps: `start()` is a plain
    /// `nonisolated async` method (this class is deliberately not an actor — see the class
    /// doc), and Swift's concurrency runtime does not preserve a caller's queue across a
    /// nonisolated async function's own scheduling — nor, it turns out, does resuming an inner
    /// continuation from inside `queue.async` make the *rest* of the async function's body
    /// continue running on `queue`; that resumption is scheduled by the task, not by whichever
    /// GCD queue happened to call `resume()`. Forcing the work onto `queue` explicitly, rather
    /// than asserting the caller already put it there, is the only way that holds.
    @discardableResult
    public func start(
        keys: [FleetDeviceKey], port: NWEndpoint.Port?, serviceName: String? = nil
    ) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                // `stop()`'s `listener?.cancel()` is fire-and-forget — Network.framework
                // releases the port asynchronously, on its own schedule. `reloadKeys()`
                // restarts this listener on the *same* port on every arm, expiry and
                // revocation, so this is not a hypothetical race: cancelling and immediately
                // rebinding regularly lost it outright, with `EADDRINUSE` surfacing before the
                // state handler below ever saw `.waiting` — two sockets cannot both be
                // LISTENing on one port at once, `allowLocalEndpointReuse` notwithstanding
                // (that flag is about reusing a port stuck in TIME_WAIT, not about a
                // still-live listener). `releaseListenerOnQueue` waits for the OS to actually
                // confirm the old listener is gone before this one tries to bind.
                releaseListenerOnQueue { [self] in
                    bind(keys: keys, port: port, serviceName: serviceName, continuation: continuation)
                }
            }
        }
    }

    /// The bind proper, called only from inside `start()`'s `queue.async` — after
    /// `releaseListenerOnQueue` confirms the previous listener (if any) is actually gone.
    /// Split out of `start()` only so that method's doc comment about *why* everything here
    /// runs inside one `queue.async` closure does not have to compete with this much detail.
    private func bind(
        keys: [FleetDeviceKey], port: NWEndpoint.Port?, serviceName: String?,
        continuation: CheckedContinuation<NWEndpoint.Port, Error>
    ) {
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.listenerParameters(keys: keys, identities: identities)
        )
        let listener: NWListener
        do {
            listener = try port.map { try NWListener(using: parameters, on: $0) }
                ?? NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: error)
            return
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener
        if let serviceName {
            // Bonjour is a *rediscovery* mechanism, not the address of record: the pairing
            // code's endpoints get the phone connected the first time, and this is how it
            // finds the Mac again after either of them moved. The instance name is stable
            // per Mac so a phone can prefer the one it paired with.
            listener.service = NWListener.Service(name: serviceName, type: Self.bonjourType)
        }

        // Waiting for the state handler rather than pumping a run loop: `listener.port` goes
        // non-nil the moment the listener has a socket, which is *before* the OS has
        // actually assigned the ephemeral port — in between it reports the `.any` (0)
        // placeholder, and connecting to that port fails immediately with `EADDRNOTAVAIL`.
        // The real port, and the guarantee that something is actually listening, only land
        // once the listener's state reaches `.ready`.
        //
        // The continuation must be resumed exactly once or the program traps, and
        // `stateUpdateHandler` fires repeatedly (`.setup`, `.waiting`, `.ready`, and
        // potentially `.failed`/`.cancelled` later) — hence the `resumed` guard.
        //
        // `nonisolated(unsafe)`: written and read only from `stateUpdateHandler` and the
        // bind-timeout work item below, both of which Network.framework/`queue` always
        // invoke serially on `queue` — the same single-queue confinement argument as the
        // class's `@unchecked Sendable` — but the compiler cannot see that a `@Sendable`
        // closure calls back onto one queue, hence the flag.
        nonisolated(unsafe) var resumed = false

        // Bounded on purpose. `.waiting` is Network.framework's "this may resolve itself"
        // state — a port not yet released by the listener we just stopped is the ordinary
        // way in, since a key rotation rebinds the same port. Without this, `start()`
        // never returns and the listener silently never comes up; the busy-wait this
        // replaced had a five-second bound and dropping it was a regression.
        //
        // A `DispatchWorkItem` rather than a bare closure so the success/failure paths in
        // `stateUpdateHandler` below can cancel it: a bare closure handed to `asyncAfter`
        // has nothing to cancel, so it would fire five seconds after every successful
        // bind, no-op against `resumed`, but keep this listener and continuation alive
        // until then — and `reloadKeys()` now calls `start` on every arm, expiry and
        // revocation, so those overlapping retentions stopped being theoretical the
        // moment pairing landed.
        //
        // Built as a `let` before `stateUpdateHandler` is assigned, not the `var .. !`
        // forward-declaration this once was: reassigning a captured variable from outside
        // the `@Sendable` closure that captured it — the shape the forward-declared
        // version required — is exactly what Swift 6 flags as "mutated after capture by
        // sendable closure". Nothing here needs the listener to have started first, so
        // constructing it up front sidesteps the warning instead of suppressing it.
        nonisolated(unsafe) let timeout = DispatchWorkItem { [weak listener] in
            guard !resumed else { return }
            resumed = true
            listener?.cancel()
            continuation.resume(throwing: FleetSocketError.didNotBind)
        }
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
                // to run — see the doc comment on `timeout` above.
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
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        cancelConnections()
        listener?.cancel()
        listener = nil
    }

    /// Shared by `stop()` and `releaseListenerOnQueue`: every attached and pending connection
    /// belongs to the listener being torn down, so both paths must drop the same two
    /// dictionaries or one of them would leak sockets the other already forgot about.
    ///
    /// Fires `onAttachedSlotsChanged` when it actually drops attachments —
    /// `releaseListenerOnQueue` calls this on every arm, expiry and revocation, most of which
    /// start from an empty
    /// `attached` and would otherwise fire a no-op "nothing changed" every time. Without
    /// firing here at all, a still-attached phone dropped by a listener restart kept its
    /// green "Connected" badge until the *next* successful attach overwrote the stale set —
    /// on a Mac restart, that next attach never comes.
    private func cancelConnections() {
        let hadAttachments = !attached.isEmpty
        for connection in attached.values { connection.cancel() }
        attached.removeAll()
        for connection in pending.values { connection.cancel() }
        pending.removeAll()
        // Every one of these is keyed to a connection that no longer exists: `slots` and
        // `names` to the ones just cancelled, `ready` to which of them had a usable socket,
        // `identities` to handshakes against the listener being torn down. Leaving any of them
        // would be a slow leak across the arm/expiry/revoke cycle, which restarts the listener
        // every time.
        slots.removeAll()
        names.removeAll()
        ready.removeAll()
        identities.removeAll()
        if hadAttachments { onAttachedSlotsChanged?([]) }
    }

    /// `start()`'s replacement for a bare `stop()`: confirms the old listener is actually gone
    /// before calling `then`, so the rebind that follows (routine — `reloadKeys()` does this
    /// on every arm, expiry and revocation) does not race a cancellation that is still in
    /// flight. See the comment at `start()`'s call site.
    ///
    /// A completion closure, not `async` — called only from inside `start()`'s `queue.async`,
    /// where it can rely on already being on `queue` rather than having to fight the same
    /// nonisolated-async-scheduling problem documented on `start()` itself.
    ///
    /// Bounded, and the bound is not decoration: an unbounded wait here would wedge every
    /// arm, expiry and revocation on the main actor if a terminal state never arrived — the
    /// identical hazard `bind`'s own timeout already had to be fixed for once (`f96c6c1`),
    /// reintroduced twenty lines away. On timeout it calls `then` rather than failing —
    /// proceeding to a bind that has its own timeout beats hanging, and a port that is
    /// genuinely still held will surface there as a clean error instead of as a frozen UI.
    private func releaseListenerOnQueue(then: @escaping @Sendable () -> Void) {
        cancelConnections()
        guard let listener else {
            then()
            return
        }
        self.listener = nil
        // Same single-resume hazard as `bind`'s continuation, and the same fix: `.cancelled`,
        // `.failed` and the timeout can each fire, and firing twice would trap. Both the state
        // handler and the timeout work item run on `queue`, which is what keeps this flag safe
        // without a lock. `timeout` itself needs the same `nonisolated(unsafe)` as `resumed`
        // — the state handler below captures it into a `@Sendable` closure to cancel it, and
        // `DispatchWorkItem` is not `Sendable`, but that closure only ever runs on `queue` too.
        nonisolated(unsafe) var resumed = false
        nonisolated(unsafe) let timeout = DispatchWorkItem {
            guard !resumed else { return }
            resumed = true
            then()
        }
        listener.stateUpdateHandler = { state in
            guard !resumed else { return }
            switch state {
            case .cancelled, .failed:
                resumed = true
                timeout.cancel()
                then()
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + 2, execute: timeout)
        listener.cancel()
    }

    public func broadcast(_ frame: ServerFrame) {
        dispatchPrecondition(condition: .onQueue(queue))
        for connection in attached.values {
            FleetSocket.send(frame, over: connection)
        }
    }

    /// How many clients a `broadcast` right now would reach.
    ///
    /// A count where `onAttachedSlotsChanged` is a set, because the question is different:
    /// that signal drives per-slot UI and needs to know *which* phone, while this answers "did
    /// what I just sent leave the machine, and to how many" for a diagnostic log. It counts
    /// every attachment, including one whose PSK identity could not be read back — such a
    /// connection is absent from the slot set and is still a phone receiving frames, and a
    /// count that omitted it would say "nobody was listening" about a push that arrived.
    public var attachedCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return attached.count
    }

    /// Which paired slot this connection's peer holds the key for — the PSK identity its
    /// handshake offered, which is the slot's UUID (`FleetDeviceKey.identity`).
    ///
    /// Read from `identities`, filed by the PSK selection block during the handshake, and
    /// **not** from `sec_protocol_metadata_access_pre_shared_keys`. That accessor answers a
    /// different question than its name suggests — "the PSKs supported by the local instance",
    /// i.e. every key on the listener — so with two paired devices it returned both, in
    /// registration order, for every connection alike, and this method returned whichever was
    /// registered last no matter who was on the other end. See `FleetPSKIdentities`.
    ///
    /// Resolved once and cached in `slots`: `take` consumes the handshake record, and the
    /// answer is asked for more than once per connection (every frame, and again for every
    /// recomputation of the attached set).
    ///
    /// The alternative — having the client name its own slot in `hello` — would let a client
    /// mislabel which of the user's phones is attached. It cannot forge access either way (TLS
    /// already proved it holds a paired key), so this is about attribution, not authorization.
    private func slot(of connection: NWConnection, id: UUID) -> UUID? {
        if let known = slots[id] { return known }
        guard
            let tls = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata,
            let identity = identities.take(tls.securityProtocolMetadata),
            let slot = UUID(uuidString: String(decoding: identity, as: UTF8.self))
        else { return nil }
        slots[id] = slot
        return slot
    }

    /// The value `onAttachedSlotsChanged` is fired with: every currently-attached
    /// connection's slot, dropping the ones whose PSK identity could not be read back —
    /// same distinction `FleetAttachment.slot` documents, just gathered over all of
    /// `attached` instead of one connection.
    private func attachedSlots() -> Set<UUID> {
        Set(attached.keys.compactMap { slots[$0] })
    }

    private func accept(_ connection: NWConnection) {
        // What this caps is two populations at once, not one. An entry that has reached
        // `.ready` completed a TLS-PSK handshake and cannot be a stranger, so for those this
        // bounds a paired-but-misbehaving device opening connections faster than `authDeadline`
        // reaps them. An entry that has not is anonymous — `accept` fires at TCP connect — and
        // for those this is the only cap on how many sockets one squatter can hold, each for a
        // `handshakeDeadline`. Both deadlines bound how long any one entry lingers; nothing but
        // this bounds how many pile up inside that window.
        guard pending.count < maxPending else {
            connection.cancel()
            return
        }
        let id = UUID()
        pending[id] = connection

        // Two deadlines on one connection, and which phase each covers is the point. `accept`
        // fires when TCP connects, before TLS-PSK and before the WebSocket upgrade, so a peer
        // here has no socket to say `hello` on yet: `handshakeDeadline` bounds getting one and
        // `authDeadline` — armed from `.ready` below — bounds saying nothing once it has.
        // Arming `authDeadline` here instead is what this used to do, and it is why the Mac
        // hung up on phones that were still handshaking; see that property's doc comment.
        //
        // `asyncAfter` cannot be cancelled, so both fire whatever happens, including into a
        // window the connection is long gone from. That is harmless because they are keyed by
        // `id`: a fresh UUID per connection, never reused, so a stale deadline's `drop` finds
        // nothing and removes nothing. It is also why each tests a set or a table rather than
        // being cancelled when the connection outgrows it, and why the one armed from `.ready`
        // below is as safe as this one — it is keyed the same way.
        queue.asyncAfter(deadline: .now() + handshakeDeadline) { [weak self] in
            guard let self, !self.ready.contains(id) else { return }
            self.drop(id)
        }

        // The state handler is the other half of that split: `.ready` is the first moment this
        // peer could have spoken, and therefore the earliest honest moment to start asking why
        // it has not. It earns its keep twice — a socket that dies on its own now frees its
        // `maxPending` slot immediately rather than at whichever deadline gets there first.
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            switch state {
            case .ready:
                // Both guards, and neither is guaranteed by the caller: a handshake that
                // completes in the same instant `handshakeDeadline` drops the connection would
                // otherwise arm an `authDeadline` for a connection already gone, and re-file a
                // dropped `id` in `ready` with nothing left that would clean it up.
                guard self.pending[id] != nil, self.ready.insert(id).inserted else { return }
                // Drop a peer that completed a handshake and then said nothing. Without this a
                // silent connection holds a slot for as long as the app runs.
                self.queue.asyncAfter(deadline: .now() + self.authDeadline) { [weak self] in
                    guard let self, self.attached[id] == nil else { return }
                    self.drop(id)
                }
            case .failed, .cancelled:
                // `drop` is idempotent, so the `.cancelled` this sees after our own `drop`,
                // `stop()` or `cancelConnections()` already cancelled the connection is a
                // no-op rather than a second teardown.
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)

        FleetSocket.receive(ClientFrame.self, from: connection) { [weak self] frame in
            guard let self else { return }
            // Every closure this type invokes is called on `queue`, and every current consumer
            // treats that as "the main actor" — one of them mutates the app's session store.
            // `init(queue:)` enforces neither serial-ness nor main-ness, so a caller passing a
            // concurrent or background queue would turn those into silent races rather than a
            // compile error. Fail on the first connection instead.
            dispatchPrecondition(condition: .onQueue(self.queue))
            // Recorded before the attachment is built, so the `hello` that carries the claim
            // is itself attributed with it rather than only the frames after it.
            if case .hello(_, let device) = frame, let device { self.names[id] = device }
            let attachment = FleetAttachment(
                id: id, slot: self.slot(of: connection, id: id), name: self.names[id]
            )
            switch frame {
            case .hello(let lastSeq, _):
                if self.attached[id] == nil {
                    self.pending.removeValue(forKey: id)
                    self.attached[id] = connection
                    self.onAttachedSlotsChanged?(self.attachedSlots())
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
            case .req(let cid, let request):
                // Same rule as `cmd`, for a stronger reason: answering an unattached peer's
                // command lets it drive the Mac, and answering its request lets it READ one.
                guard self.attached[id] != nil else { return connection.cancel() }
                guard let onRequest = self.onRequest else {
                    // Answered rather than ignored, and with the same `unhandled` code an
                    // unwired command gets: a client whose fetch is dropped in silence waits
                    // for a reply that is never coming.
                    FleetSocket.send(ServerFrame.err(cid: cid, code: "unhandled"), over: connection)
                    return
                }
                // At most one frame per `cid`, enforced here rather than asked of every
                // reader: a client correlates a reply by that number and closes the fetch out
                // when it lands, so a second one is a page it is no longer expecting and has
                // nowhere to put. One `Bool` on `queue` — where this closure has just
                // asserted it is — makes it impossible instead of merely documented.
                var answered = false
                onRequest(attachment, cid, request) { [weak self, weak connection] frame in
                    guard let self, let connection else { return }
                    // The reply comes back from wherever the page was read, which is the
                    // whole point of it being a closure rather than a return value. It still
                    // has to land here, on `queue`, because `attached` is confined to it and
                    // this is the code that reads it — a reader that hopped for itself would
                    // be reading that table from its own thread.
                    dispatchPrecondition(condition: .onQueue(self.queue))
                    guard !answered else { return }
                    answered = true
                    // The connection may have ended while the page was being read — a phone
                    // that put itself in a pocket mid-scroll. `attached` is keyed by a fresh
                    // UUID per connection and `drop(id)` removes it, so this cannot match a
                    // later peer that happens to reuse anything.
                    guard self.attached[id] != nil else { return }
                    FleetSocket.send(frame, over: connection)
                }
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
            self.drop(id)
        } onUndecodable: { [weak self] data in
            guard let self else { return false }
            dispatchPrecondition(condition: .onQueue(self.queue))
            // A phone newer than this Mac can send a request this build cannot parse:
            // `TimelineAnchor` and `FleetRequest.op` both throw on a value they have no case
            // for, deliberately, because a request is executed rather than rendered and
            // there is no default that is not a wrong answer. Without this the throw took
            // the socket with it — no `err`, no close frame — and the phone read a bare
            // hang-up as a disconnect, reconnected (resetting `FleetConnector`'s backoff on
            // the first frame), and re-issued the fetch that killed it. A one-second flap,
            // forever, over one unknown enum value.
            //
            // Only a `req` is salvaged, and that narrowness is the load-bearing part rather
            // than caution: `FleetSocket.receive`'s tear-down exists so the two ends cannot
            // silently disagree about state, and that reasoning is right about every frame
            // that carries state. A request carries none — it is correlated by a `cid` and
            // answered on it — so refusing this one and reading the next leaves both ends
            // believing exactly what they believed before.
            guard let salvaged = try? JSONDecoder().decode(SalvagedFrame.self, from: data),
                  salvaged.t == "req",
                  // The same gate the parseable `.req` arm applies: an unattached peer is
                  // told nothing and hung up on, whether or not this build understood it.
                  self.attached[id] != nil
            else { return false }
            FleetSocket.send(
                ServerFrame.err(cid: salvaged.cid, code: "unsupported"), over: connection
            )
            return true
        }
    }

    /// The two fields every frame that can be refused in isolation must have: what kind of
    /// frame it claimed to be, and the correlation id to refuse it on. Decoded from the raw
    /// bytes of a message `ClientFrame` threw on, which is why it names its own keys rather
    /// than reusing `ClientFrame.CodingKeys` — the point is to read the little that is
    /// legible in a frame whose remainder is not.
    private struct SalvagedFrame: Decodable {
        let t: String
        let cid: Int
    }

    /// Ends one connection and forgets everything filed under its id, from whichever of the
    /// three places notices first: a deadline, the state handler, or the receive loop's
    /// `onEnd`. One dropped socket routinely trips at least two of them — our own `cancel()`
    /// produces a `.cancelled` and an errored receive — so this is idempotent by construction:
    /// a second call finds the id in neither table, removes nothing, and fires nothing.
    private func drop(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeValue(forKey: id)?.cancel()
        ready.remove(id)
        // Before the `attached` check, not after: a connection that never said `hello` is not
        // in `attached` and returns below, but it can still have had its slot resolved.
        slots.removeValue(forKey: id)
        names.removeValue(forKey: id)
        guard let connection = attached.removeValue(forKey: id) else { return }
        connection.cancel()
        onAttachedSlotsChanged?(attachedSlots())
    }
}

public enum FleetSocketError: Error {
    case didNotBind
}
