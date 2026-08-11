import Foundation

/// Decides whether a status transition should raise, withdraw, or ignore a notification.
///
/// Pure and total so the whole policy is testable without `UNUserNotificationCenter`,
/// which cannot be instantiated in the unit-test bundle.
enum SessionNotificationPolicy {
    enum Action: Equatable {
        case none
        case notify(waitingFor: String?)
        case withdraw
    }

    /// Fires only on the *edge* into `waiting`, so a session that stays blocked does not
    /// re-notify on every poll. Withdrawal ignores `appActive`: once the prompt is gone
    /// the banner is stale regardless of where focus was.
    static func action(
        old: SessionStatus?, new: SessionStatus?, appActive: Bool
    ) -> Action {
        let wasWaiting = old?.activity == .waiting
        let isWaiting = new?.activity == .waiting

        if isWaiting, !wasWaiting {
            return appActive ? .none : .notify(waitingFor: new?.waitingFor)
        }
        if wasWaiting, !isWaiting {
            return .withdraw
        }
        return .none
    }
}
