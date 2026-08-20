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

    /// The data-layer half of expiry, and only that half: an expired provisional row must
    /// not appear in `deviceKeys(at:)`, regardless of whether anything ever called
    /// `expire()` on it. This asserts against `PreferencesStore` alone — no listener, no
    /// socket, no relaunch — so it does NOT prove a real listener that already ran once with
    /// the old key set stops answering it; a listener's accepted keys are derived once at
    /// `start()`, not re-derived on every query, so that is a separate question this test
    /// does not reach. See `testAProvisionalDeviceLeftOverFromAQuitProcessIsRefusedAfterRelaunch`
    /// for the one that does.
    func testAnExpiredProvisionalKeyIsRefusedEvenIfNothingPrunedIt() async throws {
        let (_, preferences, service) = try await standUp()
        let payload = try await service.arm()

        let afterExpiry = Date().addingTimeInterval(PairingArmer.window + 1)
        XCTAssertFalse(preferences.pairedDevices.isEmpty)
        XCTAssertFalse(
            preferences.deviceKeys(at: afterExpiry).contains { $0.slot == payload.key.slot },
            "an expired window must not still be a key"
        )
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

    /// The layer the bug actually lived in. `FleetService.start()` derives its accepted key
    /// set exactly once and nothing re-derives it for the rest of the process — every layer
    /// that enforces the 120-second window (the pairing sheet's timer, `expiryTask`,
    /// `PairingArmer.pending`) is a `Task` or an in-memory field that dies with the process.
    /// A quit or crash mid-window leaves the persisted provisional row behind with nothing
    /// left alive to prune it, so the process that inherits it at relaunch must refuse it
    /// itself, at `start()`, before it ever derives a key set — which is exactly what this
    /// asserts by standing up a SECOND `FleetService` against the SAME persisted
    /// `Preferences` a first one armed and then "quit" without unarming. Nothing here waits
    /// out the window: the ruling this proves is that a provisional row orphaned by a quit
    /// is revoked outright on the next `start()`, not merely re-timed, so the refusal holds
    /// immediately — not just after the 120 seconds would have elapsed anyway.
    func testAProvisionalDeviceLeftOverFromAQuitProcessIsRefusedAfterRelaunch() async throws {
        let persistence = MemoryPersistence()

        let firstPreferences = PreferencesStore(persistence: persistence)
        let firstService = FleetService(
            store: SessionStore(provider: nil, persistence: nil), preferences: firstPreferences,
            armer: PairingArmer(now: { self.now })
        )
        _ = try await firstService.start(port: nil)
        let payload = try await firstService.arm()
        XCTAssertEqual(firstPreferences.pairedDevices.first?.isProvisional, true)

        // The process dies here: no `cancelArming`, no `expireArming`, nothing that would
        // ordinarily clean this up. `firstService`'s `expiryTask` and its armer's `pending`
        // die with it — only the persisted row in `persistence` survives, exactly as a real
        // quit or crash leaves it. Stopped explicitly only to free its socket for the test
        // process; a real quit does this for free.
        firstService.stop()

        // Relaunch: a fresh service, a fresh armer (so `pending == nil`, same as a real
        // process boot), reading the same persisted rows through a fresh `PreferencesStore`.
        let secondPreferences = PreferencesStore(persistence: persistence)
        let secondService = FleetService(
            store: SessionStore(provider: nil, persistence: nil), preferences: secondPreferences,
            armer: PairingArmer(now: { self.now })
        )
        self.service = secondService
        _ = try await secondService.start(port: nil)

        let refused = expectation(description: "refused")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { _ in
            XCTFail("a provisional device orphaned by a quit reached the application layer")
        }
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: try secondService.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [refused], timeout: 8)

        // Revoked, not merely refused: `DevicesSettingsTab` hides provisional rows, so a
        // row left behind here would be invisible AND permanently dead — the phone can never
        // reconnect and the user has nothing on screen explaining why.
        XCTAssertTrue(
            secondPreferences.pairedDevices.isEmpty,
            "a provisional row orphaned by a quit must be revoked outright at the next start(), not merely re-timed"
        )
    }

    func testArmingTwiceLeavesOnlyTheNewestCodeLive() async throws {
        let (_, preferences, service) = try await standUp()
        let first = try await service.arm()
        let second = try await service.arm()
        XCTAssertEqual(preferences.pairedDevices.map(\.slot), [second.key.slot])
        XCTAssertFalse(preferences.deviceKeys().contains { $0.slot == first.key.slot })
    }

    /// Cancelling must take the provisional key out of the accepted set, not merely stop
    /// drawing the sheet. An armed code whose window was closed in the UI but whose key is
    /// still live is the same hole as one that never expired.
    func testCancellingArmingRevokesTheProvisionalKey() async throws {
        let (_, preferences, service) = try await standUp()
        let payload = try await service.arm()
        try await service.cancelArming()

        XCTAssertTrue(preferences.pairedDevices.isEmpty)
        XCTAssertFalse(preferences.deviceKeys().contains { $0.slot == payload.key.slot })

        let refused = expectation(description: "refused")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { _ in XCTFail("a cancelled code must not reach application code") }
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        // `wait(for:)` deadlocks a `@MainActor` async test under this repo's headless
        // harness (see the class doc) — `await fulfillment(of:timeout:)` throughout this
        // file instead, same as the coordinator's own `refused` pattern elsewhere.
        await fulfillment(of: [refused], timeout: 8)
    }

    func testThePairingCodeAdvertisesTheListenersRealPort() async throws {
        let (_, _, service) = try await standUp()
        let payload = try await service.arm()
        let port = try XCTUnwrap(service.boundPort)
        XCTAssertFalse(payload.endpoints.isEmpty, "a code with no candidates cannot be raced")
        XCTAssertTrue(payload.endpoints.allSatisfy { $0.hasSuffix(":\(port.rawValue)") })
    }
}
