import SwiftUI

/// A `Window`, not a `WindowGroup`: Flight Deck is a single-window app. This is also what
/// frees ⌘N — `WindowGroup` claims it for File ▸ New Window. Closing this window quits,
/// because `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns true.
struct RootWindow: Scene {
    @ObservedObject var store: SessionStore

    var body: some Scene {
        Window("Flight Deck", id: "main") {
            RootView(store: store)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
