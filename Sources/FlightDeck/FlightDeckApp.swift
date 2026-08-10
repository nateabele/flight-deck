import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        RootWindow(ghostty: appDelegate.ghostty)
    }
}
