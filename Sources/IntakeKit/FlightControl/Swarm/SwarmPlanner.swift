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
