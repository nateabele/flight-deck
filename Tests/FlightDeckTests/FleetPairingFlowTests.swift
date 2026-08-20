import Network
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetPairingFlowTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private var service: FleetService?
    private var client: FleetClient?
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func tearDown() async throws {
        client?.disconnect()
        service?.stop()
        client = nil
        service = nil
    }

    private func standUp() async throws -> (SessionStore, PreferencesStore, FleetService) {
        let store = SessionStore(provider: nil, persistence: nil)
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        let service = FleetService(
            store: store, preferences: preferences,
            armer: PairingArmer(now: { self.now })
        )
        self.service = service
        _ = try await service.start(port: nil)
        return (store, preferences, service)
    }

    /// The moment pairing actually completes. Nothing on the wire announces it — a
    /// successful handshake followed by a `hello` *is* the announcement.
    func testTheFirstHelloOnAnArmedSlotPairsTheDevice() async throws {
        let (_, preferences, service) = try await standUp()
        let payload = try await service.arm()
        XCTAssertEqual(preferences.pairedDevices.first?.isProvisional, true)

        let attached = expectation(description: "paired")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { if case .snapshot = $0 { attached.fulfill() } }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [attached], timeout: 10)

        let device = try XCTUnwrap(preferences.pairedDevices.first)
        XCTAssertEqual(device.slot, payload.key.slot)
        XCTAssertFalse(device.isProvisional, "a connected device is no longer provisional")
        XCTAssertNotNil(device.pairedAt)
        XCTAssertNil(device.armedUntil)
    }

    func testTheServerLearnsWhichSlotConnected() async throws {
        let (_, _, service) = try await standUp()
        let payload = try await service.arm()
        let seen = expectation(description: "slot observed")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { _ in
            MainActor.assumeIsolated {
                if service.attachedSlots.contains(payload.key.slot) { seen.fulfill() }
            }
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [seen], timeout: 10)
    }

    /// A code that was never claimed must stop being a key, not just stop being displayed.
    func testAnUnclaimedWindowExpiresOutOfTheAcceptedKeys() async throws {
        let (_, preferences, service) = try await standUp()
        let payload = try await service.arm()
        now += PairingArmer.window + 1
        try await service.expireArming()
        XCTAssertTrue(preferences.pairedDevices.isEmpty)
        XCTAssertFalse(preferences.deviceKeys().contains { $0.slot == payload.key.slot })
    }

    /// Revoking is deleting the key, and the listener must stop honouring it — not merely
    /// stop listing it.
    func testARevokedDeviceCanNoLongerConnect() async throws {
        let (_, preferences, service) = try await standUp()
        let payload = try await service.arm()
        preferences.revokeDevice(slot: payload.key.slot)
        try await service.reloadKeys()

        let refused = expectation(description: "refused")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { _ in XCTFail("a revoked device reached the application layer") }
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        // The brief's literal `XCTWaiter().await fulfillment(...)` is not valid Swift —
        // `await` cannot follow a `.`, and `fulfillment(of:timeout:)` is an `XCTestCase`
        // method, not one on `XCTWaiter`. Same call the rest of this file uses, since
        // `wait(for:)` deadlocks a `@MainActor` async test (see the class doc).
        await fulfillment(of: [refused], timeout: 8)
    }

    func testArmingTwiceLeavesOnlyTheNewestCodeLive() async throws {
        let (_, preferences, service) = try await standUp()
        let first = try await service.arm()
        let second = try await service.arm()
        XCTAssertEqual(preferences.pairedDevices.map(\.slot), [second.key.slot])
        XCTAssertFalse(preferences.deviceKeys().contains { $0.slot == first.key.slot })
    }

    func testThePairingCodeAdvertisesTheListenersRealPort() async throws {
        let (_, _, service) = try await standUp()
        let payload = try await service.arm()
        let port = try XCTUnwrap(service.boundPort)
        XCTAssertFalse(payload.endpoints.isEmpty, "a code with no candidates cannot be raced")
        XCTAssertTrue(payload.endpoints.allSatisfy { $0.hasSuffix(":\(port.rawValue)") })
    }
}
