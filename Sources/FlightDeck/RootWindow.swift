import SwiftUI

struct RootWindow: Scene {
    let ghostty: GhosttyApp?

    var body: some Scene {
        WindowGroup {
            RootView(ghostty: ghostty)
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
