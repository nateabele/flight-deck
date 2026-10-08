import FleetKit
import Foundation
import IntakeKit

/// **A STUB (unify brief P0).** Gemini's tab adapter. Gemini is driven through the Antigravity
/// CLI, `agy` (unify brief R5), exactly as its planning runs are (`GeminiProfile`). Present so
/// every exhaustive switch over `AgentID` has a real gemini arm and Track M has a type to fill
/// in; `AgentID.gemini.tabReady` is false, which keeps gemini out of every new-tab menu, project
/// default-agent picker and routing target until Track M flips it.
///
/// Every optional capability is nil and every command is the minimum that names the CLI. agy
/// signs in through the OS keyring and has no home variable, so gemini has only its built-in
/// account (`AgentID.homeEnvironmentKey` is nil for it; `AccountList.addAccountRefusal`).
@MainActor
struct GeminiAdapter: AgentAdapter {
    static let id: AgentID = .gemini

    /// The headless facet (unify brief R3); see `GrokAdapter.profile`.
    nonisolated static var profile: any AgentProfile { AgentProfiles.profile(for: id) }

    static let textChannel: AgentTextChannel? = nil
    static let renameTyping: AgentRenameTyping? = nil
    static let dialogDriver: AgentDialogDriver? = nil
    static let turnRecovery: AgentTurnRecovery? = nil
    static let openPromptReader: AgentOpenPromptReader? = nil
    static let searchCorpus: AgentSearchCorpus? = nil

    /// Stub answers. agy has no flag to pre-assign a conversation id (`--conversation` only
    /// resumes one it reported), so Track M will likely have to negotiate identity; until then
    /// the tab's own id stands in, which is harmless while no tab can be opened.
    static let negotiatesIdentity = false
    static let needsRuntimeStart = false
    static let hasStatusRegistry = false

    nonisolated static func sanitizedTitle(_ raw: String) -> String? {
        AgentTitle.sanitized(raw, removing: CharacterSet())
    }

    nonisolated static func title(fromTranscriptAt url: URL) -> String? { nil }

    nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] { [] }

    /// agy keeps its configuration under `~/.gemini/antigravity-cli`, so that directory marks a
    /// gemini home (`AgentID.gemini.builtInHome` is `~/.gemini`). Identity is not read: the login
    /// is in the keyring, not in a file a menu could read.
    nonisolated static let homeMarkerFile = "antigravity-cli"
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

    /// STUB: plain `agy`. Unreachable while `tabReady` is false.
    func launchCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String { "agy" }
    func resumeCommand(_ binding: AgentBinding, _ session: Session, _ options: AgentOptions) -> String { "agy" }

    func rename(_ binding: AgentBinding, to title: String) async throws { throw AgentStubUnsupported(agent: Self.id) }

    /// agy has no login subcommand: its interactive first run signs in (`GeminiProfile.signInHint`).
    func loginInvocation(for account: AgentAccount) -> LoginInvocation {
        LoginInvocation(command: "agy", inject: nil)
    }
}
