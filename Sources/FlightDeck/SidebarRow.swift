import FleetKit
import Foundation

/// One row of the sidebar, flattened.
///
/// The sidebar deliberately does not use SwiftUI `Section`s. `.onMove` is not supported on
/// a `ForEach` that yields Sections, so section-level drag would need a hand-rolled
/// `.draggable`/`.dropDestination` pair with its own insertion indicator while session rows
/// used `.onMove` — two mechanisms with two different feels. Flattening gives one `.onMove`
/// over one list, and moves the whole reorder decision into `SidebarReorder`, where it is
/// testable without instantiating any SwiftUI.
///
/// The cost is the system's sticky, styled group header. `ProjectHeaderRow` replaces that
/// header's contents wholesale anyway, so the loss is nominal.
enum SidebarRow: Identifiable, Hashable {
    case project(Repo.ID)
    case session(Session.ID, project: Repo.ID)
    /// Stands in for "this project is expanded and has no sessions". Without it, an expanded
    /// empty project is indistinguishable from a collapsed one.
    case empty(Repo.ID)

    /// Prefixed rather than bare: a project and its placeholder carry the same `Repo.ID`, and
    /// two rows with the same identity make `ForEach` drop one of them.
    var id: String {
        switch self {
        case .project(let id): return "p:\(id.uuidString)"
        case .session(let id, _): return "s:\(id.uuidString)"
        case .empty(let id): return "e:\(id.uuidString)"
        }
    }

    /// The project this row belongs to, however it belongs to it.
    var projectID: Repo.ID {
        switch self {
        case .project(let id), .empty(let id): return id
        case .session(_, let project): return project
        }
    }

    static func rows(for repos: [Repo]) -> [SidebarRow] {
        repos.flatMap { repo -> [SidebarRow] in
            let header: SidebarRow = .project(repo.id)
            guard !repo.isCollapsed else { return [header] }
            guard !repo.sessions.isEmpty else { return [header, .empty(repo.id)] }
            return [header] + repo.sessions.map { .session($0.id, project: repo.id) }
        }
    }

    /// Whether a session's stamped account differs from what its own project resolves to
    /// today, for the same agent. Pure so the sidebar's marker is testable without a window —
    /// the comparison is two already-resolved ids, and that has nothing to do with SwiftUI.
    ///
    /// Quiet whenever the two ids already match (the overwhelmingly common case) and quiet
    /// too when neither resolves to anything (nothing configured to compare), so the marker
    /// only ever fires when a tab is genuinely running as a login its project would not have
    /// picked — a work session left open in a personal repo, or the reverse.
    static func accountMismatched(session sessionAccount: UUID?, project projectAccount: UUID?) -> Bool {
        sessionAccount != projectAccount
    }
}
