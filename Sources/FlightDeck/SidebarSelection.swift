import Foundation

/// The sidebar `List` has one `UUID?` selection. Project headers no longer carry a `.tag` into
/// it — see `ProjectHeaderRow`'s and `SessionSidebar`'s doc comments for why native selection
/// had to come back off headers — so `newValue` here now only ever arrives as a session id or
/// `nil`; nothing the List reports can equal a project id any more, since no visible row is
/// tagged with one. `.project` below is consequently unreachable from the List's own writes,
/// but stays: `route`'s signature is shared with `store.selectProject`, which now comes
/// exclusively from `SidebarInputMonitor.selectRow` instead, and widening the selection type
/// back out for sessions alone would ripple through every `selectedSessionID` reader
/// (persistence, the phone, the CLI, unread tracking) for no gain.
enum SidebarSelection {
    /// `clearProject` is distinct from `session(nil)`: both can arrive as the `List` writing
    /// `nil` — most commonly a click in the blank area below the last row, or Escape, since a
    /// project header can no longer be ⌘-clicked to produce this directly — but only one of
    /// them means "the user deselected a session". Collapsing them into `session(nil)` would
    /// zero `selectedSessionID` for a session the user never touched, losing which terminal
    /// was selected underneath the project view.
    enum Route: Equatable { case project(UUID), session(UUID?), clearProject }

    static func route(_ newValue: UUID?, projectIDs: Set<UUID>, currentProject: UUID?) -> Route {
        if let newValue, projectIDs.contains(newValue) { return .project(newValue) }
        if newValue == nil, currentProject != nil { return .clearProject }
        return .session(newValue)
    }
}
