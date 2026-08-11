import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when the user clicks a session notification. userInfo: `["sessionID": UUID]`.
    /// A `NotificationCenter` hop rather than a direct reference because `AppDelegate` is
    /// created by `@NSApplicationDelegateAdaptor` and the store by `FlightDeckApp.init`,
    /// with no ordering guarantee between them.
    static let flightDeckActivateSession = Notification.Name("FlightDeckActivateSession")
}

/// Delivery seam. `SessionNotifier` is the real implementation; tests substitute a spy.
///
/// The protocol is load-bearing, not ceremony: `UNUserNotificationCenter.current()` traps
/// when the calling binary is not a signed bundle, which is exactly the case inside the
/// unit-test bundle. Nothing reachable from a test may touch it.
protocol Notifying: AnyObject {
    func requestAuthorization()
    func notify(sessionID: UUID, title: String, body: String)
    func withdraw(sessionID: UUID)
}

final class SessionNotifier: Notifying {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // A denial is not an error: the sidebar icons still convey everything.
        }
    }

    /// The request identifier is the session UUID, so a second prompt for the same
    /// session replaces its banner instead of stacking, and `withdraw` targets exactly one.
    func notify(sessionID: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionID": sessionID.uuidString]
        center.add(
            UNNotificationRequest(
                identifier: sessionID.uuidString, content: content, trigger: nil
            )
        )
    }

    func withdraw(sessionID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [sessionID.uuidString])
    }
}
