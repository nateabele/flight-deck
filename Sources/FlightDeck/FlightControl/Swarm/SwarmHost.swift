import Foundation

/// What a swarm needs from the session store, and nothing more. `SessionStore` conforms below.
@MainActor
protocol SwarmHost: AnyObject {
    func sessionExists(_ id: UUID) -> Bool
    /// The tab's agent is idle right now. Reuse requires it: a `/clear` typed into a running turn
    /// queues behind work that was supposed to be finished (Review Focus: human-closed task).
    func isAgentIdle(_ id: UUID) -> Bool
    func wakeIfAsleep(_ id: UUID)
    func lastActiveAt(for id: UUID) -> Date?
    /// Every tab in `project` (a standardized path) that booted an Agent Mail identity.
    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)]
}

extension SessionStore: SwarmHost {
    func isAgentIdle(_ id: UUID) -> Bool { status(for: id)?.activity == .idle }

    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)] {
        let key = FlywheelObserveService.key(project)
        return repos.flatMap(\.sessions).compactMap { session in
            guard let identity = session.flywheelIdentity, FlywheelObserveService.key(identity.project) == key else { return nil }
            return (session.id, identity.agentName)
        }
    }
}
