import Network
import XCTest
import FleetKit

/// The trust boundary, tested as a boundary. Everything else in this feature assumes an
/// unpaired peer cannot reach application code; these four tests are the only evidence for
/// that claim, so they exercise a real listener and a real connection over loopback rather
/// than asserting anything about the parameter objects.
final class FleetTLSHandshakeTests: XCTestCase {
    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

    /// Starts a listener that accepts any of `keys` and echoes the first message it receives.
    private func startEchoListener(keys: [FleetDeviceKey]) throws -> NWEndpoint.Port {
        let listener = try NWListener(using: FleetTLS.listenerParameters(keys: keys))
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, _ in
                guard let data else { return }
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(listener.port)
    }

    /// Returns the connection's terminal state: `.ready` on a successful handshake, or
    /// `.failed`/`.cancelled` when the peer refused us.
    ///
    /// A refused handshake presents as *silence*, not as `.failed` — Apple's PSK path drops a
    /// mismatched identity rather than sending an alert, which is a reasonable way to avoid an
    /// identity oracle. So these tests conclude "refused" from a timeout, and that is only
    /// evidence because the two positive tests in this file exercise the identical listener
    /// and `attempt` path and reach `.ready` in single-digit milliseconds. They are the
    /// control. If you ever weaken or delete them, these refusal tests stop proving anything
    /// and quietly keep passing.
    private func attempt(
        key: FleetDeviceKey, port: NWEndpoint.Port, timeout: TimeInterval = 2
    ) -> NWConnection.State {
        let connection = NWConnection(
            host: "127.0.0.1", port: port, using: FleetTLS.clientParameters(key: key)
        )
        let settled = expectation(description: "connection settled")
        var terminal: NWConnection.State = .setup
        // Cancelling a connection that already reached a terminal state (.ready or .failed)
        // delivers a further, asynchronous .cancelled notification of its own — sometimes
        // late enough to land during a *later* test's run-loop pumping, where it fulfills an
        // already-fulfilled expectation and aborts the whole process. Guard so only the
        // first terminal transition is recorded; this changes nothing about what counts as
        // a pass, it only stops a stray duplicate callback from crashing the test host.
        var hasSettled = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                guard !hasSettled else { return }
                hasSettled = true
                terminal = state
                settled.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .main)
        let outcome = XCTWaiter().wait(for: [settled], timeout: timeout)
        connection.cancel()
        // A handshake the peer refuses can also manifest as silence rather than a failure
        // state, so a timeout counts as "did not connect" — never as a pass.
        return outcome == .completed ? terminal : .cancelled
    }

    private func isReady(_ state: NWConnection.State) -> Bool {
        if case .ready = state { return true }
        return false
    }

    func testAPairedKeyCompletesTheHandshake() throws {
        let key = FleetDeviceKey.mint()
        let port = try startEchoListener(keys: [key])
        XCTAssertTrue(isReady(attempt(key: key, port: port)))
    }

    /// The real question this task exists to answer: can one listener hold several paired
    /// devices' keys at once? Everything about revocation-per-slot depends on it.
    func testEveryRegisteredSlotCanConnectToOneListener() throws {
        let first = FleetDeviceKey.mint()
        let second = FleetDeviceKey.mint()
        let port = try startEchoListener(keys: [first, second])
        XCTAssertTrue(isReady(attempt(key: first, port: port)), "first slot was refused")
        XCTAssertTrue(isReady(attempt(key: second, port: port)), "second slot was refused")
    }

    /// Revocation is deleting a slot's secret, so this is the test that says revocation
    /// works: the same slot id with a different secret must not get in.
    func testTheRightSlotWithTheWrongSecretIsRefused() throws {
        let paired = FleetDeviceKey.mint()
        let impostor = FleetDeviceKey(slot: paired.slot, secret: FleetDeviceKey.mint().secret)
        let port = try startEchoListener(keys: [paired])
        XCTAssertFalse(isReady(attempt(key: impostor, port: port)))
    }

    func testASlotTheMacHasNeverSeenIsRefused() throws {
        let port = try startEchoListener(keys: [.mint()])
        XCTAssertFalse(isReady(attempt(key: .mint(), port: port)))
    }

    func testAMintedKeyIsThirtyTwoBytesAndNotReused() {
        let a = FleetDeviceKey.mint()
        let b = FleetDeviceKey.mint()
        XCTAssertEqual(a.secret.count, 32)
        XCTAssertNotEqual(a.secret, b.secret)
        XCTAssertNotEqual(a.slot, b.slot)
    }
}
