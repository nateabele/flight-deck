import FleetKit
import Foundation
import OSLog

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

    /// Claude's own transience predicate, carried on the transcript record — see
    /// `ClaudeTurnRecovery`.
    static let turnRecovery: AgentTurnRecovery? = ClaudeTurnRecovery()

    /// **`nil`, and that is an answer, not a gap.** Claude's rename is one line typed through
    /// `textChannel` — `/rename <name>`⏎, submitted in a single shot — so it never has a
    /// second stage for `AgentRenameTyping` to drive; see `CodexAdapter.renameTyping` for the
    /// agent that does. Do not touch claude's rename path to "support" this protocol — it is
    /// the path the 54769a4 regression came from, and it already works unchanged.
    static let renameTyping: AgentRenameTyping? = nil

    /// Claude mints its own conversation id — Flight Deck has always chosen the tab's own —
    /// so there is nothing to negotiate and nothing that can come back different.
    static let negotiatesIdentity = false

    /// Nothing to bring up. This adapter is a pure function of paths and flags.
    static let needsRuntimeStart = false

    /// `<home>/sessions`, one file per live session, scanned by `SessionStatusWatcher`. It is
    /// where every claude status glyph in the sidebar comes from.
    static let hasStatusRegistry = true

    /// Claude's rename is `/rename <name>` typed at a pty, but `SessionStore.inject` now
    /// refuses to type it anywhere but a live, on-screen composer (see `ClaudeTextChannel`),
    /// so the bare-shell case the old shell-metacharacter strip guarded against cannot reach
    /// this path any more. See `ClaudeSession.sanitizedName`.
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

    /// The phone's own derivation, run on the Mac over the same mapper — see
    /// `ClaudeOpenCall`, which exists so there is exactly one implementation of the
    /// call/result pairing rather than two that can disagree about which dialog is up.
    static let openPromptReader: AgentOpenPromptReader? = ClaudeOpenPromptReader()

    static let searchCorpus: AgentSearchCorpus? = ClaudeSearchCorpus()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: String(describing: ClaudeAdapter.self)
    )

    /// Where this account's `projects` directory lives, read on every derivation rather than
    /// captured as a value. It is derived from the home of the account the adapter was built
    /// for, and `SessionStore.transcriptsRootOverride` — a fixture/test seam — is assigned
    /// *after* the store is constructed, so a struct that snapshotted a URL at construction
    /// would keep pointing at the real projects directory for the life of a fixture run.
    var projectsRoot: () -> URL = { ClaudeSession.defaultProjectsRoot }

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

    /// Unreachable in production: `SessionStore.rename` dispatches `.claude` inline to
    /// `injectPendingRename` — never through an adapter, because this method is `async` and
    /// the injection contract needs a synchronous now-or-deferred decision — so only `.codex`
    /// ever calls `adapter.rename`. See `SessionStore.rename`'s doc comment for the full
    /// reasoning.
    ///
    /// A silent no-op here would be exactly the latent hazard this plan exists to remove: the
    /// 2026-08-23 incident was a fan-out nobody noticed had gone stale. So in Debug and CI this
    /// traps: `assertionFailure` plus a thrown error, so a future refactor that starts routing
    /// claude through the adapter surfaces immediately rather than quietly dropping every
    /// rename.
    ///
    /// In Release, `assertionFailure` compiles out and the thrown error is swallowed by
    /// `SessionStore.rename`'s `try? await adapter.rename(...)` on the codex leg — so this
    /// degrades to a logged failure rather than a crash. That degrade is deliberate: trapping
    /// in Release would crash a session manager holding dozens of live terminals over a
    /// cosmetic rename, which is a far worse outcome than a name silently staying stale. The
    /// `Logger` call below is what leaves a breadcrumb for that case.
    func rename(_ binding: AgentBinding, to title: String) async throws {
        assertionFailure("ClaudeAdapter.rename is unreachable — claude renames dispatch inline through SessionStore.rename, never through the adapter")
        Self.logger.fault("ClaudeAdapter.rename reached in Release — claude renames dispatch inline through SessionStore.rename, never through the adapter")
        throw RenameUnreachable()
    }

    /// Local to this file: the only thing that needs to know `ClaudeAdapter.rename` is
    /// unreachable is whatever caller finds a way to reach it.
    private struct RenameUnreachable: Error {}

    /// Claude has no shell-level login subcommand — it authenticates inside a running
    /// session — so signing in means launching claude plain and then typing `/login` at it,
    /// unlike codex's one-shot `codex login`.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "claude", inject: "/login")
    }

    /// Where the bundled plugin's `record.sh` appends, and the only thing that switches the
    /// hook feed on: the script's first line is `[ -n "${FLIGHT_DECK_EVENT_DIR:-}" ] || exit 0`,
    /// so a session launched without this reports nothing at all and stays `.unknown` for the
    /// life of the process.
    ///
    /// On `launchEnvironment` rather than on `environment(for:)` because a tab whose login was
    /// deleted launches with no account — see `AgentAdapter.launchEnvironment`. The default
    /// implementation there folds this into `environment(for:)`, so the Tools-menu path keeps
    /// receiving it too.
    ///
    /// `FLIGHT_DECK_USAGE_DIR` is where the bundled usage mod writes each tab's rate limits;
    /// without it the mod writes nothing.
    ///
    /// Creating the directory here rather than at launch keeps the hook script's single
    /// append from ever hitting a missing directory — it has no `mkdir` of its own, by design:
    /// a hook that fails blocks the agent.
    var launchEnvironment: [String: String] {
        let events = ClaudePluginLocation.eventDirectory
        try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        // The usage mod's directory rides the same account-free path, for the same reason: a tab
        // whose login was deleted still runs on *some* account and still has a meter.
        let usage = ClaudePluginLocation.usageDirectory
        try? FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
        return ["FLIGHT_DECK_EVENT_DIR": events.path, "FLIGHT_DECK_USAGE_DIR": usage.path]
    }

    /// A codex payload here is a programming error, not a runtime condition: the store picks
    /// the adapter and the options together. Degrade to defaults rather than trap.
    private func flags(_ options: AgentOptions) -> FlagSet {
        if case .claude(let f) = options { return f }
        return FlagSet()
    }
}
