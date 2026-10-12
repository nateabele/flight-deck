import Foundation
import UserNotifications

/// How the Reaper tells the user a cloud machine is about to go, or went. A seam for the same
/// reason as `Notifying`: `UNUserNotificationCenter.current()` traps when the calling binary is
/// not a signed bundle, which is exactly the case inside the unit-test bundle.
protocol InfraNotifying: Sendable {
    /// `id` names the banner: a later notification with the same id replaces it, so a machine
    /// shows one TTL warning, not a stack of them.
    func notify(id: String, title: String, body: String)
}

/// The real one. Authorization is `SessionNotifier`'s, asked for once at launch for the app.
struct UserNotificationInfraNotifier: InfraNotifying {
    func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
