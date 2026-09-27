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
    /// `ignore` is distinct from `session(nil)`: both arrive as the `List` writing `nil`, but
    /// only one of them means "the user deselected a session". With headers `.selectionDisabled()`,
    /// nothing the user does to a project row can legitimately produce a `nil` write any more —
    /// but SwiftUI's own `List` machinery can: selecting a project deselects the table (nothing
    /// is tagged with the project id — see the file-level comment above), and that deselection
    /// can itself echo back through this same binding as a `nil` write, arriving right behind
    /// the `selectProject` call that set `currentProject` in the first place. Routing that echo
    /// to `session(nil)` would zero `selectedSessionID` for a session the user never touched;
    /// routing it to a project-clearing action (an earlier version of this case, `clearProject`)
    /// would instantly undo the very selection that produced it. Neither reflects anything the
    /// user asked for, so `ignore` leaves both selections exactly as they were.
    enum Route: Equatable { case project(UUID), session(UUID?), ignore }

    static func route(_ newValue: UUID?, projectIDs: Set<UUID>, currentProject: UUID?) -> Route {
        if let newValue, projectIDs.contains(newValue) { return .project(newValue) }
        if newValue == nil, currentProject != nil { return .ignore }
        return .session(newValue)
    }
}
