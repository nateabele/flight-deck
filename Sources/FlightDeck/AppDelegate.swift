import AppKit

/// Owns the one libghostty app for the whole process. Because the delegate
/// outlives every window and surface, the deferred ghostty_surface_free in
/// Ghostty.Surface.deinit can never race a freed app — this is the fix for the
/// documented teardown-lifetime hazard.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let ghostty: GhosttyApp? = GhosttyApp()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
