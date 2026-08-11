import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore

    init() {
        // Read the launch argument here rather than in a view: with a single window the
        // store is app-scoped, and `.commands` needs to reach it.
        let delegate = AppDelegate.shared
        let resetState = UserDefaults.standard.bool(forKey: "FlightDeckResetState")
        _store = StateObject(
            wrappedValue: SessionStore(ghostty: delegate?.ghostty, resetState: resetState)
        )
    }

    var body: some Scene {
        RootWindow(store: store)
    }
}
