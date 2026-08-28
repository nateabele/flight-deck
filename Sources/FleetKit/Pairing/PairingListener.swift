import Foundation
import Network
import Security

/// The Mac's half of a pairing window: a listener that exists only while one is open.
///
/// **Why this is not the fleet listener** (spec §6). A PAKE necessarily runs *before* any
/// shared secret exists, so carrying it on the fleet listener means accepting unauthenticated
/// handshakes there — letting anyone on the LAN consume that listener's pending pool during
/// every window, and turning "a bootstrap connection must never send `hello`" into a check
/// somebody has to write rather than a fact about the socket. Here, application code is not
/// reachable because it is not there: this type imports no store, holds no callback into one,
/// and speaks a vocabulary (`PairingClientFrame`) with no `hello` in it.
///
/// **The channel provides no confidentiality.** Its PSK is in every copy of both binaries.
/// The device key is safe because it is sealed under the SPAKE2-derived key, and would be
/// equally safe in the clear.
///
/// `@unchecked Sendable`, with every mutation confined to `queue` — the same discipline
/// `FleetSocketServer` and `FleetConnector` use, and for the same reason: Network.framework's
/// handlers are typed `@Sendable` but every one of them runs on `queue`, so the state they
/// touch is confined rather than shared. `stop()` asserts
/// `dispatchPrecondition(condition: .onQueue(queue))` as its first line, and every
/// caller-supplied closure is invoked on `queue` under the same assertion. `start()` cannot
/// use that assertion — it is a plain `nonisolated async` method, and Swift's concurrency
/// runtime does not preserve a caller's queue across one — so it forces its whole body onto
/// `queue` with a single `queue.async`, exactly as `FleetSocketServer.start` does. See that
/// method's doc comment for why the more obvious fixes do not work.
public final class PairingListener: @unchecked Sendable {
    /// Three guesses against 55 bits, per Mac, per window (spec §7). The limit is the security
    /// boundary here, not the code's length.
    public static let maxAttempts = 3

    /// This listener's own pending cap, deliberately unrelated to `FleetSocketServer`'s 16.
    /// Every entry here is *unauthenticated* — the bootstrap PSK proves nothing about who is
    /// on the other end — where the fleet listener's pending entries have all completed a
    /// handshake with a paired key. Different populations, different bound; a window expects
    /// one phone, and four is generous for retries.
    ///
    /// **A cap only means something alongside the deadline that empties it**, and this pair
    /// was originally chosen one number at a time: 4 slots against the fleet's 16, held for 30
    /// seconds against its 5. Four times fewer slots held six times longer is roughly 24 times
    /// easier to saturate, on the one socket in the app whose peers are unauthenticated — so
    /// anyone on the LAN, holding only the PSK that ships in every binary, could take all four
    /// silently, renew them, and the legitimate phone would be refused at `accept`'s cap guard
    /// with nothing to show for it. That is why the deadlines below are split by what the peer
    /// has *reached*: `handshakeDeadline` bounds a socket that never becomes usable,
    /// `firstFrameDeadline` bounds a usable one that says nothing, and the long
    /// `exchangeDeadline` is reachable only by a peer that has spoken.
    public static let maxPending = 4

    /// The largest frame this socket will receive, and the reason it is not
    /// `TimelineLimits.maximumMessageSize`: every peer here is *unauthenticated*, so this
    /// is the one socket in the app where a stranger can make the stack allocate. The whole
    /// vocabulary is four small frames — a 32-byte curve point, a 32-byte MAC, a sealed key of
    /// a few hundred bytes — so 16 KiB is three orders of magnitude of headroom and still
    /// nothing a peer can use. See `FleetSocket.webSocketParameters` for what the absent
    /// default costs.
    public static let maxFrameBytes = 16 * 1024

    /// How long a peer may hold one of the four pending slots **before its socket is even
    /// usable** — from `accept`, which fires when TCP connects, to `.ready`, which is when the
    /// TLS-PSK handshake and the WebSocket upgrade have both completed.
    ///
    /// This exists because `firstFrameDeadline` used to be armed here, and that shipped a Mac
    /// that hung up on real phones. Measured against a booted simulator: the phone's flow
    /// reported `flow:failed_connect @5.273s, error server closed session with no
    /// notification` — five seconds of handshake against a five-second deadline, with the Mac
    /// cutting a live pairing off mid-upgrade and the phone reporting "Couldn't reach that
    /// Mac". The reasoning behind arming it at `accept` was simply false: "a peer that has not
    /// sent its `pake` within five seconds is not a phone" describes a peer that *could* have
    /// sent it, and a peer still completing its handshake has no socket to send on.
    ///
    /// Ten seconds, and the number is picked the same way `exchangeDeadline`'s is: the Mac
    /// must never be the side that gives up first on a slow-but-live phone. The initiator
    /// gives TLS, the upgrade and all four frames together 8 seconds
    /// (`PairingInitiator.exchangeTimeout`), so a peer that has not reached `.ready` by ten has
    /// already abandoned its own attempt, and anything the Mac drops here it would have lost
    /// anyway.
    ///
    /// It is not free: a peer that opens a socket and never sends a byte of TLS now costs ten
    /// seconds of a slot instead of five, so saturating the pool of four got twice as cheap.
    /// That is the price of not hanging up on real phones, and it is paid on the phase where
    /// no better signal exists — nothing about a TCP connection distinguishes a phone on a bad
    /// link from a squatter. The phase where a signal *does* exist, `.ready` onwards, keeps the
    /// short deadline below.
    ///
    /// Settable so a test need not wait the production value.
    public var handshakeDeadline: TimeInterval = 10

    /// How long a peer may hold one of the four pending slots **without saying anything**,
    /// measured from `.ready` — the first moment it *could* speak — rather than from `accept`.
    /// See `handshakeDeadline` for what arming it at `accept` cost.
    ///
    /// Not named `authDeadline`, and not one deadline any more, for the same reason
    /// `PairingInitiator.exchangeTimeout` was renamed: nothing authenticates on this socket —
    /// the PSK is public and the PAKE is the whole point — so a name borrowed from the fleet
    /// listener described a thing that does not happen here, and it hid that the generous
    /// number was being handed to peers that had not earned it. A peer whose socket is usable
    /// and that has not sent its `pake` within five seconds is not a phone: the phone sends
    /// that frame from `stateUpdateHandler`'s `.ready`, with no work left between the two, so
    /// five seconds is already three orders of magnitude of slack on one queued send.
    ///
    /// Settable so a test need not wait the production value.
    public var firstFrameDeadline: TimeInterval = 5

    /// How long a peer that *has* spoken may take to finish, measured from `accept` — so it is
    /// a ceiling over the whole connection rather than a budget that renews, and the two short
    /// deadlines above partition the time before the first frame underneath it.
    ///
    /// Thirty seconds, and **not because a human is typing inside it** — the earlier comment
    /// said that and it was simply wrong. `PairingRunner` takes a `PairingCode`, so the code is
    /// typed and checksummed before the phone dials at all, and nothing on this socket waits
    /// for a person. What the number is really for is slack over the initiator's own
    /// whole-exchange timeout (`PairingInitiator.exchangeTimeout`, 8s): the Mac should never be
    /// the side that gives up first on a slow-but-live phone, because a phone that gets cut off
    /// mid-exchange reports a network problem while the Mac's window sits there looking open.
    public var exchangeDeadline: TimeInterval = 30

    /// Fired once, on `queue`, the moment the sealed key is actually out — from the sealed
    /// frame's own send completion, not the line after it, so a consumer that closes the
    /// window from in here cannot truncate the frame it is reacting to — see `stop()` for the
    /// mechanism and its one bound. Once per connection, enforced by `paired`, not merely
    /// intended. The consumer's job is
    /// to close the window; this type does not close itself, because "the window is open" is
    /// `FleetService`'s fact, not this listener's.
    public var onPaired: (() -> Void)?
    /// Fired once, on `queue`, when the third attempt is spent — from the send completion of
    /// the `.attemptsExhausted` reject, so a consumer that closes the window from in here does
    /// not truncate the frame that says why. The window is burned and the user must re-arm.
    public var onAttemptsExhausted: (() -> Void)?

    /// Read by tests and by nothing in production. Confined to `queue` like everything else.
    public private(set) var attemptsSpent = 0

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    /// One SPAKE2 session per connection, and never reused: the C context is single-use, so a
    /// retry is a new connection with a new session. Held only to keep the transcript
    /// reachable; `PairingSecrets` is what the exchange actually consults.
    private var sessions: [UUID: SPAKE2Session] = [:]
    private var secrets: [UUID: PairingSecrets] = [:]
    /// Connections that have already been handed a sealed key. They are deliberately left
    /// open — the consumer's `stop()` is what closes them — so without this a phone that
    /// replayed the confirmation the Mac just accepted would be sealed a second key under a
    /// fresh nonce and fire `onPaired` again, which is not what "fired once" can mean to a
    /// consumer that hangs window teardown and key promotion off it.
    private var paired: Set<UUID> = []
    /// Connections whose socket has become usable — TLS-PSK done, WebSocket upgrade done — and
    /// which are therefore out from under `handshakeDeadline` and into `firstFrameDeadline`.
    /// Same `Set`-rather-than-a-cancelled-timer reasoning as `spoken` below, and the same
    /// reason it is a set rather than a read of `NWConnection.state`: what the deadline has to
    /// know is whether *this* connection reached `.ready`, and after a `drop` there is no
    /// connection left to ask.
    private var ready: Set<UUID> = []
    /// Connections that have delivered at least one frame, and therefore hold the long
    /// `exchangeDeadline` rather than the short `firstFrameDeadline`. A `Set` rather than a
    /// cancelled timer because `DispatchQueue.asyncAfter` cannot be cancelled — the deadline
    /// has to recognise that it no longer applies, exactly as the stale-window case does.
    private var spoken: Set<UUID> = []

    private var code: PairingCode?
    private var key: FleetDeviceKey?
    private var macName = ""

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// Binds an OS-assigned port and advertises it on `PairingChannel.bonjourType`.
    ///
    /// No `releaseListenerOnQueue` dance, unlike `FleetSocketServer.start`: that exists
    /// because key rotation rebinds the fleet listener on the *same* port on every arm, expiry
    /// and revocation. This listener always takes a fresh port and is never rebound, so there
    /// is no cancellation in flight for a bind to race.
    @discardableResult
    public func start(
        code: PairingCode, key: FleetDeviceKey, macName: String,
        serviceName: String, port: NWEndpoint.Port?
    ) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                self.code = code
                self.key = key
                self.macName = macName
                self.attemptsSpent = 0
                bind(
                    port: port, serviceName: serviceName, macName: macName,
                    continuation: continuation
                )
            }
        }
    }

    private func bind(
        port: NWEndpoint.Port?, serviceName: String, macName: String,
        continuation: CheckedContinuation<NWEndpoint.Port, Error>
    ) {
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.pairingListenerParameters(), maximumMessageSize: Self.maxFrameBytes
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
        // The advertisement's lifetime IS the window's lifetime — this service exists only
        // while the listener does, which is why a phone that finds nothing can say "that Mac
        // isn't pairable right now" rather than guessing. The TXT record carries the Mac's
        // display name so a phone that finds two can tell them apart; it is unauthenticated
        // text from the network, for display only, until the seal delivers the real name.
        listener.service = NWListener.Service(
            name: serviceName, type: PairingChannel.bonjourType,
            txtRecord: NWTXTRecord([PairingChannel.txtNameKey: macName])
        )

        // Same single-resume hazard, and same fix, as `FleetSocketServer.bind`: the state
        // handler fires repeatedly and the continuation must be resumed exactly once or the
        // program traps. `nonisolated(unsafe)` because both this flag and the work item are
        // touched only from handlers Network.framework delivers serially on `queue`.
        nonisolated(unsafe) var resumed = false
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
                // `.any` (0) is the placeholder `listener.port` reports in the moment before
                // the OS assigns a real ephemeral port; resuming there hands back a port
                // nothing can connect to.
                guard let port = listener.port, port != .any else { return }
                resumed = true
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

    /// Tears the window down. Called by every route that closes one — success, expiry, cancel,
    /// app termination (invariant 2) — so it must leave nothing behind that could answer.
    ///
    /// `cancel()`, never `forceCancel()`, but that alone is *not* what protects the sealed
    /// frame: `cancel()` is the graceful close and it still does not wait for a send issued in
    /// the same block — see `FleetSocket.send`'s `onSent` for the measurement. So the success
    /// path fires `onPaired`, and the exhaustion path `onAttemptsExhausted`, from their
    /// frame's own send completion rather than from the line after it.
    ///
    /// The mechanism, measured rather than assumed, because a plausible wrong reading of it
    /// ("the frame reaches the peer's socket and is dropped unread") would call for a very
    /// different fix. Instrumenting the *unfixed* shape's send with an error handler — which
    /// costs nothing on the success path, so it does not perturb the race the way a log line
    /// between the two calls does — reports `POSIXErrorCode(rawValue: 89): Operation canceled`
    /// on every failing run. The bytes never reach the socket at all: `cancel()` aborts a send
    /// that the stack has not yet taken. Cancelling *after* `.contentProcessed` is a different
    /// thing entirely — the bytes are already in the stack, and a graceful close orders its
    /// FIN behind them, which is why the peer reads the frame and then EOF.
    ///
    /// So the guarantee holds for any frame small enough to be resident when the stack reports
    /// it took it, which every frame here is: this socket refuses anything over
    /// `maxFrameBytes` (16 KiB) inbound, and the largest thing it sends is a sealed device key
    /// of a few hundred bytes. It is not unconditional — a 2 MB frame cancelled from `onSent`
    /// was still lost 8 times out of 8, because a message that large is still being written
    /// when the cancel lands — so a frame that ever grew by orders of magnitude would need a
    /// real drain rather than this.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sessions.removeAll()
        secrets.removeAll()
        paired.removeAll()
        ready.removeAll()
        spoken.removeAll()
        code = nil
        key = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connections.count < Self.maxPending else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection

        // Three deadlines on one connection, and the split is the point: a peer that holds a
        // slot in a pool of four must not get the window a real exchange gets for doing
        // nothing to earn it, and *what it has managed to reach* is the only signal available
        // for telling those apart. So each phase is bounded by the deadline that fits it —
        // ten seconds to make the socket usable, five more to say something on it, and the
        // long one reachable only after a frame actually arrives. All three are this
        // listener's own, not the fleet listener's (invariant 4).
        //
        // `asyncAfter` cannot be cancelled, so all of them fire whatever happens — including
        // into a *later* window, if the user closes one and arms another inside
        // `exchangeDeadline`. That is harmless because they are keyed by `id`: a fresh UUID
        // per connection, never reused, so a stale deadline's `drop` finds nothing and removes
        // nothing. That is what stands in for `FleetConnector`'s generation counter here — the
        // key already carries the generation. It is also why each deadline tests a set rather
        // than being cancelled when the connection outgrows it, and why the one armed from
        // `.ready` below is as safe as these two: it is keyed the same way.
        queue.asyncAfter(deadline: .now() + handshakeDeadline) { [weak self] in
            guard let self, !self.ready.contains(id) else { return }
            self.drop(id)
        }
        queue.asyncAfter(deadline: .now() + exchangeDeadline) { [weak self] in
            self?.drop(id)
        }

        // The state handler exists for the deadline above's other half. `accept` fires when
        // TCP connects — before TLS-PSK and before the WebSocket upgrade — so this is where
        // the connection stops being a socket and starts being a peer that can speak, and it
        // is the earliest honest moment to start asking why it has not.
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            switch state {
            case .ready:
                // `insert().inserted`, and the `connections` check, because neither is
                // guaranteed by the caller: a handshake that completes in the same instant its
                // deadline drops the connection would otherwise arm a first-frame deadline for
                // a connection that is already gone, and re-file a dropped `id` in `ready`
                // where the ceiling deadline's `drop` would then have to clean it up again.
                guard self.connections[id] != nil, self.ready.insert(id).inserted else { return }
                self.queue.asyncAfter(deadline: .now() + self.firstFrameDeadline) { [weak self] in
                    guard let self, !self.spoken.contains(id) else { return }
                    self.drop(id)
                }
            case .failed, .cancelled:
                // A socket that died on its own frees its slot now rather than at whichever
                // deadline gets there first. `drop` is idempotent, so the `.cancelled` this
                // sees after our own `drop` or `stop()` cancelled the connection is a no-op.
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)

        FleetSocket.receive(PairingClientFrame.self, from: connection) { [weak self] frame in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            // Before `handle`, and unconditionally: what promotes a connection to the long
            // deadline is that it *spoke*, not that what it said was any good. A frame this
            // listener rejects is dropped by `handle` anyway, so there is nothing to gain by
            // withholding the promotion from it — and making the promotion depend on the
            // frame's contents would put the slow, generous path behind a parse.
            self.spoken.insert(id)
            self.handle(frame, id: id, connection: connection)
        } onEnd: { [weak self] _ in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.drop(id)
        }
    }

    private func handle(_ frame: PairingClientFrame, id: UUID, connection: NWConnection) {
        guard let code, let key, connections[id] != nil else { return drop(id) }
        // Ignored rather than dropped: this connection has already been sealed a key that may
        // still be flushing, and cancelling it here would truncate the frame the exchange
        // exists to deliver — the very failure `onSent` is here to avoid.
        guard !paired.contains(id) else { return }
        guard attemptsSpent < Self.maxAttempts else {
            // Answered rather than silently dropped so a phone can say "ask your Mac for a new
            // code" instead of "the network went away". The window is already burned; there is
            // nothing left to protect by staying quiet.
            return reply(.reject(.attemptsExhausted), over: connection, thenDrop: id)
        }

        switch frame {
        case .pake(let peerMessage):
            // One PAKE per connection. `SPAKE2Session` is single-use in the C library and
            // would throw, but dropping here says why.
            guard sessions[id] == nil else { return drop(id) }
            let session = SPAKE2Session(
                role: .responder,
                myName: PairingChannel.responderName, theirName: PairingChannel.initiatorName
            )
            do {
                // Generate before processing: the C context requires that order, and
                // `transcript` needs both halves before it will answer.
                let mine = try session.message(for: code)
                let material = try session.keyMaterial(from: peerMessage)
                sessions[id] = session
                // `session.transcript`, never assembled here. It is initiator-first on both
                // sides; the same `myMsg + theirMsg` line written on both ends yields opposite
                // orders, mismatched keys, and a Mac that reports "wrong code" for a correctly
                // typed one while spending an attempt saying so.
                secrets[id] = PairingSecrets(
                    keyMaterial: material, transcript: try session.transcript
                )
                FleetSocket.send(PairingServerFrame.pake(msg: mine), over: connection)
            } catch {
                // Not a guess — a frame that is not a curve point at all — so no attempt is
                // spent. The pending cap and the deadline are what bound this, not the budget.
                reply(.reject(.malformed), over: connection, thenDrop: id)
            }

        case .confirm(let claimed):
            guard let derived = secrets[id] else {
                // A confirmation with no exchange behind it contains no guess to charge for.
                return drop(id)
            }
            guard PairingSecrets.matches(claimed, derived.initiatorConfirmation) else {
                attemptsSpent += 1
                let exhausted = attemptsSpent >= Self.maxAttempts
                // `then:`, not the next line, for the same reason the sealed frame uses
                // `onSent`: closing the window from inside `onAttemptsExhausted` is the only
                // sensible thing a consumer can do there, and a `stop()` that lands while this
                // reject is still queued takes the socket out from under the one frame that
                // tells the phone to ask for a new code rather than that the network went
                // away. Measured on the unfixed shape: the third attempt's
                // `.attemptsExhausted` never arrived, 4 runs out of 4.
                reply(
                    .reject(exhausted ? .attemptsExhausted : .badCode),
                    over: connection, thenDrop: id,
                    then: { [weak self] in
                        guard exhausted else { return }
                        self?.onAttemptsExhausted?()
                    }
                )
                return
            }
            let box: Data
            do {
                // `seal` takes the key and reads the slot out of it, never a slot passed
                // alongside — see its own doc comment for why that is the shape.
                box = try derived.seal(key, macName: macName)
            } catch {
                return reply(.reject(.malformed), over: connection, thenDrop: id)
            }
            // `onSent`, not the next line: the consumer closes the window from inside
            // `onPaired`, and a `stop()` that lands while this frame is still queued takes the
            // socket out from under the one frame the whole exchange exists to deliver. The
            // connection is deliberately left open — the consumer's `stop()` is what closes
            // it, and by then the frame is out.
            paired.insert(id)
            // The key material has done its job; nothing after this may consult it.
            sessions.removeValue(forKey: id)
            secrets.removeValue(forKey: id)
            FleetSocket.send(
                PairingServerFrame.sealed(mac: derived.responderConfirmation, box: box),
                over: connection,
                onSent: { [weak self] in
                    guard let self else { return }
                    // The send completion lands on the connection's queue, which is `queue` —
                    // the same assertion every other caller-supplied closure here is invoked
                    // under, made at the one site that reaches `onPaired`.
                    dispatchPrecondition(condition: .onQueue(self.queue))
                    self.onPaired?()
                }
            )
        }
    }

    /// Sends one last frame and then closes the connection — never `FleetSocket.send`
    /// followed on the next line by `drop`, which loses the frame (see `FleetSocket.send`'s
    /// `onSent`). The connection stays in `connections` until the send completes, so `stop()`
    /// and the deadline can both still reach it if the completion never arrives.
    private func reply(
        _ frame: PairingServerFrame, over connection: NWConnection, thenDrop id: UUID,
        then: (@Sendable () -> Void)? = nil
    ) {
        FleetSocket.send(frame, over: connection, onSent: { [weak self] in
            self?.drop(id)
            then?()
        })
    }

    private func drop(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        connections.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)
        secrets.removeValue(forKey: id)
        paired.remove(id)
        ready.remove(id)
        spoken.remove(id)
    }
}
