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
    var harness: HarnessID { get }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]>
    var knobSchema: [String: [String]] { get }
    var accountModel: AccountModel { get }
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource>
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer>
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void>
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions>
}

extension AgentID {
    var harnessID: HarnessID { HarnessID(rawValue) }
}

@MainActor
final class RoutingCapabilityRegistry {
    private var entries: [HarnessID: any AgentRoutingCapabilities] = [:]
    private(set) var harnesses: [HarnessID] = []

    init(_ list: [any AgentRoutingCapabilities]) {
        for e in list where entries[e.harness] == nil {
            entries[e.harness] = e
            harnesses.append(e.harness)
        }
    }

    func capabilities(for harness: HarnessID) -> (any AgentRoutingCapabilities)? { entries[harness] }

    /// Every registered harness's catalog. A harness outside `enabled`, or one whose catalog is
    /// unsupported, contributes a disabled, empty catalog — present, so validation can say
    /// "codex is disabled" instead of "codex does not exist".
    func catalogs(enabled: Set<HarnessID>) async -> AdapterCatalogs {
        var out: [AdapterCatalog] = []
        for h in harnesses {
            guard let caps = entries[h] else { continue }
            let models = await caps.modelCatalog().value
            out.append(AdapterCatalog(harness: h, models: models ?? [], knobSchema: caps.knobSchema,
                                      defaultModel: models?.first?.id,
                                      enabled: enabled.contains(h) && models != nil))
        }
        return AdapterCatalogs(out)
    }

    /// One conformer per `AgentID`. The `switch` is exhaustive on purpose: a new `AgentID` case
    /// (the OpenCode branch adds `.opencode`) fails to compile here until it states its answers.
    static func standard() -> RoutingCapabilityRegistry {
        RoutingCapabilityRegistry(AgentID.allCases.map { id -> any AgentRoutingCapabilities in
            switch id {
            case .claude: ClaudeRoutingCapabilities()
            case .codex: CodexRoutingCapabilities()
            }
        })
    }
}

/// Catalog and knobs are real (L3-R, `RoutingCatalogs.swift`); the usage meter and transcript
/// pointer are real (L3-U); reset and overrides stay stubs until L3-S fills them in.
@MainActor
final class ClaudeRoutingCapabilities: AgentRoutingCapabilities {
    let harness: HarnessID = AgentID.claude.harnessID
    let accountModel: AccountModel = .login
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
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> { .unsupported(reason: "filled in by L3-S") }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> { .unsupported(reason: "filled in by L3-S") }
}

@MainActor
final class CodexRoutingCapabilities: AgentRoutingCapabilities {
    let harness: HarnessID = AgentID.codex.harnessID
    let accountModel: AccountModel = .login
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
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> { .unsupported(reason: "filled in by L3-S") }
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> { .unsupported(reason: "filled in by L3-S") }
}

/// Owned by L3-S. Spawns (or the caller reuses) an agent for `task` and submits `firstPrompt`
/// once its composer is ready. L3-U's hand-off calls it with the hand-off prompt.
@MainActor
protocol SwarmSpawner: AnyObject {
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError>
}
