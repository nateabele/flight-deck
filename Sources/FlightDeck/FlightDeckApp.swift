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
        let store = SessionStore(ghostty: GhosttyApp.shared, resetState: resetState)
        // Injected here rather than built inside the store: `UNUserNotificationCenter`
        // traps outside a signed bundle, and `SessionStore`'s convenience init is
        // reachable from tests (SessionPersistenceTests). This factory is not.
        let notifier = SessionNotifier()
        notifier.requestAuthorization()
        store.notifier = notifier
        return store
    }

    var body: some Scene {
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }
    }
}
