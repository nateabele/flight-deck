/// Decides whether a status transition leaves a session marked "finished while you were
/// away" — the unread dot in the sidebar.
///
/// Pure and total, for the same reason as `SessionNotificationPolicy`: the whole rule is
/// testable without SwiftUI, `NSApplication`, or a live registry.
enum SessionReadPolicy {
    enum Change: Equatable {
        case none
        case mark
        case clear
    }

    /// Fires only on the *edge* into `.idle`, so a session that simply stays idle is not
    /// re-marked on every poll — the same edge-triggering `SessionNotificationPolicy` uses.
    ///
    /// Because it is an edge, the `.clear` case is what keeps this self-correcting: a session
    /// that finishes while you are watching it clears any older mark, so nothing has to
    /// explicitly reset the flag when a session cycles busy → idle in view. Leaving `.idle`
    /// deliberately produces `.none`: a busy session renders a spinner, so its mark is
    /// invisible until it lands back on idle and this runs again.
    ///
    /// `isViewed` means "the user is looking at this tab right now" — selected *and* the app
    /// frontmost. Selected-but-backgrounded still marks, which is the case the feature exists
    /// for: you left, it finished, you should be able to see that when you come back.
    static func change(
        old: SessionStatus?, new: SessionStatus?, isViewed: Bool
    ) -> Change {
        let wasIdle = old?.activity == .idle
        let isIdle = new?.activity == .idle

        guard isIdle, !wasIdle else { return .none }
        return isViewed ? .clear : .mark
    }
}
