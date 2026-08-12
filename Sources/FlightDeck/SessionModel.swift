import Foundation

/// A single terminal session. In this foundation a session is just a titled
/// terminal rooted at a working directory; agent/worktree state comes later.
struct Session: Identifiable, Equatable {
    /// The tab's identity, immutable for its whole life. Keys the surface, the transcript
    /// watcher, the status map, the selection, and every notification. Deliberately NOT
    /// the Claude conversation id — see `pinnedConversationID`.
    let id: UUID
    var title: String
    /// The project the tab is filed under. Mutable because a resume can move a session to
    /// another project (`SessionStore.moveSession`).
    var workingDirectory: String
    /// The Claude conversation this tab is currently attached to. Equal to `id` at birth,
    /// because a session Flight Deck starts uses its own tab id as `--session-id`. An
    /// in-session `/resume` repoints it at the resumed conversation.
    var pinnedConversationID: UUID

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        pinnedConversationID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.pinnedConversationID = pinnedConversationID ?? id
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
