import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore

    init() {
        // `wrappedValue` is an @autoclosure: this call is NOT evaluated here. That is
        // load-bearing — constructing the store touches `GhosttyApp.shared`, which reads
        // `NSApp.isActive`, and `NSApp` does not exist yet during `App.init`. SwiftUI
        // evaluates the thunk later, once the app is up.
        _store = StateObject(wrappedValue: Self.makeStore())
    }

    @MainActor
    private static func makeStore() -> SessionStore {
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
        return SessionStore(ghostty: GhosttyApp.shared, resetState: resetState, notifier: notifier)
    }

    var body: some Scene {
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }
    }
}
