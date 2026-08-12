import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: PreferencesStore
    @StateObject private var store: SessionStore

    init() {
        let resetState = UserDefaults.standard.bool(forKey: "FlightDeckResetState")
        // Preferences first: SessionStore's convenience init restores sessions inline and
        // resolves each one's flags as it goes, so it needs a live store to read from.
        let preferences = PreferencesStore()
        _preferences = StateObject(wrappedValue: preferences)
        _store = StateObject(
            wrappedValue: SessionStore(
                ghostty: GhosttyApp.shared, resetState: resetState, preferences: preferences
            )
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
