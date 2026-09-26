import Foundation
import Network

/// The client end. Ships in FleetKit rather than in the phone app so the loopback test can
/// drive the real thing — a second, test-only client implementation would prove nothing
/// about the one that ships.
///
/// `@unchecked Sendable`: Network.framework's handlers (`stateUpdateHandler`, the
/// `receiveMessage` completion) are typed `@Sendable`, but every one of them — and every
/// public method here — is documented to run on `queue`, so the mutable state they touch
/// is never actually shared across threads. The same idiom the rest of the codebase uses
/// for classes whose state is confined to one queue rather than protected by locks.
public final class FleetClient: @unchecked Sendable {
    public var onFrame: ((ServerFrame) -> Void)?
    public var onReady: (() -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    /// Which wire this client dials. A paired client carries the TLS-PSK key that proves who
    /// it is; a local client carries the `caller` string it puts in `hello` instead — see
    /// `FleetSocketServer.startLocal`'s doc for why that string, not a key, is the local
    /// socket's proof of who is asking (the file's permissions already answered "may this
    /// process connect at all").
    private enum Transport {
        case paired(FleetDeviceKey)
        case local(caller: String?)
    }
    private let transport: Transport
    /// What this client calls itself in `hello`, so the Mac can list it as something other
    /// than a placeholder. Injected rather than read here: FleetKit imports Foundation,
    /// Network and Security only — `UIDevice` is not reachable from this module, and the
    /// `FleetKitiOS` target exists to keep it that way. `nil` for a local client: `flightdeck`
    /// has no device name to claim, and `FleetAttachment.isLocal` already tells the Mac what
    /// this connection is.
    private let deviceName: String?
    /// What this client tells the Mac it can be *asked*, sent in `hello`. Empty for a local
    /// client — `flightdeck` answers nothing the Mac would `phoneRequest` a phone for.
    ///
    /// Injectable so a test can present a peer that claims nothing — which is what every
    /// phone in the field is, and the state the Mac must not send a `phoneRequest` into. See
    /// `FleetCapability` for why the guarantee lives in a claim rather than in a version.
    private let caps: [String]
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var nextCID = 1

    /// Guards `onDisconnect` so it fires at most once per connection, and never for a
    /// teardown we asked for ourselves.
    ///
    /// Three independent paths reach it — `stateUpdateHandler`'s `.failed`, its `.cancelled`,
    /// and the receive loop's `onEnd` — and one dropped socket trips at least two of them,
    /// because `receiveMessage` errors at the same moment the state goes `.failed`.
    /// Network.framework adds a third: calling `cancel()` on a connection that has already
    /// reached a terminal state still delivers a further asynchronous `.cancelled`, which was
    /// measured while building the TLS handshake tests (it double-fulfilled an
    /// `XCTestExpectation` and aborted the test host).
    ///
    /// The consumer of `onDisconnect` schedules a reconnect, so an unguarded closure turns a
    /// single drop into a retry storm — and a deliberate `disconnect()` into a reconnect of
    /// the thing we just chose to stop talking to.
    private var hasEnded = false

    /// `deviceName` defaults to `nil` — "claims nothing" — because that is a real wire state
    /// the server has to handle anyway (every phone built before `hello` carried a name is
    /// in it), not a convenience for callers.
    public init(
        key: FleetDeviceKey, deviceName: String? = nil,
        caps: [String] = FleetCapability.supported, queue: DispatchQueue = .main
    ) {
        self.transport = .paired(key)
        self.deviceName = deviceName
        self.caps = caps
        self.queue = queue
    }

    /// A local client: no TLS-PSK key, because the socket path's permissions are the whole
    /// authorization story (see `FleetSocketServer.startLocal`'s doc). `caller` — typically a
    /// short opaque token, not a person's name — travels in `hello` for the app's own scope
    /// check, exactly as `FleetAttachment.caller` documents.
    public init(localCaller caller: String?, queue: DispatchQueue = .main) {
        self.transport = .local(caller: caller)
        self.deviceName = nil
        self.caps = []
        self.queue = queue
    }

    public func connect(to endpoint: NWEndpoint, lastSeq: Int) {
        guard case .paired(let key) = transport else {
            preconditionFailure("a local FleetClient dials connect(toLocal:)")
        }
        open(
            NWConnection(
                to: FleetSocket.webSocketEndpoint(for: endpoint),
                using: FleetSocket.webSocketParameters(FleetTLS.clientParameters(key: key))
            ),
            lastSeq: lastSeq
        )
    }

    /// The local control socket. Same frames, same callbacks; line framing instead of TLS-PSK
    /// and WebSocket (see `FleetLineFramer`), and a `caller` in the hello for the app's scope
    /// check.
    public func connect(toLocal path: String, lastSeq: Int) {
        guard case .local = transport else {
            preconditionFailure("a paired FleetClient dials connect(to:)")
        }
        open(NWConnection(to: .unix(path: path), using: FleetSocket.lineParameters()), lastSeq: lastSeq)
    }

    /// Shared body of both `connect` overloads, from the point their parameters diverge.
    private func open(_ connection: NWConnection, lastSeq: Int) {
        disconnect()
        // Cleared after `disconnect()`, which sets it: the flag is per-connection, and this
        // is a new one.
        hasEnded = false
        self.connection = connection
        // `callerForHello` is the `.local` caller and `nil` for `.paired` — a socket-paired
        // phone has no caller to name, and the wire already omits an absent one.
        let callerForHello: String?
        if case .local(let caller) = transport { callerForHello = caller } else { callerForHello = nil }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // `hello` goes out the instant the socket is usable. TLS-PSK has already
                // established who we are, so this is a resume point, not a credential.
                FleetSocket.send(
                    ClientFrame.hello(
                        lastSeq: lastSeq, device: self.deviceName, caps: self.caps,
                        caller: callerForHello
                    ),
                    over: connection
                )
                self.onReady?()
            case .failed(let error):
                self.end(error)
            case .waiting(let error):
                // A phone dialling a Mac it hasn't reached yet *should* keep waiting —
                // Network.framework will re-probe as the network changes, and that retry is
                // the reconnect story `FleetConnector` already relies on. A local client has
                // no such story: a missing socket path never becomes viable (no listener is
                // coming up on it in the background the way a Mac might come back on the
                // LAN), so leaving `.waiting` unhandled here would make `flightdeck` hang
                // forever instead of exiting 69. Paired behaviour is untouched — this arm
                // only fires for `.local`.
                if case .local = self.transport { self.end(error) }
            case .cancelled:
                self.end(nil)
            default:
                break
            }
        }
        // `onFrame` is gated on `!hasEnded` the same way `onDisconnect` already is via
        // `end()`. Network.framework has already hopped this receive completion onto `queue`
        // by the time `disconnect()` runs — `cancel()` cannot recall an in-flight block — so
        // without this guard a frame from a connection this client has already been told to
        // abandon can still arrive and be handled as though it were live. `onDisconnect` was
        // the only one gated before this; that asymmetry was a trap for every consumer, not
        // just `FleetConnector`, whose own `accept()` needed a second, independent guard
        // against exactly this frame arriving after a `teardown()`.
        FleetSocket.receive(ServerFrame.self, from: connection) { [weak self] frame in
            guard let self, !self.hasEnded else { return }
            self.onFrame?(frame)
        } onEnd: { [weak self] error in
            self?.end(error)
        } onUndecodable: { [weak self] data in
            // The mirror of `FleetSocketServer.accept`'s salvage, added the moment this half
            // of the wire gained a request of its own. A Mac newer than this phone can send a
            // `PhoneRequest` op this build has no case for; `PhoneRequest`'s decoder throws on
            // one, deliberately, and without this the throw took the socket with it — no
            // reply, no close frame — so the phone would read a bare hang-up as a disconnect,
            // reconnect, and be asked the same unanswerable question again. A one-second flap,
            // forever, over one unknown enum value.
            //
            // Only an `ask` is salvaged, and that narrowness is the load-bearing part rather
            // than caution: `FleetSocket.receive`'s tear-down exists so the two ends cannot
            // silently disagree about state, and that reasoning is right about every frame
            // that carries state. A request carries none — it is correlated by a `cid` and
            // answered on it — so refusing this one and reading the next leaves both ends
            // believing exactly what they believed before.
            guard let self, !self.hasEnded,
                  let salvaged = try? JSONDecoder().decode(
                      FleetSocket.CorrelatedFrame.self, from: data
                  ),
                  salvaged.t == "ask"
            else { return false }
            FleetSocket.send(
                ClientFrame.refused(cid: salvaged.cid, code: "unsupported"), over: connection
            )
            return true
        }
        connection.start(queue: queue)
    }

    /// Reports the connection ending, exactly once. See `hasEnded`.
    private func end(_ error: Error?) {
        guard !hasEnded else { return }
        hasEnded = true
        onDisconnect?(error)
    }

    /// Stops talking to this peer. Deliberately does NOT report through `onDisconnect`:
    /// `hasEnded` is set first, so the `.cancelled` this provokes is swallowed. That keeps
    /// `onDisconnect` meaning one thing — "the peer went away without being asked" — which
    /// is the only reading a reconnect policy can act on.
    public func disconnect() {
        hasEnded = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    /// Returns the correlation id the reply will carry. `ack` means dispatched, not done —
    /// the observable effect arrives separately as a northbound event (§4).
    @discardableResult
    public func send(_ command: FleetCommand) -> Int {
        guard let connection else { return 0 }
        let cid = nextCID
        nextCID += 1
        FleetSocket.send(ClientFrame.cmd(cid: cid, command), over: connection)
        return cid
    }

    /// Returns the correlation id the `page` — or the `err` — will carry.
    ///
    /// Drawn from the same `nextCID` a command is, deliberately: the two travel one socket
    /// and are answered on one `cid` space, so a request and a command sharing a number
    /// would let a client match a page to a `markRead`.
    @discardableResult
    public func send(_ request: FleetRequest) -> Int {
        guard let connection else { return 0 }
        let cid = nextCID
        nextCID += 1
        FleetSocket.send(ClientFrame.req(cid: cid, request), over: connection)
        return cid
    }

    /// Answer a `ServerFrame.phoneRequest` on the `cid` the Mac chose.
    ///
    /// Separate from `send` and returning nothing, because it mints no correlation id: this
    /// echoes one back. Dropped in silence when there is no connection, which is the right
    /// answer for a reply nobody is waiting on any more — the Mac's own pending entry is
    /// released by the drop that took this socket away.
    public func answer(_ frame: ClientFrame) {
        guard let connection else { return }
        FleetSocket.send(frame, over: connection)
    }
}
