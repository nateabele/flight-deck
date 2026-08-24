import FleetKit
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

    /// Claude's screen is the one this build can actually read: `InputBar.read` finds its
    /// one-row input box, `ChoiceDialog` reads its select lists, and both were derived from
    /// the verbatim captures `Fixtures/Claude/dialogs.captured.provenance.json` records with
    /// their sha256s. Everything `SessionStore` types — a phone's message, `/rename`, an
    /// answer to a dialog — goes into that box or that list.
    static let textChannel: AgentTextChannel? = ClaudeTextChannel()
    static let dialogDriver: AgentDialogDriver? = ClaudeDialogDriver()

    /// Claude mints its own conversation id — Flight Deck has always chosen the tab's own —
    /// so there is nothing to negotiate and nothing that can come back different.
    static let negotiatesIdentity = false

    /// Nothing to bring up. This adapter is a pure function of paths and flags.
    static let needsRuntimeStart = false

    /// `<home>/sessions`, one file per live session, scanned by `SessionStatusWatcher`. It is
    /// where every claude status glyph in the sidebar comes from.
    static let hasStatusRegistry = true

    /// Claude's rename is `/rename <name>` typed at a pty that may be a bare shell, so the
    /// shell strip is load-bearing here in a way it is nowhere else.
    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        ClaudeSession.sanitizedName(raw)
    }

    /// What `claude`'s own `/resume` picker shows: the conversation's name when it has one,
    /// else its first real user message.
    nonisolated static func title(fromTranscriptAt url: URL) -> String? {
        ConversationTitle.resolve(transcriptAt: url)
    }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
        ClaudeTimelineMapper.items(inLine: line, at: offset)
    }

    /// `<home>/.claude.json` → `oauthAccount.emailAddress` / `organizationName`.
    nonisolated static let homeMarkerFile = ".claude.json"

    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
        AccountDirectory.claudeIdentity(from: data)
    }

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
        ClaudeSession.resumeCommand(
            sessionID: binding.conversationID, title: session.title, flags: flags(options)
        )
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
