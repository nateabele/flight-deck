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

    private let key: FleetDeviceKey
    /// What this client calls itself in `hello`, so the Mac can list it as something other
    /// than a placeholder. Injected rather than read here: FleetKit imports Foundation,
    /// Network and Security only — `UIDevice` is not reachable from this module, and the
    /// `FleetKitiOS` target exists to keep it that way.
    private let deviceName: String?
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
    public init(key: FleetDeviceKey, deviceName: String? = nil, queue: DispatchQueue = .main) {
        self.key = key
        self.deviceName = deviceName
        self.queue = queue
    }

    public func connect(to endpoint: NWEndpoint, lastSeq: Int) {
        disconnect()
        // Cleared after `disconnect()`, which sets it: the flag is per-connection, and this
        // is a new one.
        hasEnded = false
        let parameters = FleetSocket.webSocketParameters(
            FleetTLS.clientParameters(key: key)
        )
        let connection = NWConnection(to: Self.webSocketEndpoint(for: endpoint), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // `hello` goes out the instant the socket is usable. TLS-PSK has already
                // established who we are, so this is a resume point, not a credential.
                FleetSocket.send(
                    ClientFrame.hello(lastSeq: lastSeq, device: self.deviceName),
                    over: connection
                )
                self.onReady?()
            case .failed(let error):
                self.end(error)
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
        }
        connection.start(queue: queue)
    }

    /// `NWProtocolWebSocket`'s automatic HTTP-upgrade handshake needs a URL to build its
    /// Upgrade request from. Handed a bare `.hostPort` endpoint instead — what every caller
    /// here passes — it aborts the connection (`ECONNABORTED`, silently, before `.ready`)
    /// rather than falling back to something host/port alone could satisfy; a plain TLS-PSK
    /// connection built from the identical parameters, minus the WebSocket layer, completes
    /// in single-digit milliseconds, which is what isolates this to the WebSocket handshake
    /// rather than to TLS-PSK or to loopback itself. So `.hostPort` is translated to a `wss`
    /// URL here rather than pushing the workaround onto every call site.
    private static func webSocketEndpoint(for endpoint: NWEndpoint) -> NWEndpoint {
        guard case .hostPort(let host, let port) = endpoint else { return endpoint }
        // IPv6 literals need bracketing to be valid inside a URL authority; every other
        // host form's description is already URL-safe as-is.
        let hostText: String
        switch host {
        case .ipv6:
            hostText = "[\(host)]"
        default:
            hostText = "\(host)"
        }
        guard let url = URL(string: "wss://\(hostText):\(port.rawValue)/") else { return endpoint }
        return .url(url)
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
}
