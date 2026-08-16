import Foundation

/// A single terminal session. In this foundation a session is just a titled
/// terminal rooted at a working directory; agent/worktree state comes later.
struct Session: Identifiable, Equatable {
    /// The tab's identity, immutable for its whole life. Keys the surface, the transcript
    /// watcher, the status map, the selection, and every notification. Deliberately NOT
    /// the Claude conversation id — see `pinnedConversationID`.
    let id: UUID
    var title: String
    /// The project the tab is filed under. Changed only by `SessionStore.moveSession` — an
    /// explicit move, or a reported cwd that matches a project *already open* in the sidebar.
    ///
    /// A cwd change on its own deliberately does NOT move the tab any more: `EnterWorktree`
    /// changes `claude`'s cwd to `<project>/.claude/worktrees/<name>`, which is a directory
    /// change *within* a project, and treating it as a resume-into-another-project filed the
    /// tab under a phantom project named after the worktree. Where `claude` is writing is
    /// `transcriptDirectory`'s job, not this field's.
    var workingDirectory: String
    /// Where `claude` is actually writing, and the only input to
    /// `ClaudeSession.transcriptURL`. Equal to `workingDirectory` at birth and follows every
    /// reported cwd change, including one into a worktree — `claude` encodes its live
    /// `process.cwd()` into the project directory name under `~/.claude/projects`, so a tab
    /// that declined to follow would tail a file nothing writes to and lose title sync and
    /// sub-agent counts silently.
    var transcriptDirectory: String
    /// The Claude conversation this tab is currently attached to. Equal to `id` at birth,
    /// because a session Flight Deck starts uses its own tab id as `--session-id`. An
    /// in-session `/resume` repoints it at the resumed conversation.
    var pinnedConversationID: UUID

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        transcriptDirectory: String? = nil,
        pinnedConversationID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.transcriptDirectory = transcriptDirectory ?? workingDirectory
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
    /// Whether the sidebar hides this project's session rows. Stored on the model rather
    /// than as view state so it survives a relaunch — see `SessionSnapshot.Project`.
    var isCollapsed: Bool

    init(id: UUID = UUID(), url: URL, sessions: [Session] = [], isCollapsed: Bool = false) {
        self.id = id
        self.url = url
        self.displayName = url.lastPathComponent
        self.sessions = sessions
        self.isCollapsed = isCollapsed
    }
}
