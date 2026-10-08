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
    /// would otherwise pick grok for a task and the spawn would type a stub command into a
    /// shell. Its stub conformer still exists, so flipping `tabReady` is the whole change that
    /// makes it routable once Track G or M fills the conformer in.
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

/// **STUB (unify brief P0).** grok's routing answers: every capability unsupported, with the
/// reason. Unregistered while `AgentID.grok.tabReady` is false (`RoutingCapabilityRegistry
/// .standard`); Track G fills each in where its probe shows grok can (unify brief R10).
@MainActor
final class GrokRoutingCapabilities: AgentRoutingCapabilities {
    let agent: AgentID = .grok
    let accountModel: AccountModel = .login
    var knobSchema: [String: [String]] { [:] }
    private static let stub = "the grok adapter is a stub"
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .unsupported(reason: Self.stub) }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { .unsupported(reason: Self.stub) }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { .unsupported(reason: Self.stub) }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> { .unsupported(reason: Self.stub) }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> { .unsupported(reason: Self.stub) }
}

/// **STUB (unify brief P0).** Gemini's routing answers; see `GrokRoutingCapabilities`. Its
/// account model is `.login` with exactly one login (the keyring's), per unify brief R5.
@MainActor
final class GeminiRoutingCapabilities: AgentRoutingCapabilities {
    let agent: AgentID = .gemini
    let accountModel: AccountModel = .login
    var knobSchema: [String: [String]] { [:] }
    private static let stub = "the gemini adapter is a stub"
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .unsupported(reason: Self.stub) }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { .unsupported(reason: Self.stub) }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { .unsupported(reason: Self.stub) }
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> { .unsupported(reason: Self.stub) }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> { .unsupported(reason: Self.stub) }
}

/// Owned by L3-S. Spawns (or the caller reuses) an agent for `task` and submits `firstPrompt`
/// once its composer is ready. L3-U's hand-off calls it with the hand-off prompt.
@MainActor
protocol SwarmSpawner: AnyObject {
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError>
}
extension CodexRoutingCapabilities: CommandSinkAttachable {}
