import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: PreferencesStore
    @StateObject private var store: SessionStore

    init() {
        // Constructed eagerly, unlike the store: this only reads `UserDefaults`, and both
        // the Settings scene and the store below need the *same* instance.
        let preferences = PreferencesStore()
        _preferences = StateObject(wrappedValue: preferences)

        // `wrappedValue` is an @autoclosure: this call is NOT evaluated here. That is
        // load-bearing — constructing the store touches `GhosttyApp.shared`, which reads
        // `NSApp.isActive`, and `NSApp` does not exist yet during `App.init`. SwiftUI
        // evaluates the thunk later, once the app is up.
        _store = StateObject(wrappedValue: Self.makeStore(preferences: preferences))
    }

    @MainActor
    private static func makeStore(preferences: PreferencesStore) -> SessionStore {
        let resetState = UserDefaults.standard.bool(forKey: "FlightDeckResetState")
        // Built here rather than inside the store: `UNUserNotificationCenter` traps
        // outside a signed bundle, and `SessionStore`'s convenience init is reachable
        // from tests (SessionPersistenceTests). This factory is not.
        //
        // Constructed and authorized BEFORE the store, then passed in, so `notifier` is
        // set before the convenience init's `startStatusWatching()` runs — see the
        // comment on that initializer.
        let notifier = SessionNotifier()
        notifier.requestAuthorization()

        // `preferences` is passed in rather than built here because the convenience init
        // restores sessions inline and resolves each one's flags as it goes, so it needs a
        // live store — and the Settings scene must observe that same instance.
        return SessionStore(
            ghostty: GhosttyApp.shared,
            resetState: resetState,
            preferences: preferences,
            notifier: notifier
        )
    }

    var body: some Scene {
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }

        // A `Settings` scene gives ⌘, and the standard Preferences window for free.
        Settings {
            PreferencesView(preferences: preferences, sessions: store)
        }
    }
}
