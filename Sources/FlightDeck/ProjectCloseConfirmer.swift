import AppKit

/// What the user decided, and whether they asked not to be asked again.
struct ProjectCloseDecision: Equatable {
    var confirmed: Bool
    var suppressFutureConfirmations: Bool
}

/// Seam over the close confirmation, so the "prompt or not" logic in
/// `ProjectCloseCoordinator` is testable without putting a panel on screen.
@MainActor
protocol ProjectCloseConfirming {
    func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision
}

/// The real thing.
///
/// `NSAlert` rather than SwiftUI's `.alert` or `.confirmationDialog`: neither can host a
/// suppression checkbox, and `NSAlert.showsSuppressionButton` exists for exactly this case
/// and draws the platform-standard control.
@MainActor
struct NSAlertProjectCloseConfirmer: ProjectCloseConfirming {
    /// Injectable so a headless context can fall back to a modal run rather than trapping
    /// on a nil window.
    var window: () -> NSWindow? = { NSApp.keyWindow }

    func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close the project “\(name)”?"
        alert.informativeText = """
            This closes \(sessionCount) sessions. Any commands still running in them will be \
            terminated.
            """

        let close = alert.addButton(withTitle: "Close Project")
        close.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return takes the safe path. `addButton` makes the first button the default, and a
        // destructive default is exactly the alert people dismiss into data loss.
        close.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"

        let response: NSApplication.ModalResponse
        if let window = window() {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        return ProjectCloseDecision(
            confirmed: response == .alertFirstButtonReturn,
            // Read after the alert closes, and recorded whichever button was pressed: the
            // box applies to the decision the user just made, which is what every other
            // macOS app does with it.
            suppressFutureConfirmations: alert.suppressionButton?.state == .on
        )
    }
}

/// Decides whether closing a project needs to ask, asks if so, and then closes.
///
/// A separate type from the view so the branching is a unit test rather than a UI test.
@MainActor
struct ProjectCloseCoordinator {
    let store: SessionStore
    let preferences: PreferencesStore?
    let confirmer: ProjectCloseConfirming

    func requestClose(projectAt id: Repo.ID) async {
        guard let repo = store.repos.first(where: { $0.id == id }) else { return }

        // One session or none closes outright — that is what a single session's own close
        // button already does, and an alert to confirm closing one thing is noise.
        guard repo.sessions.count > 1, preferences?.confirmsProjectClose ?? true else {
            store.closeProject(id)
            return
        }

        let decision = await confirmer.confirmClose(
            projectNamed: repo.displayName, sessionCount: repo.sessions.count
        )
        if decision.suppressFutureConfirmations {
            preferences?.confirmsProjectClose = false
        }
        guard decision.confirmed else { return }
        store.closeProject(id)
    }
}
