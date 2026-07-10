import SwiftUI

struct RootWindow: Scene {
    var body: some Scene {
        WindowGroup {
            TerminalContainer(workingDirectory: NSHomeDirectory())
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
