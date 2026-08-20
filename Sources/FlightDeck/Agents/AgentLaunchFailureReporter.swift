import AppKit

/// Seam over "tell the user this tab could not be created or relaunched", so the three
/// `SessionStore` paths that refuse one — `createSession`, `newSession`, and `restore` — can
/// be tested without putting a panel on screen. The same shape and the same reason as
/// `ProjectCloseConfirming`.
///
/// `newSession` and `restore` report through here *only*: neither has a `Result` to hand back
/// (one is claude's synchronous path, the other rebuilds the whole deck), so this is not a
/// convenience for them, it is the entire error channel.
@MainActor
protocol AgentLaunchFailureReporting {
    func report(_ error: AgentLaunchError)
}

/// The real thing.
///
/// An alert rather than a silently-returned `Result`: a failed creation leaves *nothing*
/// behind — no tab, no row, no terminal — so there is no surface left on which the failure
/// could be noticed. `AgentLaunchError.errorDescription` already names the cause and what to
/// do about it, which is why it is the informative text verbatim.
///
/// `NSAlert` rather than SwiftUI's `.alert` for the same reason `NSAlertProjectCloseConfirmer`
/// uses it: the store is not a view, and routing this through published state would mean a
/// second piece of alert plumbing in every window that can create a session.
@MainActor
struct NSAlertAgentLaunchFailureReporter: AgentLaunchFailureReporting {
    /// Injectable so a test can say which window — and so the no-window case is reachable
    /// without one.
    var window: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }

    func report(_ error: AgentLaunchError) {
        let text = error.errorDescription ?? "\(error)"

        // No window means nowhere to hang a sheet — and emphatically NOT a reason to fall
        // back to `runModal()`, which is what `NSAlertProjectCloseConfirmer` can do only
        // because a *view* calls it. This is reached from the store, so the calling context
        // may be a headless one with no run loop and nobody to click the button: a modal
        // panel there puts an undismissable alert on screen and blocks whatever raised it.
        // Production always has a window, because a session can only be created from one.
        guard let window = window() else {
            NSLog("Flight Deck could not start the session: %@", text)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not start the session."
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        // A sheet, not a modal run: the failure belongs to the window the user asked from,
        // and nothing about it needs to stop the rest of the app.
        alert.beginSheetModal(for: window)
    }
}
