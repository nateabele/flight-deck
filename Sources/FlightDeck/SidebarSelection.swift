import Foundation

/// The sidebar `List` has one `UUID?` selection, but its rows now carry two kinds of id:
/// project headers are tagged with `Repo.id`, session rows with `Session.id`. UUIDs never
/// collide, so the binding's setter routes on membership instead of widening the selection
/// type — which would ripple through every `selectedSessionID` reader (persistence, the
/// phone, the CLI, unread tracking).
enum SidebarSelection {
    /// `clearProject` is distinct from `session(nil)`: both arise from the `List` writing
    /// `nil`, but only one of them means "the user deselected a session". ⌘-clicking the
    /// selected *project* row also writes `nil` — collapsing that into `session(nil)` would
    /// zero `selectedSessionID` for a session the user never touched, losing which terminal
    /// was selected underneath the project view.
    enum Route: Equatable { case project(UUID), session(UUID?), clearProject }

    static func route(_ newValue: UUID?, projectIDs: Set<UUID>, currentProject: UUID?) -> Route {
        if let newValue, projectIDs.contains(newValue) { return .project(newValue) }
        if newValue == nil, currentProject != nil { return .clearProject }
        return .session(newValue)
    }
}
