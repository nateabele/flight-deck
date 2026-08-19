import AppKit

/// Seam over "tell the user this tool did not start", the same shape and for the same reason
/// as `AgentLaunchFailureReporting`: the launcher can then be tested without a panel on screen.
@MainActor
protocol ToolLaunchFailureReporting {
    func report(tool: String, message: String)
}

/// The real thing.
///
/// A tool that fails leaves nothing behind — no window, no tab, no output — so there is no
/// surface on which the failure could otherwise be noticed. The likeliest case by far is
/// `$EDITOR` unset: the login shell then runs a bare path, gets "permission denied", and
/// without this the user presses ⌘O and nothing whatsoever happens.
@MainActor
struct NSAlertToolLaunchFailureReporter: ToolLaunchFailureReporting {
    /// Injectable so the no-window case is reachable without one, matching
    /// `NSAlertAgentLaunchFailureReporter`.
    var window: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }

    func report(tool: String, message: String) {
        guard let window = window() else {
            NSLog("Flight Deck could not run %@: %@", tool, message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not run \(tool)."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        // A sheet rather than `runModal()`, for the reason `NSAlertAgentLaunchFailureReporter`
        // gives: nothing about a failed tool needs to stop the rest of the app.
        alert.beginSheetModal(for: window)
    }
}
