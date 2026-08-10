import SwiftUI

struct RootWindow: Scene {
    let ghostty: GhosttyApp?

    var body: some Scene {
        WindowGroup {
            RootView(ghostty: ghostty)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
