import Foundation

/// The pure decisions inside a controller tick, kept apart from the side effects so each rule is
/// one function with one test.
public enum SwarmPlanner {
    /// Ready tasks this swarm may claim, in the order given (scheduler order), minus the ones it
    /// is already holding or launching. The filter is applied HERE, after ranking: the scheduler
    /// ranks the whole project, and an intake swarm must never claim outside its intake.
    public static func candidates(_ ready: [ReadyTask], filter: SwarmFilter, excluding taken: Set<String>) -> [ReadyTask] {
        ready.filter { filter.admits($0.id) && !taken.contains($0.id) }
    }
}

extension SwarmPlanner {
    /// Spec §4 step 4: an idle agent with the same config key whose account is still under soft
    /// (`unknown` counts, as the allocator's own order does). The agent that has waited longest
    /// goes first, so work spreads instead of piling onto the most recently finished tab.
    public static func reuseCandidate(for key: ConfigKey, in agents: [SwarmAgentRecord],
                                      isAvailable: (UUID) -> Bool,
                                      headroom: (SwarmAgentRecord) -> HeadroomState) -> SwarmAgentRecord? {
        agents
            .filter { $0.state == .idle && !$0.excludedFromReuse && $0.config == key && isAvailable($0.session) }
            .filter { [HeadroomState.underSoft, .unknown].contains(headroom($0)) }
            .min { $0.stateSince < $1.stateSince }
    }
}

extension SwarmPlanner {
    /// Spec §4: a swarm stops on its own when nothing is ready, nothing is waiting and no agent is
    /// working. Unroutable tasks are not "ready" here — nothing will ever start them.
    public static func isFinished(claimable: Int, waiting: Int, active: Int, launching: Int) -> Bool {
        claimable == 0 && waiting == 0 && active == 0 && launching == 0
    }
}
