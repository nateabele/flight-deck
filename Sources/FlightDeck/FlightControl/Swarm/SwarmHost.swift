import Foundation

/// What a swarm needs from the session store, and nothing more. `SessionStore` conforms (Task 7h).
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
