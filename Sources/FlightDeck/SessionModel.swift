import Foundation

/// A single terminal session. In this foundation a session is just a titled
/// terminal rooted at a working directory; agent/worktree state comes later.
struct Session: Identifiable, Equatable {
    let id: UUID
    var title: String
    let workingDirectory: String

    init(id: UUID = UUID(), title: String, workingDirectory: String) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }
}

/// A working-directory root that groups sessions. `displayName` is the folder's
/// last path component.
struct Repo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var displayName: String
    var sessions: [Session]

    init(id: UUID = UUID(), url: URL, sessions: [Session] = []) {
        self.id = id
        self.url = url
        self.displayName = url.lastPathComponent
        self.sessions = sessions
    }
}
