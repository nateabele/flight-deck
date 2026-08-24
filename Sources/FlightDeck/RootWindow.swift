import SwiftUI

/// A `Window`, not a `WindowGroup`: Flight Deck is a single-window app. This is also what
/// frees ⌘N — `WindowGroup` claims it for File ▸ New Window. Closing this window quits,
/// because `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns true.
struct RootWindow: Scene {
    @ObservedObject var store: SessionStore
    var preferences: PreferencesStore?
    /// Sessions a paired phone has open. Threaded down rather than reached for: the fleet is
    /// the app's dependency, not the window's, and a view that fetched a service it does not
    /// own could not be previewed or tested without one.
    var phoneActiveSessions: Set<UUID> = []

    var body: some Scene {
        Window("Flight Deck", id: "main") {
            RootView(store: store, preferences: preferences,
                     phoneActiveSessions: phoneActiveSessions)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
