/// Decides whether a status transition should raise, withdraw, or ignore a notification.
///
/// Pure and total so the whole policy is testable without `UNUserNotificationCenter`,
/// which cannot be instantiated in the unit-test bundle.
enum SessionNotificationPolicy {
    enum Action: Equatable {
        case none
        case notify
        case withdraw
    }

    /// Fires only on the *edge* into `waiting`, so a session that stays blocked does not
    /// re-notify on every poll. Withdrawal ignores `appActive`: once the prompt is gone
    /// the banner is stale regardless of where focus was.
    ///
    /// `.notify` carries no payload — the caller (`SessionStore.deliverNotifications`)
    /// builds the notification body from `status.tooltip`, which reads better than the
    /// bare `waitingFor` text this case used to carry.
    static func action(
        old: SessionStatus?, new: SessionStatus?, appActive: Bool
    ) -> Action {
        let wasWaiting = old?.activity == .waiting
        let isWaiting = new?.activity == .waiting

        if isWaiting, !wasWaiting {
            return appActive ? .none : .notify
        }
        if wasWaiting, !isWaiting {
            return .withdraw
        }
        return .none
    }
}
