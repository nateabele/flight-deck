import FleetKit
import Foundation
import IntakeKit

/// OpenCode conformance: one `opencode serve` per account, every tab an `opencode attach` to it.
///
/// **The shape, and why it is not codex's.** Codex tabs run their own TUI that owns the thread
/// and the app-server only knows metadata; an OpenCode server owns everything — sessions,
/// turns, the event stream, every pending permission — and a TUI is just a view of it. So
/// almost every capability here is a request to that server rather than keystrokes at a
/// screen: a phone message is `prompt_async`, a rename is `PATCH /session`, an answer is a
/// reply to the request by id. The screen is read only to keep the injection gate's ordering
/// (`OpenCodeTextChannel`).
///
/// **Identity is negotiated and DERIVED.** OpenCode chooses session ids (`ses_…`) and accepts
/// none from a client, so `prepare` asks for one; the store's `UUID` is a name-based UUID of
/// it, and the binding's transcript — the session's mirror file, named `<ses_id>.jsonl` — is
/// how the `ses_` id is recovered. See `OpenCodeIdentity`.
@MainActor
struct OpenCodeAdapter: AgentAdapter {
    static let id: AgentID = .opencode

    /// The headless facet (unify brief R3): the same profile the planning runner reaches through
    /// `AgentProfiles.profile(for: .opencode)`.
    nonisolated static var profile: any AgentProfile { AgentProfiles.profile(for: id) }

    static let textChannel: AgentTextChannel? = OpenCodeTextChannel()

    /// **`nil`, because there is no modal to drive — not because rename is missing.** Codex
    /// needs this to type its two-stage `/rename` into the TUI it cannot otherwise reach. An
    /// OpenCode rename is `PATCH /session/{id}` (`rename` below), and every attached TUI
    /// redraws the new title from the server's own `session.updated` event — live-probed, the
    /// header changed within a second with nothing typed. Typing a rename as well would only
    /// put `/rename` text in front of somebody's draft.
    static let renameTyping: AgentRenameTyping? = nil

    static let dialogDriver: AgentDialogDriver? = OpenCodeDialogDriver()
    static let turnRecovery: AgentTurnRecovery? = OpenCodeTurnRecovery()
    static let openPromptReader: AgentOpenPromptReader? = OpenCodeOpenPromptReader()
    static let searchCorpus: AgentSearchCorpus? = OpenCodeSearchCorpus()
    static let promptResponder: AgentPromptResponder? = OpenCodePromptResponder()

    /// OpenCode mints the id; it can also say the conversation is gone (`GET /session/{id}`
    /// answers 404 `NotFoundError` — probed).
    static let negotiatesIdentity = true

    /// The account's `opencode serve` has to be up before `prepare` can ask it for a session.
    static let needsRuntimeStart = true

    /// Status comes over the server's event stream; there is no per-session file to scan.
    static let hasStatusRegistry = false

    /// A rename travels as JSON to OpenCode's API, never into a shell, so only control
    /// characters are removed — the rule `AgentTitle.sanitized` shares with codex.
    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        AgentTitle.sanitized(raw, removing: CharacterSet())
    }

    /// `nil`, as codex's is: an OpenCode session's name lives on its session row, and reaches a
    /// tab through the runtime (`session.updated`, and a re-read on every reconnect) — never out
    /// of the mirror, which carries messages only.
    nonisolated static func title(fromTranscriptAt url: URL) -> String? { nil }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
        OpenCodeTimelineMapper.items(inLine: line, at: offset)
    }

    /// An account's home is an XDG data root, and OpenCode keeps everything of its own in an
    /// `opencode` directory inside it — so that directory is the marker.
    nonisolated static let homeMarkerFile = "opencode"

    /// OpenCode has no signed-in identity to show: provider credentials are per provider, and
    /// a local model needs none. "No answer" is the safe degrade `AgentAdapter` asks for.
    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? { nil }

    let server: OpenCodeServing
    var mirrorRoot: URL = OpenCodeMirror.defaultRoot
    /// The transport behind every client this adapter builds. A seam for tests, which answer
    /// requests from a script instead of a server.
    var transport: @MainActor (OpenCodeEndpoint) -> OpenCodeHTTP = {
        URLSessionOpenCodeHTTP(baseURL: $0.url, password: $0.password)
    }

    func client() throws -> OpenCodeClient {
        guard let endpoint = server.endpoint else {
            throw OpenCodeError.unreachable("the OpenCode server for this account is not running")
        }
        return OpenCodeClient(http: transport(endpoint))
    }

    func sessionID(of binding: AgentBinding) -> String? {
        OpenCodeIdentity.sessionID(fromTranscript: binding.transcriptURL)
    }

    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let info = try await client().createSession(
            directory: session.transcriptDirectory, title: session.title, options: openCodeOptions(options)
        )
        return try binding(forSession: info.id)
    }

    private func binding(forSession sessionID: String) throws -> AgentBinding {
        guard let database = server.databaseURL else {
            throw AgentLaunchError.agentFailed(
                agent: "OpenCode", why: "the server is running but its session database was not found."
            )
        }
        return AgentBinding(
            conversationID: OpenCodeIdentity.conversationID(forSession: sessionID),
            transcriptURL: OpenCodeMirror.url(forSession: sessionID, database: database, root: mirrorRoot)
        )
    }

    func binding(for session: Session) -> AgentBinding {
        AgentBinding(
            conversationID: session.pinnedConversationID,
            transcriptURL: session.transcriptPath.map { URL(fileURLWithPath: $0) }
        )
    }

    func location(for session: Session) -> AgentLocation {
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }

    /// `opencode attach <server> --dir <cwd> -s <session>`. The password is not on the command
    /// line — where it would land in shell history and `ps` — but in the shell's environment,
    /// which `attach` reads (`OPENCODE_SERVER_PASSWORD`; see `launchEnvironment`).
    ///
    /// With no server endpoint known — reachable only if the server failed to start, which
    /// the store reports separately — the tab still gets a working OpenCode on that session,
    /// self-hosted; it simply reports nothing to Flight Deck until it is reopened.
    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        let dir = ClaudeSession.shellQuoted(session.transcriptDirectory)
        guard let sessionID = sessionID(of: binding) else { return "opencode \(dir)\n" }
        guard let endpoint = server.endpoint else { return "opencode \(dir) -s \(sessionID)\n" }
        return "opencode attach \(endpoint.url.absoluteString) --dir \(dir) -s \(sessionID)\n"
    }

    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String {
        launchCommand(binding, session, options)
    }

    /// The pinned session if the server still has it; a fresh one if it was deleted.
    func rebind(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        let existing = binding(for: session)
        guard let sessionID = sessionID(of: existing) else {
            return try await prepare(for: session, options: options)
        }
        if try await client().session(sessionID, directory: session.transcriptDirectory) == nil {
            return try await prepare(for: session, options: options)
        }
        return existing
    }

    /// The session's current title, for a restore that may have missed a rename made while
    /// Flight Deck was closed. Nil when it is a placeholder or cannot be read.
    func title(of binding: AgentBinding, directory: String) async -> String? {
        guard let sessionID = sessionID(of: binding),
              let info = try? await client().session(sessionID, directory: directory),
              !OpenCodeSearchCorpus.isPlaceholderTitle(info.title)
        else { return nil }
        return info.title
    }

    func rename(_ binding: AgentBinding, to title: String) async throws {
        guard let sessionID = sessionID(of: binding) else {
            throw OpenCodeError.malformed("the tab's binding names no OpenCode session")
        }
        // The session's own directory, read from the database: `rename` is handed only a
        // binding, and the server routes a request without the right `?directory=` to another
        // instance (see `OpenCodeClient`).
        let directory = server.databaseURL
            .flatMap { try? OpenCodeDatabase(url: $0).session(sessionID) }?.directory
        guard let directory else { throw OpenCodeError.malformed("no directory for \(sessionID)") }
        try await client().rename(sessionID, to: title, directory: directory)
    }

    /// The password the shell's `opencode attach` authenticates with. Stable per account —
    /// see `OpenCodeServer` — so a shell that outlives a server restart still gets in.
    var launchEnvironment: [String: String] {
        ["OPENCODE_SERVER_PASSWORD": server.password]
    }

    /// OpenCode signs into providers, not into an account: `opencode auth login` walks the
    /// provider list. A local model needs none of it.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "opencode auth login", inject: nil)
    }

    private func openCodeOptions(_ options: AgentOptions) -> OpenCodeOptions {
        if case .opencode(let o) = options { return o }
        return OpenCodeOptions()
    }
}
