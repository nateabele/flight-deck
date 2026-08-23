import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// Stands up a real `FleetService` over a real socket with one paired device.
///
/// Extracted verbatim from `FleetServiceTests.standUp()`, which was the only copy until the
/// timeline tests needed the same thing. It is a `final class` rather than a function
/// returning a tuple because the caller has to keep the service alive for the length of the
/// test — a returned service with no owner is cancelled out from under the socket.
@MainActor
final class FleetTestHarness {
    let store: SessionStore
    let preferences: PreferencesStore
    let service: FleetService
    let key: FleetDeviceKey

    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    init() {
        store = SessionStore(provider: nil, persistence: nil)
        key = FleetDeviceKey.mint()
        preferences = PreferencesStore(persistence: MemoryPersistence())
        preferences.upsert(
            PairedDevice(
                slot: key.slot, name: "test device", secret: key.secret,
                pairedAt: Date(), lastSeenAt: nil, armedUntil: nil
            )
        )
        service = FleetService(store: store, preferences: preferences, armer: PairingArmer())
    }

    @discardableResult
    func start() async throws -> NWEndpoint.Port { try await service.start(port: nil) }
}
