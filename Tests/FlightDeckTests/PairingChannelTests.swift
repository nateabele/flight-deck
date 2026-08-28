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
///
/// The surface `testTheBootstrapPSKIsRefusedByTheFleetListener` actually watches is the
/// shared private `FleetTLS.parameters(keys:identities:)`: folding the bootstrap PSK into
/// that function is the plausible refactor that reaches this test and fails it (in ~0.15s).
/// Registering `PairingChannel.bootstrapSecret` under a `FleetDeviceKey` does not — a
/// `FleetDeviceKey`'s identity is always UUID-shaped and can never collide with
/// `PairingChannel.bootstrapIdentity`, and Apple's PSK path (no selection block) requires an
/// identity match before it will even try a secret. That is a dead end, not a gap: do not
/// re-derive it to "prove" this test can fail.
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

    /// The spec's §6, pinned to a golden vector rather than compared against
    /// `PairingCode.mint().secret`: a `PairingCode`'s secret is 7 bytes, so `Data` inequality
    /// against it is structural for *any* 32-byte value — no bug this test claims to catch
    /// could ever fail these lines. And the hazard itself (deriving the PSK from the code)
    /// would change `bootstrapSecret`'s construction, not produce a value comparable to a
    /// `PairingCode`'s secret — it would be a compile error in this test, not a red one.
    /// A golden vector is falsifiable, and it pins the wire constant so a silent edit cannot
    /// break pairing between an updated Mac and an un-updated phone.
    func testTheBootstrapSecretIsIndependentOfAnyPairingCode() {
        XCTAssertEqual(
            PairingChannel.bootstrapSecret.map { String(format: "%02x", $0) }.joined(),
            "52de10393fa90d84120a741cbd84ba12355072cb322d94434b01ef1fc4c3437c"
        )
    }

    /// The file header's own claim: a divergence in any of these constants "produces a
    /// failure that looks like a wrong code." Golden values so that divergence is caught
    /// here, not as a support report about a code that "doesn't work."
    func testTheWireConstantsAreGolden() {
        XCTAssertEqual(PairingChannel.bonjourType, "_flightdeck-pair._tcp")
        XCTAssertEqual(PairingChannel.txtNameKey, "name")
        XCTAssertEqual(PairingChannel.initiatorName, Data("flightdeck-phone".utf8))
        XCTAssertEqual(PairingChannel.responderName, Data("flightdeck-mac".utf8))
    }

    /// SPAKE2 binds both role names into its transcript specifically so each role gets a
    /// distinct context. Nothing else enforces that distinctness — if these were ever made
    /// equal, the binding becomes role-symmetric, silently, and Task 2 consumes both names
    /// as given.
    func testTheSPAKE2RoleNamesAreDistinct() {
        XCTAssertNotEqual(PairingChannel.initiatorName, PairingChannel.responderName)
    }
}
