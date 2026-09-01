import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The listener's port is what a paired phone dials. `PairedMac.endpoints` are `host:port`
/// strings seeded from the pairing payload, so a port drawn fresh from the ephemeral range on
/// every launch strands every paired device the moment the Mac restarts — leaving Bonjour as
/// the only way back, and anything that breaks Bonjour as a permanent stranding.
///
/// These tests are about that behaviour, not about the storage: each one restarts the *service*
/// over a surviving `Preferences` blob, exactly as a relaunch does.
@MainActor
final class FleetPortPersistenceTests: XCTestCase {
    private var services: [FleetService] = []
    private var holders: [PortHolder] = []

    override func tearDown() async throws {
        services.forEach { $0.stop() }
        services.removeAll()
        holders.forEach { $0.release() }
        holders.removeAll()
    }

    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    /// A plain listening socket. Used both to occupy a port and to ask whether one is free —
    /// an `NWListener` answers neither question usefully, because a busy port parks it in
    /// `.waiting` indefinitely rather than failing, and it may take the port later anyway.
    private final class PortHolder {
        private let descriptor: Int32

        init?(port: UInt16) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = in_addr_t(0)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 1) == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            self.descriptor = descriptor
        }

        func release() { Darwin.close(descriptor) }
    }

    /// One launch of the app: a fresh `PreferencesStore` reading whatever the last launch left
    /// behind, and a fresh `FleetService` over it.
    private func launch(_ persistence: MemoryPersistence) -> FleetService {
        let service = FleetService(
            store: SessionStore(provider: nil, persistence: nil),
            preferences: PreferencesStore(persistence: persistence),
            armer: PairingArmer()
        )
        // Silenced for `FleetTestHarness`'s reason: the default prompt-lifecycle sink
        // appends to the developer's own `~/Library/Logs/flight-deck-prompt.log`.
        service.promptLifecycleForTesting = { _ in }
        services.append(service)
        return service
    }

    /// Quits a launch and waits for the port to actually come back.
    ///
    /// A real relaunch inherits a free port because the process that held it is gone. In one
    /// process `stop()` only *starts* the release — Network.framework finishes it on its own
    /// schedule, which is the whole reason `FleetSocketServer.releaseListenerOnQueue` exists —
    /// so a test that relaunched immediately would be measuring that race rather than the
    /// behaviour under test.
    private func quit(_ service: FleetService, releasing port: NWEndpoint.Port) async throws {
        service.stop()
        for _ in 0..<200 {
            if let probe = PortHolder(port: port.rawValue) {
                probe.release()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("port \(port.rawValue) was never released")
    }

    /// Holds `port` for the rest of the test, so the next bind of it cannot succeed.
    private func occupy(_ port: NWEndpoint.Port) throws {
        let holder = try XCTUnwrap(PortHolder(port: port.rawValue), "could not occupy \(port.rawValue)")
        holders.append(holder)
    }

    /// The bug: the Mac was on 58337 when the phone paired, relaunched onto 58385, and the
    /// phone spent the rest of its life dialling a port nothing was listening on.
    func testARelaunchComesBackOnTheSamePort() async throws {
        let persistence = MemoryPersistence()
        let first = launch(persistence)
        let original = try await first.start()
        try await quit(first, releasing: original)

        let second = launch(persistence)
        let rebound = try await second.start()
        XCTAssertEqual(
            rebound, original,
            "a relaunch must reclaim the port every paired phone remembers"
        )
    }

    /// The remembered port is a preference, not a claim — nothing reserves it while Flight Deck
    /// is not running. A phone that has to rediscover is a nuisance; a Mac with no listener is
    /// a dead feature, so the listener comes up regardless.
    func testAPortSomethingElseTookDoesNotStopTheListenerComingUp() async throws {
        let persistence = MemoryPersistence()
        let first = launch(persistence)
        let original = try await first.start()
        try await quit(first, releasing: original)
        try occupy(original)

        let second = launch(persistence)
        let bound = try await second.start()
        XCTAssertNotEqual(bound, original)
        XCTAssertNotEqual(bound.rawValue, 0)
        XCTAssertEqual(second.boundPort, bound)
    }

    /// Including the port the OS chose after that fallback: a launch that keeps asking for a
    /// port which is never coming back has only moved the problem one relaunch along.
    func testThePortActuallyBoundIsTheOneRemembered() async throws {
        let persistence = MemoryPersistence()
        let first = launch(persistence)
        let original = try await first.start()
        XCTAssertEqual(persistence.stored?.fleetPort, original.rawValue)

        try await quit(first, releasing: original)
        try occupy(original)
        let second = launch(persistence)
        let fallback = try await second.start()
        XCTAssertEqual(persistence.stored?.fleetPort, fallback.rawValue)
    }

    /// A key rotation is not a move. `reloadKeys()` runs on every arm, expiry and revocation,
    /// and the endpoints in a pairing code — and in every paired phone — are only true for as
    /// long as the listener stays where it was.
    func testReloadingKeysKeepsTheListenerOnTheSamePort() async throws {
        let persistence = MemoryPersistence()
        let service = launch(persistence)
        let bound = try await service.start()
        try await service.reloadKeys()
        XCTAssertEqual(service.boundPort, bound)
        XCTAssertEqual(persistence.stored?.fleetPort, bound.rawValue)
    }

    /// The load-bearing guarantee for anything added to `Preferences`: a blob written before
    /// this field existed decodes rather than throwing, which is what stops a silent reset of
    /// every setting the user has. See `PreferencesMigrationTests`.
    func testAPreFleetPortBlobStillDecodes() throws {
        let legacy = Data(#"{"globalFlags":{"values":{},"passthrough":[]},"projectFlags":{},"shell":{"environment":{},"clearChildSessionMarker":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertNil(decoded.fleetPort)
        XCTAssertTrue(decoded.projectFlags.isEmpty)
    }
}
