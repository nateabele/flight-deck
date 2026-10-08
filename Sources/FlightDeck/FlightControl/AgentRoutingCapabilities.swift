import Foundation
import IntakeKit

/// An adapter's answer to one Level 3 question: the value, or an explicit "can't". Never a
/// made-up value — a stub that returned an empty-but-supported answer would let routing think an
/// adapter has no models rather than that nobody asked it yet.
enum RoutingCapability<Value> {
    case supported(Value)
    case unsupported(reason: String)
    var value: Value? { if case .supported(let v) = self { v } else { nil } }
}

/// How an adapter's capacity is owned. `.none` is a local provider: no account, so no rollover —
/// its limit is concurrency (L3-U local pools).
enum AccountModel: String, Sendable { case login, providerKeys, none }

/// The model and knobs a spawn asks for, on top of the agent's preferences.
struct LaunchOverrides: Equatable, Sendable {
    var model: String?
    var knobs: [String: String]
}

/// What routing, rollover and the swarm need from an agent. Separate from `AgentAdapter`
/// because adapters are built per account (`SessionStore.makeClaudeAdapter(account:)`), while
/// these answers are per agent; session-specific calls take the `Session`.
@MainActor
protocol AgentRoutingCapabilities: AnyObject {
    var agent: AgentID { get }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]>
    var knobSchema: [String: [String]] { get }
    var accountModel: AccountModel { get }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource>
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer>
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void>
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions>
}

@MainActor
final class RoutingCapabilityRegistry {
    private var entries: [AgentID: any AgentRoutingCapabilities] = [:]
    private(set) var agents: [AgentID] = []

    init(_ list: [any AgentRoutingCapabilities]) {
        for e in list where entries[e.agent] == nil {
            entries[e.agent] = e
            agents.append(e.agent)
        }
    }

    func capabilities(for agent: AgentID) -> (any AgentRoutingCapabilities)? { entries[agent] }

    /// Every registered harness's catalog. A harness outside `enabled`, or one whose catalog is
    /// unsupported, contributes a disabled, empty catalog — present, so validation can say
    /// "codex is disabled" instead of "codex does not exist".
    func catalogs(enabled: Set<AgentID>) async -> AdapterCatalogs {
        var out: [AdapterCatalog] = []
        for h in agents {
            guard let caps = entries[h] else { continue }
            let models = await caps.modelCatalog().value
            out.append(AdapterCatalog(agent: h, models: models ?? [], knobSchema: caps.knobSchema,
                                      defaultModel: models?.first?.id,
                                      enabled: enabled.contains(h) && models != nil))
        }
        return AdapterCatalogs(out)
    }

    /// One conformer per tab-ready `AgentID`. The `switch` is exhaustive on purpose: a new
    /// `AgentID` case fails to compile here until it states its answers.
    ///
    /// Filtered by `tabReady` (unify brief R4): routing sends a task to an agent by opening a
    /// TAB on it, so an agent that cannot run a tab must not be a routing target — the router
    /// would otherwise pick it for a task and the spawn would type a placeholder command into
    /// a shell. Every agent is tab-ready today; the filter is what keeps the next agent off
    /// routing until its adapter can run a tab.
    static func standard() -> RoutingCapabilityRegistry {
        RoutingCapabilityRegistry(AgentID.tabReadyCases.map { id -> any AgentRoutingCapabilities in
            switch id {
            case .claude: ClaudeRoutingCapabilities()
            case .codex: CodexRoutingCapabilities()
            case .grok: GrokRoutingCapabilities()
            case .gemini: GeminiRoutingCapabilities()
            }
        })
    }
}

/// Catalog and knobs are real (L3-R, `RoutingCatalogs.swift`); the usage meter and transcript
/// pointer are real (L3-U); reset and overrides are real (L3-S).
@MainActor
final class ClaudeRoutingCapabilities: AgentRoutingCapabilities {
    let agent: AgentID = .claude
    let accountModel: AccountModel = .login
    /// Attached by `SessionStore` (`attachCommandSink`); weak because the store owns the registry.
    weak var commands: SessionCommandSink?
    var knobSchema: [String: [String]] { ClaudeRoutingCatalog.knobSchema }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .supported(ClaudeRoutingCatalog.models) }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> {
        .supported(UsageService.shared.tap(agent: .claude, account: account))
    }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> {
        guard let pointer = TranscriptPointers.claude(session: session, projectsRoot: UsageService.shared.claudeProjectsRoot(for: session)) else {
            return .unsupported(reason: "no transcript file on disk for this conversation")
        }
        return .supported(pointer)
    }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        try ContextReset.typing(ContextReset.claudeCommand, into: session, via: commands)
    }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        ClaudeLaunchOverrides.apply(overrides, to: options)
    }
}

extension ClaudeRoutingCapabilities: CommandSinkAttachable {}

@MainActor
final class CodexRoutingCapabilities: AgentRoutingCapabilities {
    let agent: AgentID = .codex
    let accountModel: AccountModel = .login
    /// Attached by `SessionStore` (`attachCommandSink`); weak because the store owns the registry.
    weak var commands: SessionCommandSink?
    var knobSchema: [String: [String]] { CodexRoutingCatalog.shared.knobSchema }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { await CodexRoutingCatalog.shared.models() }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> {
        .supported(UsageService.shared.tap(agent: .codex, account: account))
    }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> {
        guard let pointer = TranscriptPointers.codex(session: session) else {
            return .unsupported(reason: "codex has not reported a rollout path for this tab")
        }
        return .supported(pointer)
    }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        try ContextReset.typing(ContextReset.codexCommand, into: session, via: commands)
    }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        CodexLaunchOverrides.apply(overrides, to: options)
    }
}

/// grok's routing answers (unify brief R10). Catalog and knobs come from `GrokProfile`, the one
/// place grok's models and effort levels are stated; the meter is the billing line grok logs
/// (`GrokBillingSource`); overrides become `GrokOptions`.
@MainActor
final class GrokRoutingCapabilities: AgentRoutingCapabilities {
    let agent: AgentID = .grok
    let accountModel: AccountModel = .login
    private var catalog: ProfileModelCatalog { GrokProfile().modelCatalog }
    var knobSchema: [String: [String]] { ["effort": catalog.effortValues] }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> {
        .supported(catalog.aliases.map { ModelEntry(id: $0, displayName: $0, knobs: ["effort"]) })
    }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> {
        .supported(UsageService.shared.tap(agent: .grok, account: account))
    }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> {
        guard let pointer = TranscriptPointers.grok(session: session, home: UsageService.shared.grokHome(for: session)) else {
            return .unsupported(reason: "no grok session file on disk for this conversation")
        }
        return .supported(pointer)
    }
    /// **Unsupported, and it is Flight Deck that cannot, not grok.** grok's reset is `/new`
    /// (alias `/clear`), which starts a NEW session with a new id inside the same process.
    /// Nothing re-pins a grok tab to a session it did not mint — codex has
    /// `CodexPinReconciler` for exactly this; grok has no equivalent yet — so after a reset the
    /// tab would watch a session nobody writes and report its status forever stale.
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        .unsupported(reason: "grok's /new starts a new session id that Flight Deck cannot follow yet")
    }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        GrokLaunchOverrides.apply(overrides, to: options)
    }
}

/// Gemini's (agy's) routing answers. Its account model is `.login` with exactly one login (the
/// keyring's), per unify brief R5.
@MainActor
final class GeminiRoutingCapabilities: AgentRoutingCapabilities {
    let agent: AgentID = .gemini
    let accountModel: AccountModel = .login
    /// Attached by `SessionStore` (`attachCommandSink`); weak because the store owns the registry.
    weak var commands: SessionCommandSink?
    /// No knobs: every agy model id already names its effort (`gemini-3.1-pro-high`), and agy
    /// resolves `--model` and `--effort` as one selection (`GeminiProfile.modelCatalog`).
    var knobSchema: [String: [String]] { [:] }

    /// The account's own list, from `agy models` (read-only, no tokens; also the sign-in check),
    /// Gemini ids only. Listed once per run: the catalog changes with agy releases, not turns.
    /// Unsupported, with the reason, when agy is missing or signed out.
    private var listed: [ModelEntry]?
    var list: @Sendable () async -> [String]? = {
        await Task.detached(priority: .utility) { () -> [String]? in
            let path = LoginShellPath.repairing()["PATH"]
            guard let executable = (path ?? "").split(separator: ":").lazy.map({ "\($0)/agy" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            let profile = GeminiProfile()
            guard let output = SignInProbe.system.run(executable, profile.signInCheck.arguments, path ?? ""),
                  profile.signInCheck.readiness(output) == .ready else { return nil }
            return profile.parseModelList(output.stdout)
        }.value
    }

    func modelCatalog() async -> RoutingCapability<[ModelEntry]> {
        if let listed { return .supported(listed) }
        guard let ids = await list(), !ids.isEmpty else {
            return .unsupported(reason: "agy is not installed or not signed in (`agy models` listed nothing)")
        }
        let entries = ids.map { ModelEntry(id: $0, displayName: $0, knobs: []) }
        listed = entries
        return .supported(entries)
    }

    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> {
        .supported(UsageService.shared.tap(agent: .gemini, account: account))
    }

    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> {
        guard let pointer = TranscriptPointers.gemini(session: session) else {
            return .unsupported(reason: "agy has not written a transcript for this conversation yet")
        }
        return .supported(pointer)
    }

    /// `/clear` starts a new agy conversation in the same process (probed 2026-10-08: a new
    /// presence lock and step store at once); `GeminiRuntime` re-pins the tab to it.
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        try ContextReset.typing(ContextReset.geminiCommand, into: session, via: commands)
    }

    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        GeminiLaunchOverrides.apply(overrides, to: options)
    }
}

extension GeminiRoutingCapabilities: CommandSinkAttachable {}

/// Owned by L3-S. Spawns (or the caller reuses) an agent for `task` and submits `firstPrompt`
/// once its composer is ready. L3-U's hand-off calls it with the hand-off prompt.
@MainActor
protocol SwarmSpawner: AnyObject {
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError>
}
extension CodexRoutingCapabilities: CommandSinkAttachable {}
