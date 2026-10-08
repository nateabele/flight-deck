import FleetKit
import Foundation
import IntakeKit

/// Gemini's tab adapter, driving the Antigravity CLI `agy` (unify brief R5) — the same binary
/// its planning runs use (`GeminiProfile`). Every answer below was read off a live agy 1.3.1
/// (`.superpowers/agy-tui-facts.md`, and a second smoke on 2026-10-08).
///
/// **Identity is learned after launch, not negotiated before it.** agy has no flag that names a
/// conversation up front, creates one only on the first submit (or `/clear`), and answers
/// `--conversation=<unknown>` by minting a fresh id rather than failing. Nothing can be asked
/// before the tab's own agy exists, so there is nothing for `prepare` to round-trip: a new tab
/// is pinned to its own id as a placeholder, and `GeminiRuntime` re-pins it (`AgentEvent
/// .rebound`) the moment the tab's agy holds a conversation open. Hence
/// `negotiatesIdentity == false` and `needsRuntimeStart == false`.
///
/// **One account.** agy keeps its login in the macOS keychain (service `gemini`, account
/// `antigravity`) and reads no home variable, so gemini has only its built-in account
/// (`AgentID.homeEnvironmentKey` is nil; `AccountList.addRefusal`).
@MainActor
struct GeminiAdapter: AgentAdapter {
    static let id: AgentID = .gemini

    /// The headless facet (unify brief R3): the profile planning runs this agent through.
    nonisolated static var profile: any AgentProfile { AgentProfiles.profile(for: id) }

    static let textChannel: AgentTextChannel? = GeminiTextChannel()
    static let dialogDriver: AgentDialogDriver? = GeminiDialogDriver()
    static let openPromptReader: AgentOpenPromptReader? = GeminiOpenPromptReader()
    static let searchCorpus: AgentSearchCorpus? = GeminiSearchCorpus()

    /// **nil: agy's `/rename` is single-stage.** `/rename <name>` executes with its inline
    /// argument (a bare `/rename` answers `Error: Please provide a new name`), so the plain
    /// `textChannel.submit("/rename <name>")` is the whole rename — claude's shape, not codex's
    /// modal.
    static let renameTyping: AgentRenameTyping? = nil

    /// **nil, and that is a finding.** agy retries transient API errors itself (up to 8 attempts
    /// with backoff, per its binary's strings) and writes no transience classification anywhere
    /// Flight Deck can read — no field in the transcript, only screen text and a hook payload's
    /// error string. An allowlist keyed on prose nobody has seen fire (no real API failure was
    /// provoked) would type into a terminal on a guess, so nothing retries.
    static let turnRecovery: AgentTurnRecovery? = nil

    static let negotiatesIdentity = false
    static let needsRuntimeStart = false

    /// No per-account registry: agy's status is read per tab by `GeminiRuntime`, from the tab's
    /// own presence lock, so a claude-style registry scan has nothing to confirm or refute.
    static let hasStatusRegistry = false

    /// The model a tab launches with when its options name none: the strongest Gemini
    /// `agy models` offers an AI Pro account, the same default planning uses. **Always passed
    /// explicitly**, because agy's own default is whatever the user last picked in agy — which
    /// may be a Claude or GPT-OSS model it also serves.
    static let defaultModel = GeminiProfile.defaultPlanningModel

    /// The slug a tab launches with. A configured slug that is not a Gemini model, or that
    /// carries anything but `[a-z0-9.-]` (it is typed at a shell), falls back to the default.
    nonisolated static func model(for options: GeminiOptions) -> String {
        guard let slug = options.model, isLaunchableModel(slug) else { return GeminiProfile.defaultPlanningModel }
        return slug
    }

    nonisolated static func isLaunchableModel(_ slug: String) -> Bool {
        GeminiProfile.isGeminiModel(slug)
            && slug.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0) }
    }

    /// Control characters only: the name is typed at agy's own composer behind
    /// `GeminiTextChannel`'s gate, never at a shell. See `AgentAdapter.sanitizedTitle`.
    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        AgentTitle.sanitized(raw, removing: CharacterSet())
    }

    /// The title is not in the transcript: agy writes it to `annotations/<id>.pbtxt`, beside the
    /// `brain/` tree the transcript lives in.
    nonisolated static func title(fromTranscriptAt url: URL) -> String? {
        guard let conversation = GeminiPaths.conversation(ofTranscript: url) else { return nil }
        return GeminiTitle.read(conversation.paths.annotation(conversation.id))
    }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
        GeminiTimelineMapper.items(inLine: line, at: offset)
    }

    /// agy keeps its configuration under `~/.gemini/antigravity-cli`, so that directory marks a
    /// gemini home (`AgentID.gemini.builtInHome` is `~/.gemini`).
    nonisolated static let homeMarkerFile = "antigravity-cli"

    /// **nil, and why.** No file agy keeps offline names the signed-in account: the email
    /// appears only in the TUI header, in `/usage`, and in a network-auth log line — none of it
    /// in a file this marker could point at, and the marker is a directory. A wrong email next to
    /// a real account is worse than none.
    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? { nil }

    var paths: GeminiPaths = .default

    /// Every file existence check goes through here so a test can say what agy has on disk.
    var exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    init(paths: GeminiPaths = .default) { self.paths = paths }

    /// Nothing to negotiate (see the type's comment): the binding is the tab's own pin.
    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        binding(for: session)
    }

    func binding(for session: Session) -> AgentBinding {
        AgentBinding(conversationID: session.pinnedConversationID,
                     transcriptURL: paths.transcript(session.pinnedConversationID))
    }

    /// agy runs in the directory it was launched in, which is where the store spawns the pty.
    func location(for session: Session) -> AgentLocation {
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }

    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        "agy --model \(Self.model(for: geminiOptions(options)))\n"
    }

    /// Resume only a conversation agy actually has. `agy --conversation=<unknown>` does not fail
    /// — it opens a fresh conversation under a new id behind a one-line warning — so the check
    /// is made here, and a pin agy never had (a tab that never submitted, or a conversation
    /// deleted between launches) launches fresh. Either way `GeminiRuntime` re-pins to whatever
    /// agy ends up holding.
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        guard paths.conversationExists(binding.conversationID, exists: exists) else {
            return launchCommand(binding, session, options)
        }
        return "agy --conversation=\(GeminiPaths.name(binding.conversationID)) --model \(Self.model(for: geminiOptions(options)))\n"
    }

    /// Unreachable in production: `SessionStore.rename` types gemini's `/rename` through the
    /// composer (`injectPendingRename`), because agy's rename has no offline route Flight Deck
    /// has verified — editing `annotations/<id>.pbtxt` behind a running agy was never tested.
    func rename(_ binding: AgentBinding, to title: String) async throws {
        throw GeminiRenameIsTyped()
    }

    /// Bare `agy`: its interactive first run signs in (opens a browser). Flight Deck shows this
    /// and never runs it on its own.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "agy", inject: nil)
    }

    private func geminiOptions(_ options: AgentOptions) -> GeminiOptions {
        if case .gemini(let o) = options { return o }
        return GeminiOptions()
    }
}

/// `GeminiAdapter.rename` was reached; gemini's rename is typed at the composer instead.
struct GeminiRenameIsTyped: Error, Equatable {}
