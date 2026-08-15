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

    /// Fires only on the *edge* from a known working state into `.idle`, so a session that
    /// simply stays idle is not re-marked on every poll — the same edge-triggering
    /// `SessionNotificationPolicy` uses.
    ///
    /// "Known working state" is load-bearing, not incidental. A missing `old` is not an edge:
    /// it is the app launching, a `claude` restarting, or a session registering for the first
    /// time. None of those are something the user missed, and treating them as edges lit the
    /// entire sidebar blue on every launch.
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
        // `old` must exist AND have been non-idle: the rule is "we watched it working and it
        // stopped", not "it is idle now". Accepting a nil `old` made launch itself an edge —
        // `statuses` starts empty, so the first registry read is `nil -> idle` for every
        // session at once, and the whole sidebar came up marked unread.
        guard let old, old.activity != .idle, new?.activity == .idle else { return .none }
        return isViewed ? .clear : .mark
    }
}
