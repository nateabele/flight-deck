import Foundation

/// What the main window's title bar says: `Flight Deck - <project>` for the project the
/// active session is filed under, and the bare product name when nothing is selected.
///
/// A free-standing rule rather than a string built inline in `RootView` for the usual
/// reason (`docs/CONVENTIONS.md`): the interesting part is the fallback, and a headless
/// test can exercise it here without a window, a scene, or a running app.
///
/// The separator is a plain hyphen, not an en/em dash. It is what the window title has
/// always read, it is what a `wmctrl`-style window query or a screenshot filename ends up
/// carrying, and swapping it for a typographic dash would silently break any of those.
enum WindowTitle {
    /// The title with no project to name — the empty state, and the value the
    /// `RootWindow` scene is declared with, so the two cannot drift.
    static let base = "Flight Deck"

    /// - Parameter project: the active project's display name, or nil when nothing is
    ///   selected. Blank and whitespace-only names are treated as nil rather than rendered:
    ///   `Repo.displayName` is a URL's `lastPathComponent`, which is `""` for `/`, and
    ///   "Flight Deck - " with a dangling separator reads as a bug.
    static func text(project: String?) -> String {
        guard
            let project,
            !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return base }
        return "\(base) - \(project)"
    }
}
