import Foundation
import IntakeKit

enum SwarmTiming {
    /// Spec §10: no composer within two minutes is "stuck at start".
    static let composerTimeout: TimeInterval = 120
    static let deliveryPoll: Duration = .seconds(1)
    /// Spec §10: three spawn failures in a row on one config pause the swarm.
    static let spawnFailureLimit = 3
}

/// The three steps of starting work on an agent, split so the controller can claim between the
/// spawn (which boots the Agent Mail identity the claim names) and the prompt — spec §4's order.
@MainActor
protocol SwarmAgentLauncher: AnyObject {
    func createAgent(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async -> Result<SessionRef, SpawnError>
    /// Types `prompt` once the tab has a composer. `.composerTimeout` after `SwarmTiming.composerTimeout`.
    func deliver(_ prompt: String, to session: UUID) async -> Result<Void, SpawnError>
    func resetContext(_ session: UUID) async -> Bool
}

/// Waits for a composer by asking the same gate a phone prompt goes through: `submitPrompt`
/// answers `notRunning` until the tab has a live status and a surface, then `sent` or `queued`;
/// a queued prompt is typed when the inject gate sees a real composer box. Polling, because
/// nothing announces "composer ready" — the gate IS the definition.
@MainActor
struct PromptDelivery {
    let submit: (String, UUID, UUID) -> SessionStore.PromptDispatch
    let pending: (UUID, UUID) -> Bool
    let withdraw: (UUID, UUID) -> Void
    let sleep: (Duration) async -> Void
    let now: () -> Date
    let timeout: TimeInterval
    /// Whether the tab still exists. The queue letting go of a prompt is not proof it was typed:
    /// closing a tab drops its whole queue, and that must not read as a delivery (the claim would
    /// be held for an agent that never got its prompt).
    var exists: (UUID) -> Bool = { _ in true }

    func deliver(_ text: String, to session: UUID) async -> Result<Void, SpawnError> {
        let token = UUID()
        let deadline = now().addingTimeInterval(timeout)
        var queued = false
        while !queued {
            switch submit(text, token, session) {
            case .sent: return .success(())
            case .queued, .duplicate: queued = true
            case .notRunning:
                if now() >= deadline { return .failure(.composerTimeout) }
                await sleep(SwarmTiming.deliveryPoll)
            case .unknownSession: return .failure(.launchFailed("the tab is gone"))
            case .unsupportedAgent: return .failure(.launchFailed("this agent has no text channel"))
            case .rejected(let reason): return .failure(.launchFailed("the prompt was refused: \(reason.rawValue)"))
            }
        }
        while pending(token, session) {
            guard exists(session) else { return .failure(.launchFailed("the tab is gone")) }
            if now() >= deadline {
                withdraw(token, session)
                return .failure(.composerTimeout)
            }
            await sleep(SwarmTiming.deliveryPoll)
        }
        return exists(session) ? .success(()) : .failure(.launchFailed("the tab is gone"))
    }
}

/// L3-S's `SwarmSpawner`: creates a tab through `createSession(agent:in:account:overrides:)`,
/// which boots the Agent Mail identity for a Flight Control project, and types the first prompt
/// once the tab can take it. Built from closures so the contract is testable without a GUI;
/// `live(store:)` binds them to the store.
@MainActor
final class StoreSwarmSpawner: SwarmSpawner, SwarmAgentLauncher {
    typealias Create = (AgentID, String, UUID?, LaunchOverrides) async -> Result<UUID, AgentLaunchError>

    private let create: Create
    private let exists: (UUID) -> Bool
    private let discard: (UUID) -> Void
    private let identity: (UUID) -> FlywheelIdentity?
    /// Named apart from the `session` locals below, which would otherwise shadow it.
    private let lookupSession: (UUID) -> Session?
    private let registry: RoutingCapabilityRegistry
    private let delivery: PromptDelivery
    /// Used by the contract's `spawn` only (L3-U's hand-off path); the controller claims itself.
    /// Wired by `SessionStore.useSwarmService` to the service's backend. Nil makes `spawn` refuse.
    var claim: ((TaskRef, String) async -> ClaimOutcome)?

    init(create: @escaping Create, exists: @escaping (UUID) -> Bool, discard: @escaping (UUID) -> Void,
         identity: @escaping (UUID) -> FlywheelIdentity?,
         session: @escaping (UUID) -> Session?, registry: RoutingCapabilityRegistry, delivery: PromptDelivery) {
        self.create = create; self.exists = exists; self.discard = discard; self.identity = identity; self.lookupSession = session
        self.registry = registry; self.delivery = delivery
    }

    static func live(store: SessionStore) -> StoreSwarmSpawner {
        StoreSwarmSpawner(
            create: { [weak store] agent, dir, account, overrides in
                guard let store else { return .failure(.prepareFailed("the app is shutting down")) }
                // `selecting: false`: a swarm spawn must never move the desk's selection.
                return await store.createSession(agent: agent, in: dir, account: account, selecting: false, overrides: overrides)
            },
            exists: { [weak store] in store?.sessionExists($0) ?? false },
            // A tab the hand-off spawn opened and then could not use. Not offered to ⌘⇧T: it
            // never got a prompt, so there is nothing in it to reopen.
            discard: { [weak store] in store?.closeSession($0, recordingHistory: false) },
            identity: { [weak store] id in store?.repos.flatMap(\.sessions).first { $0.id == id }?.flywheelIdentity },
            session: { [weak store] id in store?.repos.flatMap(\.sessions).first { $0.id == id } },
            registry: store.routingCapabilities,
            delivery: PromptDelivery(
                submit: { [weak store] text, token, id in store?.submitPrompt(text, token: token, to: id) ?? .unknownSession },
                pending: { [weak store] token, id in store?.isPromptQueued(token, for: id) ?? false },
                withdraw: { [weak store] token, id in store?.withdrawQueuedPrompt(token, from: id) },
                sleep: { try? await Task.sleep(for: $0) },
                now: Date.init, timeout: SwarmTiming.composerTimeout,
                exists: { [weak store] in store?.sessionExists($0) ?? false }))
    }

    func createAgent(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async -> Result<SessionRef, SpawnError> {
        await createReportingTab(task: task, block: block, lease: lease).result
    }

    /// `createAgent`, plus the tab it opened whether or not that tab is usable — the contract
    /// spawn must close a tab it opened and cannot use (no Agent Mail identity).
    private func createReportingTab(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async
        -> (result: Result<SessionRef, SpawnError>, tab: UUID?) {
        guard let agent = AgentID(rawValue: block.harness.rawValue) else { return (.failure(.unsupportedHarness(block.harness)), nil) }
        let overrides = LaunchOverrides(model: block.model, knobs: block.knobs)
        switch await create(agent, task.project.path, lease?.account.id, overrides) {
        case .failure(let error):
            return (.failure(.launchFailed(error.errorDescription ?? String(describing: error))), nil)
        case .success(let id):
            // `newSession` returns an unfiled draft when it refuses, and `createSession` passes
            // that draft's id back as a success; the tab has to actually exist.
            guard exists(id) else { return (.failure(.launchFailed("the tab was refused")), nil) }
            guard let name = identity(id)?.agentName else {
                return (.failure(.launchFailed("no Agent Mail identity — is Flight Control on for this project?")), id)
            }
            return (.success(SessionRef(id: id, agentName: name)), id)
        }
    }

    func deliver(_ prompt: String, to session: UUID) async -> Result<Void, SpawnError> {
        await delivery.deliver(prompt, to: session)
    }

    func resetContext(_ id: UUID) async -> Bool {
        guard let session = lookupSession(id), let capabilities = registry.capabilities(for: session.agent.harnessID),
              let result = try? await capabilities.resetContext(session), case .supported = result else { return false }
        return true
    }

    /// The contract's one-call spawn (L3-0): create → claim → prompt. A hand-off driver returns
    /// the old agent's claim to open first, so this claim does not race the agent it replaces.
    ///
    /// Without a claim it refuses before opening a tab: a spawn that only prompts leaves the
    /// task open after the hand-off returned it, and the swarm then claims it for a second agent.
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
        guard let claim else { return .failure(.launchFailed("no claim configured")) }
        return await ContractSpawn.run(
            create: { await self.createReportingTab(task: task, block: block, lease: lease) },
            claim: { await claim(task, $0.agentName ?? "") },
            deliver: { await self.deliver(firstPrompt, to: $0) },
            discard: discard, task: task)
    }
}

/// The contract spawn's sequence, shared by `StoreSwarmSpawner` and the integration rig so the
/// rig runs production's failure handling, not a copy of it.
///
/// Create → claim → prompt, and any failure after the tab exists closes that tab. The hand-off
/// driver retries a failed spawn at the next boundary; a tab left behind by each try is one
/// more agent nobody prompts, holding nothing the swarm knows about. The claim such a spawn may
/// have landed is NOT returned here: the caller (`HandoffClaimSpawner`) returns it to open
/// before claiming the task back for the old agent.
@MainActor
enum ContractSpawn {
    static func run(create: () async -> (result: Result<SessionRef, SpawnError>, tab: UUID?),
                    claim: (SessionRef) async -> ClaimOutcome,
                    deliver: (UUID) async -> Result<Void, SpawnError>,
                    discard: (UUID) -> Void, task: TaskRef) async -> Result<SessionRef, SpawnError> {
        let created = await create()
        guard case .success(let ref) = created.result else {
            if let tab = created.tab { discard(tab) }
            return created.result
        }
        switch await claim(ref) {
        case .claimed: break
        case .conflict, .failed:
            discard(ref.id)
            return .failure(.claimConflict(task.id))
        }
        switch await deliver(ref.id) {
        case .success: return .success(ref)
        case .failure(let error):
            discard(ref.id)
            return .failure(error)
        }
    }
}
