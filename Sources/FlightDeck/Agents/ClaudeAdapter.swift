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

    /// How a rename reaches `claude`: by typing `/rename <name>` into the tab's pty.
    /// Injected so tests need no terminal. Production wires this to `SessionStore.inject`.
    var injectRename: (UUID, String) async -> Void = { _, _ in }

    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        // Claude takes the id we choose, and Flight Deck has always chosen the tab's own.
        AgentBinding(
            conversationID: session.id,
            transcriptURL: ClaudeSession.transcriptURL(
                sessionID: session.id,
                workingDirectory: session.transcriptDirectory
            )
        )
    }

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.launchCommand(
            sessionID: binding.conversationID, title: session.title, flags: flags(options)
        )
    }

    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        ClaudeSession.resumeCommand(
            sessionID: binding.conversationID, title: session.title, flags: flags(options)
        )
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        await injectRename(binding.conversationID, title)
    }

    /// A codex payload here is a programming error, not a runtime condition: the store picks
    /// the adapter and the options together. Degrade to defaults rather than trap.
    private func flags(_ options: AgentOptions) -> FlagSet {
        if case .claude(let f) = options { return f }
        return FlagSet()
    }
}
