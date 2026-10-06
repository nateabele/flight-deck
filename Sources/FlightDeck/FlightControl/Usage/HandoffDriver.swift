import Foundation
import IntakeKit

/// Spec L3-U §5 as a state machine, one agent at a time: wait for a turn boundary (or the
/// deadline), optionally confirm, lease the next account or spill, spawn the new agent with the
/// hand-off prompt, then reassign, release, stop and mark the old one.
///
/// Ordering is the safety property. Nothing about the old agent changes until the new one exists:
/// a spawn that fails leaves the old agent running, still assigned, on its account — the task is
/// never orphaned between two agents.
@MainActor
final class HandoffDriver {
    enum Phase: Equatable {
        case waitingForBoundary(since: Date)
        case waitingForCapacity(String)
        case declined
        case failed
        /// The new agent exists but the old one could not be told to exit. Terminal for this crossing.
        case stopFailed
        case done(SessionRef)
    }

    private(set) var phases: [UUID: Phase] = [:]
    private var confirmed: Set<UUID> = []
    private var workedSinceFailure: Set<UUID> = []
    private var inFlight: Set<UUID> = []

    private let planner: HandoffPlanner
    private let allocator: PoolAllocator
    private let router: Router?
    private let spawner: SwarmSpawner
    private let host: HandoffHost
    private let settings: () -> HandoffSettings
    private let now: () -> Date

    init(planner: HandoffPlanner, allocator: PoolAllocator, router: Router?, spawner: SwarmSpawner, host: HandoffHost,
         settings: @escaping () -> HandoffSettings, now: @escaping () -> Date = Date.init) {
        self.planner = planner; self.allocator = allocator; self.router = router; self.spawner = spawner
        self.host = host; self.settings = settings; self.now = now
    }

    func evaluate(_ agents: [SwarmAgentSnapshot]) async {
        // An agent that leaves the snapshot ends its crossing. Keeping its state would let it come
        // back on a NEW crossing with an old `since` (deadline already past, so a busy agent is
        // interrupted at once), an old decline (never asked again) or an old confirmation
        // (asked never) — and the maps would grow for the life of the app. A finished (`.done`)
        // hand-off is pruned too: its old agent is stopped and gone, and nothing reads it after.
        let present = Set(agents.map(\.session.id))
        for id in Array(phases.keys) where !present.contains(id) && !inFlight.contains(id) { phases[id] = nil }
        confirmed.formIntersection(present.union(inFlight))
        workedSinceFailure.formIntersection(present.union(inFlight))
        for agent in agents { await evaluate(agent) }
    }

    private func evaluate(_ agent: SwarmAgentSnapshot) async {
        let id = agent.session.id
        guard !inFlight.contains(id) else { return }
        if case .done? = phases[id] { return }
        let activity = host.activity(of: agent.session)
        guard let request = planner.request(for: agent) else {
            // Below hard again: this crossing is over. A decline, a failure or a wait from it must
            // not carry into the next one (§5.2: "does not ask again *for this crossing*").
            phases[id] = nil; confirmed.remove(id); workedSinceFailure.remove(id)
            return
        }
        switch phases[id] {
        case .done?, .declined?, .stopFailed?:
            return
        case .failed?:
            // "Retried at the next boundary" (§7): the agent must work again and stop again, or a
            // spawn that keeps failing would be retried on every tick.
            // A rate-limit refusal is a boundary even while the agent still reads busy: it has
            // necessarily worked on the exhausted account, and "busy" would otherwise defer it forever.
            if host.isRateLimited(agent.session) { workedSinceFailure.insert(id) }
            else if activity == .busy { workedSinceFailure.insert(id); return }
            guard workedSinceFailure.contains(id), isBoundary(activity, agent) else { return }
            workedSinceFailure.remove(id)
            await handOff(agent, request)
        case .waitingForCapacity?:
            // The agent keeps working where it is (§5.3); try again whenever it is between turns.
            guard isBoundary(activity, agent) else { return }
            await handOff(agent, request)
        case .waitingForBoundary(let since)?:
            await waitOrGo(agent, request, activity: activity, since: since)
        case nil:
            let since = now()
            phases[id] = .waitingForBoundary(since: since)
            await waitOrGo(agent, request, activity: activity, since: since)
        }
    }

    /// Idle, no agent at all, or refused by the API (it is stuck anyway, §5.1).
    private func isBoundary(_ activity: SessionActivity?, _ agent: SwarmAgentSnapshot) -> Bool {
        activity == nil || activity == .idle || host.isRateLimited(agent.session)
    }

    private func waitOrGo(_ agent: SwarmAgentSnapshot, _ request: HandoffRequest, activity: SessionActivity?, since: Date) async {
        if !isBoundary(activity, agent) {
            guard now().timeIntervalSince(since) >= settings().deadline else { return }
            if activity == .busy {
                // Logged only when the host really sent Escape: the store refuses an idle agent
                // with a busy background subagent, and a log line for an interrupt that never
                // happened misleads whoever reads it.
                if host.interrupt(agent.session) {
                    record(.interrupted, agent, request, detail: "deadline reached mid-turn")
                }
            }
            // `.waiting`: a dialog is open, so the agent is not generating. Escape would answer it
            // as a denial and start a new turn on the exhausted account — hand off as it stands;
            // retiring the old agent deals with the dialog.
        }
        await handOff(agent, request)
    }

    private func handOff(_ agent: SwarmAgentSnapshot, _ original: HandoffRequest) async {
        let id = agent.session.id
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        if settings().confirm && !confirmed.contains(id) {
            guard await host.confirm(original) else {
                phases[id] = .declined
                record(.declined, agent, original, detail: nil)
                return
            }
            confirmed.insert(id)
        }
        guard let resolved = await capacity(for: agent, original) else { return }
        let (block, lease) = resolved

        var request = original
        if let files = await host.reservedFiles(of: agent.agentName, project: request.task.project) { request.reservedFiles = files }
        let result = await spawner.spawn(task: request.task, block: block, lease: lease, firstPrompt: HandoffPrompt.render(request))

        switch result {
        case .failure(let error):
            allocator.release(lease)
            phases[id] = .failed
            workedSinceFailure.remove(id)
            record(.spawnFailed, agent, request, to: lease.account, detail: "\(error)")
            host.notify(title: "Hand-off failed",
                        body: "\(agent.agentName) keeps task \(request.task.id) on \(request.fromAccount.label). Flight Control tries again at its next turn boundary.",
                        session: agent.session)
        case .success(let fresh):
            var warnings: [String] = []
            if let name = fresh.agentName {
                if let w = await host.reassign(task: request.task, to: name) { warnings.append(w) }
            } else {
                warnings.append("the new agent has no name yet, so the task's assignee was not changed")
            }
            if let w = await host.releaseReservations(of: agent.agentName, project: request.task.project) { warnings.append(w) }
            guard await host.stopAgent(agent.session) else {
                // The new agent stays: it already holds the task (reassigned, reservations moved),
                // and killing it would orphan the task. The old lease is kept because the old agent
                // still runs on that account. A terminal phase, not `.failed`: `.failed` retries the
                // whole hand-off and would spawn a second replacement.
                phases[id] = .stopFailed
                record(.stopFailed, agent, request, to: lease.account, fresh: fresh,
                       detail: "exit command was not delivered to the old tab; \(agent.agentName) is still running")
                host.notify(title: "Hand-off needs a manual stop",
                            body: "\(fresh.agentName ?? "A new agent") took task \(request.task.id), but \(agent.agentName)'s tab is still running on \(request.fromAccount.label). Stop it by hand.",
                            session: agent.session)
                return
            }
            host.markHandedOff(agent.session, to: fresh)
            if let old = agent.lease { allocator.release(old) }
            phases[id] = .done(fresh)
            record(.handedOff, agent, request, to: lease.account, fresh: fresh,
                   detail: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
        }
    }

    /// §5.3: the next account in the same pool; else L3-R's spill; a pinned block waits.
    private func capacity(for agent: SwarmAgentSnapshot, _ request: HandoffRequest) async -> (ExecutionBlock, AccountLease)? {
        let pool = agent.block.pool
        if let lease = allocator.lease(pool: pool) { return (agent.block, lease) }
        if agent.block.pinned {
            return wait(agent, request, "pinned to pool \(pool), and every account in it is past its limit")
        }
        guard let router, let kind = host.kind(for: agent.block, project: request.task.project) else {
            return wait(agent, request, "no account in pool \(pool) has headroom")
        }
        let catalogs = await host.catalogs()
        guard let spilled = router.spill(agent.block, kind: kind, project: request.task.project, exhausted: [pool],
                                         catalogs: catalogs, now: now()) else {
            return wait(agent, request, "no account in pool \(pool) has headroom, and no other model fits")
        }
        // An unroutable spill is "nothing fits" in block clothing: its pool and harness are empty,
        // so leasing or spawning from it would launch nothing and strand the task. Ask the
        // contract (`isUnroutable`), never infer it from an empty field here.
        if spilled.isUnroutable {
            return wait(agent, request, "no account in pool \(pool) has headroom, and no other model fits: \(spilled.unroutableReason ?? "unroutable")")
        }
        guard let lease = allocator.lease(pool: spilled.block.pool) else {
            return wait(agent, request, "spilled to pool \(spilled.block.pool), which has no account free either")
        }
        return (spilled.block, lease)
    }

    private func wait(_ agent: SwarmAgentSnapshot, _ request: HandoffRequest, _ reason: String) -> (ExecutionBlock, AccountLease)? {
        if phases[agent.session.id] != .waitingForCapacity(reason) {
            phases[agent.session.id] = .waitingForCapacity(reason)
            record(.waitingForCapacity, agent, request, detail: reason)
        }
        return nil
    }

    private func record(_ outcome: HandoffLogEntry.Outcome, _ agent: SwarmAgentSnapshot, _ request: HandoffRequest,
                        to: AccountRef? = nil, fresh: SessionRef? = nil, detail: String?) {
        host.record(HandoffLogEntry(at: now(), outcome: outcome, task: request.task.id, oldSession: agent.session.id,
                                    oldAgent: agent.agentName, newSession: fresh?.id, newAgent: fresh?.agentName,
                                    fromAccount: request.fromAccount.label, toAccount: to?.label, detail: detail))
    }
}
