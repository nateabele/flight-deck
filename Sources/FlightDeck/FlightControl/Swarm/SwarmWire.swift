import FleetKit
import Foundation
import IntakeKit

/// Builds the phone's view of one swarm and the events that keep it current. Read only from the
/// store's `swarmSummaries` cache by `FleetProjection`, so the replicator's drift oracle sees
/// exactly what was last recorded.
enum SwarmWireProjection {
    @MainActor
    static func wire(_ record: SwarmRecord, service: SwarmService, now: Date = Date()) -> WireSwarm? {
        guard record.state != .stopped, let summary = service.summary(forProject: record.project) else { return nil }
        let pending = service.handoffDecisions?.pendingHandoffs ?? []
        let agents = record.agents.filter { $0.state != .done }.map { agent in
            WireSwarmAgent(session: agent.session, task: agent.task ?? agent.lastTask,
                           kind: agent.block.block.kind.rawValue, model: agent.block.block.model,
                           accountName: agent.lease?.account.label, state: agent.state.rawValue,
                           marker: service.annotation(for: agent.session, now: now)?.marker,
                           contested: service.isContested(agent.session),
                           handoffPending: pending.contains(agent.session))
        }
        let meters = service.meters(forProject: record.project).map {
            WireSwarmMeter(pool: $0.pool, accountName: $0.label, utilization: $0.value, state: $0.state.rawValue)
        }
        return WireSwarm(state: record.state.rawValue, summary: summary.text, banner: record.banner,
                         agents: agents, meters: meters, waiting: record.waiting.count)
    }

    /// One `projectSwarm` per project whose summary changed, sorted by uuid string for tests —
    /// the same contract `IntakeSummaryProjection.changes` keeps.
    static func changes(from old: [UUID: WireSwarm?], to new: [UUID: WireSwarm?]) -> [FleetEvent] {
        new.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let next = new[id] ?? nil
            return next == (old[id] ?? nil) ? nil : .projectSwarm(project: id, swarm: next)
        }
    }
}
