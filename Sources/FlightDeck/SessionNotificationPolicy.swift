import FleetKit

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

    /// What decides a notification. A struct rather than two parameters, because "wants you"
    /// is now two independent facts and a caller passing one of them is a caller that will
    /// eventually pass only one.
    struct Input: Equatable {
        let status: SessionStatus?
        let planGate: WirePlanGate?

        /// **`waiting` OR a gate.** A gate reports `busy` — measured over 33 minutes against a
        /// real one — so the status test alone is blind to the longest block in the system.
        var wantsYou: Bool { status?.activity == .waiting || planGate != nil }

        /// What is being asked, so a re-poll of one gate is not a second event and a revised
        /// plan — a new `ExitPlanMode` call, with a new id — is.
        var subject: String? { planGate?.callID }
    }

    /// Fires on the edge into "wants you" — either a `waiting` transition or a plan gate
    /// opening — so a session that stays blocked does not re-notify on every poll, and a
    /// four-day gate polled every two seconds is one notification, not 170,000.
    static func shouldNotify(from old: Input, to new: Input) -> Bool {
        guard new.wantsYou else { return false }
        if !old.wantsYou { return true }
        // Both want you: only a change of subject is a new thing to read.
        return old.subject != new.subject && new.subject != nil
    }

    /// `.notify` carries no payload — the caller (`SessionStore.deliverNotifications`)
    /// builds the notification body itself. Withdrawal ignores `appActive`: once the thing
    /// that wanted you is gone, the banner is stale regardless of where focus was.
    static func action(old: Input, new: Input, appActive: Bool) -> Action {
        if shouldNotify(from: old, to: new) {
            return appActive ? .none : .notify
        }
        if old.wantsYou, !new.wantsYou {
            return .withdraw
        }
        return .none
    }
}
