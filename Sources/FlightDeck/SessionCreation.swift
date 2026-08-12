import Foundation

/// Which creation intent a trigger resolves to, and how a dropped URL becomes a project
/// directory. Pure so both rules are testable without a menu or a real drag session.
enum SessionCreateAction: Equatable {
    /// Add a session to the active project (⌘N).
    case newSession
    /// Pick or accept a folder and create a session in it (⌘⇧A, folder drop).
    case addProject

    /// ⌘N reroutes to Add Project when the sidebar is bare.
    ///
    /// Keyed on *projects*, not sessions: a project with no sessions in it is still
    /// somewhere to put one, so ⌘N should create there rather than prompting for a folder.
    ///
    /// The menu item stays enabled in both states deliberately: a disabled `NSMenuItem`
    /// does not fire its key equivalent, so disabling New Session when empty would make ⌘N
    /// dead in exactly the state it needs to work.
    static func forState(hasProjects: Bool) -> SessionCreateAction {
        hasProjects ? .newSession : .addProject
    }

    /// A directory resolves to itself; anything else resolves to its parent, so dropping a
    /// file out of a repo adds that repo. A path that does not exist is treated as a file.
    static func projectDirectory(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }
}
