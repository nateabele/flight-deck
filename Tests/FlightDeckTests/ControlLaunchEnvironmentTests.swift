import XCTest
@testable import FlightDeck

@MainActor
final class ControlLaunchEnvironmentTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    /// A store with a live `PreferencesStore`, built the way `FleetTestHarness` builds one's
    /// preferences: `SessionStore.preferences` is a `let` handed in at init, so a bare store has
    /// no Shell pane at all and the override below would silently test nothing.
    private func makeStore() -> SessionStore {
        SessionStore(
            provider: nil, persistence: nil,
            preferences: PreferencesStore(persistence: MemoryPersistence())
        )
    }

    func testALaunchedTabCarriesItsControlIdentityAndTheShellPaneCannotOverrideIt() {
        let store = makeStore()
        let secret = Data(repeating: 3, count: 32)
        store.controlSocket = URL(fileURLWithPath: "/s/control.sock")
        store.controlSecret = secret
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        // A hand-typed value in the Shell pane must not repoint a tab at another app instance.
        store.preferences?.preferences.shell.environment["FLIGHT_DECK_CONTROL_SOCKET"] = "/elsewhere"
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertEqual(env["FLIGHT_DECK_SESSION_ID"], session.id.uuidString)
        XCTAssertEqual(env["FLIGHT_DECK_CONTROL_SOCKET"], "/s/control.sock")
        XCTAssertEqual(ControlEnvironment.session(forToken: env["FLIGHT_DECK_CALLER"] ?? "", secret: secret),
                       session.id)
    }

    func testNoControlVariablesWhenTheSocketIsOff() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertNil(env["FLIGHT_DECK_CONTROL_SOCKET"])
    }
}
