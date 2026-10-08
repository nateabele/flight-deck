import FleetKit
import Foundation
import IntakeKit

/// **A STUB (unify brief P0).** grok's tab adapter, present so every exhaustive switch over
/// `AgentID` has a real grok arm and Track G has a type to fill in. It cannot run a tab yet,
/// and nothing lets it: `AgentID.grok.tabReady` is false, which keeps grok out of every new-tab
/// menu, project default-agent picker and routing target. Planning already runs grok headless
/// through `profile`; that part is real.
///
/// Every optional capability is nil — the refusal, stated, rather than a claude-shaped default
/// — and every command is the minimum that names the CLI. Track G replaces each from a probe of
/// the real TUI (unify brief R10), and flips `tabReady` when this passes its tests.
@MainActor
struct GrokAdapter: AgentAdapter {
    static let id: AgentID = .grok

    /// The headless facet (unify brief R3): the same profile the planning runner reaches through
    /// `AgentProfiles.profile(for: .grok)`, so grok's catalog, error vocabulary, environment and
    /// sign-in check have one home.
    nonisolated static var profile: any AgentProfile { AgentProfiles.profile(for: id) }

    static let textChannel: AgentTextChannel? = nil
    static let renameTyping: AgentRenameTyping? = nil
    static let dialogDriver: AgentDialogDriver? = nil
    static let turnRecovery: AgentTurnRecovery? = nil
    static let openPromptReader: AgentOpenPromptReader? = nil
    static let searchCorpus: AgentSearchCorpus? = nil

    /// Stub answers: a locally minted id (grok's `--session-id` takes a UUID we choose, per
    /// `HeadlessCommand.mintGrokSessionID`), nothing to start, no status registry.
    static let negotiatesIdentity = false
    static let needsRuntimeStart = false
    static let hasStatusRegistry = false

    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        AgentTitle.sanitized(raw, removing: CharacterSet())
    }

    nonisolated static func title(fromTranscriptAt url: URL) -> String? { nil }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] { [] }

    /// `$GROK_HOME/auth.json` is grok's login (`GrokProfile.environment`), so its presence marks
    /// a grok home. Identity is not read from it yet: a wrong answer must be no answer.
    nonisolated static let homeMarkerFile = "auth.json"
    nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? { nil }

    func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
        binding(for: session)
    }

    func binding(for session: Session) -> AgentBinding {
        AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
    }

    func location(for session: Session) -> AgentLocation {
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }

    /// STUB: plain `grok`, with none of the session pinning a real launch needs. Unreachable
    /// while `tabReady` is false.
    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String { "grok" }
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String { "grok" }

    func rename(_ binding: AgentBinding, to title: String) async throws { throw AgentStubUnsupported(agent: Self.id) }

    /// `grok login` is grok's sign-in subcommand (`grok login --help`, grok 1.0.30).
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "grok login", inject: nil)
    }
}

/// What a stub adapter throws for an operation its agent cannot perform yet. Distinct from a
/// real failure so a caller's log says "not built" rather than "broken".
struct AgentStubUnsupported: Error, Equatable {
    let agent: AgentID
}
