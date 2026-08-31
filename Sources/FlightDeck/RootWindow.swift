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
    /// Sessions a paired phone has open. Threaded down rather than reached for: the fleet is
    /// the app's dependency, not the window's, and a view that fetched a service it does not
    /// own could not be previewed or tested without one.
    var phoneActiveSessions: Set<UUID> = []

    var body: some Scene {
        // The scene title is the pre-selection value only: `RootView` applies a
        // `navigationTitle` naming the active project, which is what the user actually sees.
        // Spelled as `WindowTitle.base` so the empty-state title cannot drift from the one
        // that rule falls back to.
        Window(WindowTitle.base, id: Self.id) {
            RootView(store: store, preferences: preferences,
                     phoneActiveSessions: phoneActiveSessions)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
