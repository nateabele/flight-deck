import Foundation

/// Translates a move expressed in flattened sidebar-row indices into a new `[Repo]`.
///
/// Kept as a free function over plain values rather than a method on `SessionStore` so the
/// whole reorder policy — what may move where, and what a drag does to the projects it
/// passes over — is testable without a store, a surface provider, or SwiftUI.
///
/// `nil` means "illegal move; change nothing". A legal move that happens to resolve to no
/// change returns the array unchanged, which is what `Array.move` already does.
enum SidebarReorder {
    static func apply(
        to repos: [Repo],
        rows: [SidebarRow],
        from source: IndexSet,
        to destination: Int
    ) -> [Repo]? {
        // The sidebar drags exactly one row; a multi-row move is not a gesture we model.
        guard source.count == 1, let from = source.first else { return nil }
        guard rows.indices.contains(from) else { return nil }
        // `destination == rows.count` is "append", and is legal.
        guard destination >= 0, destination <= rows.count else { return nil }

        switch rows[from] {
        case .empty:
            // A placeholder is a label, not a thing.
            return nil

        case .project(let projectID):
            guard let source = repos.firstIndex(where: { $0.id == projectID }) else { return nil }
            // The destination in *project* space is however many project headers precede it
            // in row space. This is what makes a project drag move its whole block: the
            // sessions between two headers never contribute to the count.
            let insertion = rows.prefix(destination).filter { row in
                if case .project = row { return true }
                return false
            }.count
            var updated = repos
            updated.move(fromOffsets: IndexSet(integer: source), toOffset: insertion)
            return updated

        case .session(let sessionID, let projectID):
            guard
                let projectIndex = repos.firstIndex(where: { $0.id == projectID }),
                let headerRow = rows.firstIndex(of: .project(projectID)),
                let sessionIndex = repos[projectIndex].sessions
                    .firstIndex(where: { $0.id == sessionID })
            else { return nil }

            // A session may be inserted anywhere inside its own project's block, including
            // the slot just past its last session — which is the flat index of the *next*
            // project's header. That position is not ambiguous for a session drag: inserting
            // before the next header is what "move to the end of this project" means, and
            // rejecting it would make it impossible to drag a project's first session to
            // last. Anything beyond it belongs to another project and is refused.
            //
            // Refused rather than clamped, deliberately: clamping would silently turn "drag
            // into the project below" into "drop at the bottom of this one", which reads as
            // the app ignoring the gesture it was given.
            let firstSlot = headerRow + 1
            let lastSlot = firstSlot + repos[projectIndex].sessions.count
            guard destination >= firstSlot, destination <= lastSlot else { return nil }

            var updated = repos
            updated[projectIndex].sessions.move(
                fromOffsets: IndexSet(integer: sessionIndex),
                toOffset: destination - firstSlot
            )
            return updated
        }
    }
}
