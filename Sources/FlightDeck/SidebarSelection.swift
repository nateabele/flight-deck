import Foundation

/// The sidebar `List` has one `UUID?` selection, but its rows now carry two kinds of id:
/// project headers are tagged with `Repo.id`, session rows with `Session.id`. UUIDs never
/// collide, so the binding's setter routes on membership instead of widening the selection
/// type — which would ripple through every `selectedSessionID` reader (persistence, the
/// phone, the CLI, unread tracking).
enum SidebarSelection {
    enum Route: Equatable { case project(UUID), session(UUID?) }

    static func route(_ newValue: UUID?, projectIDs: Set<UUID>) -> Route {
        if let newValue, projectIDs.contains(newValue) { return .project(newValue) }
        return .session(newValue)
    }
}
