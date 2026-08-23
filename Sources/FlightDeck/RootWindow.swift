import SwiftUI

/// A `Window`, not a `WindowGroup`: Flight Deck is a single-window app. This is also what
/// frees ⌘N — `WindowGroup` claims it for File ▸ New Window. Closing this window quits,
/// because `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns true.
struct RootWindow: Scene {
    /// The scene id — and, because SwiftUI stamps it onto the `NSWindow`, the way the rest of
    /// the app recognizes this window among `NSApp.windows`. Shared rather than spelled twice
    /// so the two cannot drift; see `SessionWindow`, which is what reads it.
    static let id = "main"

    @ObservedObject var store: SessionStore
    var preferences: PreferencesStore?

    var body: some Scene {
        Window("Flight Deck", id: Self.id) {
            RootView(store: store, preferences: preferences)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
