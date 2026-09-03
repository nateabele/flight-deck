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

    /// `store` is overridable so a test that needs a real provider (or a stubbed `display`,
    /// per `DisplayDrawableGuardTests`) can supply its own rather than being stuck with the
    /// providerless default every other caller here relies on.
    init(store: SessionStore? = nil) {
        self.store = store ?? SessionStore(provider: nil, persistence: nil)
        key = FleetDeviceKey.mint()
        preferences = PreferencesStore(persistence: MemoryPersistence())
        preferences.upsert(
            PairedDevice(
                slot: key.slot, name: "test device", secret: key.secret,
                pairedAt: Date(), lastSeenAt: nil, armedUntil: nil
            )
        )
        service = FleetService(store: self.store, preferences: preferences, armer: PairingArmer())
        // Silenced by default, because the production sink appends to the developer's own
        // `~/Library/Logs/flight-deck-prompt.log` and every status change in every fleet test
        // would land in it. A test that wants the records replaces this closure — see
        // `PromptLifecycleTests`.
        service.promptLifecycleForTesting = { _ in }
        // The store's own half of the same problem: `abortPrompt` and `checkStuckPrompts` file
        // through `store.promptLifecycleSink` directly, never through the service, so silencing
        // only the line above leaves that second stream writing to the same real file. A test
        // that wants those records replaces this closure too — see `AbortPromptLoopbackTests`.
        self.store.promptLifecycleSink = { _ in }
    }

    @discardableResult
    func start() async throws -> NWEndpoint.Port { try await service.start(port: nil) }
}
