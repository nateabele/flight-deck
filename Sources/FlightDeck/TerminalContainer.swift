import SwiftUI

/// Hosts a single live libghostty terminal surface in SwiftUI.
///
/// Owns and retains one `GhosttyApp` (the libghostty app-state) for the lifetime
/// of the view via the coordinator. If the `GhosttyApp` were allowed to
/// deallocate, its `ghostty_app_t` would be freed and the surface would die, so
/// the coordinator holds a strong reference for as long as the view exists.
struct TerminalContainer: NSViewRepresentable {
    /// Working directory the shell launches in.
    let workingDirectory: String

    init(workingDirectory: String = NSHomeDirectory()) {
        self.workingDirectory = workingDirectory
    }

    /// Retains the app-state and the surface view for the view's lifetime.
    final class Coordinator {
        let app: GhosttyApp?
        var surfaceView: Ghostty.SurfaceView?

        init() {
            self.app = GhosttyApp()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let app = context.coordinator.app else {
            Ghostty.logger.critical("GhosttyApp unavailable; terminal cannot start")
            return NSView()
        }

        // Point the surface at the resolved login shell in the requested directory.
        var config = Ghostty.SurfaceConfiguration()
        config.command = ShellResolver.resolve()
        config.workingDirectory = workingDirectory

        let surfaceView = app.makeSurfaceView(baseConfig: config)
        context.coordinator.surfaceView = surfaceView
        if let error = surfaceView.error {
            Ghostty.logger.critical("terminal surface creation failed: \(String(describing: error))")
        }

        // libghostty only advances its event loop when ticked. The app's wakeup
        // callback schedules subsequent ticks on the main thread; kick an initial
        // tick so the first frame renders without waiting on an external event.
        app.tick()

        return surfaceView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Nothing to reconcile: the surface manages its own rendering and sizing.
    }
}
