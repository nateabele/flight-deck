import Network
import XCTest
@testable import FleetKit

/// Invariant 1 of the spec's §6, tested as a boundary rather than as a list assertion: the
/// bootstrap PSK gets a peer onto the pairing channel and gets it nowhere near the fleet
/// listener.
///
/// A refused PSK handshake presents as *silence* — Apple's PSK path drops a mismatched
/// identity rather than sending an alert — so the refusal here is concluded from a timeout,
/// and that is only evidence because `testTheBootstrapPSKCompletesAPairingHandshake` below
/// exercises the identical client parameters against a listener that does accept them and
/// reaches `.ready` in milliseconds. It is the control. Deleting it leaves the refusal test
/// passing while proving nothing.
final class PairingChannelTests: XCTestCase {
    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

    private func startListener(using parameters: NWParameters) throws -> NWEndpoint.Port {
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { $0.start(queue: .main) }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(listener.port)
    }

    /// Returns whether a connection built from `parameters` reaches `.ready` against `port`.
    private func reaches(
        _ port: NWEndpoint.Port, using parameters: NWParameters, timeout: TimeInterval = 2
    ) -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let settled = expectation(description: "settled")
        var ready = false
        var hasSettled = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                guard !hasSettled else { return }
                hasSettled = true
                if case .ready = state { ready = true }
                settled.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .main)
        let outcome = XCTWaiter().wait(for: [settled], timeout: timeout)
        connection.cancel()
        return outcome == .completed && ready
    }

    func testTheBootstrapPSKCompletesAPairingHandshake() throws {
        let port = try startListener(using: FleetTLS.pairingListenerParameters())
        XCTAssertTrue(reaches(port, using: FleetTLS.pairingClientParameters()))
    }

    /// Invariant 1. The bootstrap PSK is in every copy of both binaries, so a fleet listener
    /// that accepted it would accept everyone — and would do it *before* any pairing had
    /// happened, which is the one thing the fleet listener's whole trust story rests on.
    func testTheBootstrapPSKIsRefusedByTheFleetListener() throws {
        let port = try startListener(using: FleetTLS.listenerParameters(keys: [.mint()]))
        XCTAssertFalse(
            reaches(port, using: FleetTLS.pairingClientParameters()),
            "the bootstrap PSK reached the fleet listener"
        )
    }

    /// `FleetSocketServer.slot(of:)` turns a PSK identity into a slot with
    /// `UUID(uuidString:)`. A bootstrap identity that happened to parse as a UUID would be
    /// attributable to a paired device, so it is deliberately not shaped like one.
    func testTheBootstrapIdentityCannotBeMistakenForASlot() {
        let text = String(decoding: PairingChannel.bootstrapIdentity, as: UTF8.self)
        XCTAssertNil(UUID(uuidString: text))
    }

    /// The spec's §6, stated as a test because it is the "improvement" someone will propose:
    /// deriving the channel's key from the code gives a passive observer an offline attack on
    /// 55 bits, which is precisely what SPAKE2 is here to prevent.
    func testTheBootstrapSecretIsIndependentOfAnyPairingCode() {
        let first = PairingCode.mint()
        let second = PairingCode.mint()
        XCTAssertNotEqual(PairingChannel.bootstrapSecret, first.secret)
        XCTAssertNotEqual(PairingChannel.bootstrapSecret, second.secret)
        XCTAssertEqual(PairingChannel.bootstrapSecret.count, 32)
    }
}
