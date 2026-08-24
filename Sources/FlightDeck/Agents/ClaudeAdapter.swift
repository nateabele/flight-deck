import Foundation

/// Claude conformance. A thin shell over `ClaudeSession`, which stays the single source of
/// truth for command construction and path derivation.
///
/// `encodedProjectDirName` deliberately does NOT appear on `AgentAdapter`. It exists only
/// because claude has no index and must derive its transcript path from the cwd; codex is
/// handed the path outright. Putting it on the protocol would leak a claude implementation
/// detail into every future agent.
@MainActor
struct ClaudeAdapter: AgentAdapter {
    static let id: AgentID = .claude

    /// Where this account's `projects` directory lives, read on every derivation rather than
    /// captured as a value. It is derived from the home of the account the adapter was built
    /// for, and `SessionStore.transcriptsRootOverride` — a fixture/test seam — is assigned
    /// *after* the store is constructed, so a struct that snapshotted a URL at construction
    /// would keep pointing at the real projects directory for the life of a fixture run.
    var projectsRoot: () -> URL = { ClaudeSession.defaultProjectsRoot }

    /// How a rename reaches `claude`: by typing `/rename <name>` into the tab's pty.
    /// Injected so tests need no terminal. Production wires this to `SessionStore.inject`.
    var injectRename: (UUID, String) async -> Void = { _, _ in }

    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        // Claude takes the id we choose, and Flight Deck has always chosen the tab's own —
        // which is what `pinnedConversationID` is at birth. Nothing to negotiate, so this is
        // the same answer `binding(for:)` gives.
        binding(for: session)
    }

    func binding(for session: Session) -> AgentBinding {
        // The pinned conversation, not the tab id: they diverge the moment an in-session
        // `/resume` repoints the tab, and the transcript is named after the conversation.
        AgentBinding(
            conversationID: session.pinnedConversationID,
            transcriptURL: ClaudeSession.transcriptURL(
                sessionID: session.pinnedConversationID,
                workingDirectory: session.transcriptDirectory,
                projectsRoot: projectsRoot()
            )
        )
    }

    func location(for session: Session) -> AgentLocation {
        // Claude encodes its live cwd into the transcript path and follows the agent into a
        // worktree, so the transcript directory is where it is working.
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.launchCommand(
            sessionID: binding.conversationID, title: session.title, flags: flags(options)
        )
    }

    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.resumeCommand(sessionID: binding.conversationID, flags: flags(options))
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        await injectRename(binding.conversationID, title)
    }

    /// Claude has no shell-level login subcommand — it authenticates inside a running
    /// session — so signing in means launching claude plain and then typing `/login` at it,
    /// unlike codex's one-shot `codex login`.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "claude", inject: "/login")
    }

    /// A codex payload here is a programming error, not a runtime condition: the store picks
    /// the adapter and the options together. Degrade to defaults rather than trap.
    private func flags(_ options: AgentOptions) -> FlagSet {
        if case .claude(let f) = options { return f }
        return FlagSet()
    }
}
