import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore

    init() {
        let resetState = UserDefaults.standard.bool(forKey: "FlightDeckResetState")
        _store = StateObject(
            wrappedValue: SessionStore(ghostty: GhosttyApp.shared, resetState: resetState)
        )
    }

    var body: some Scene {
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }
    }
}
