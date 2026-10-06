import Foundation

/// Encode-time classification and routing (spec L3-R §4). Every task a release creates gets a
/// kind — the one planning named, or its proposal, registered as `origin: planning` and usable at
/// once — and the router's block, as the `agent_context` its `br create` writes.
public enum EncodeRouting {
    /// What an unclassified create routes as (deviation 7). Failing validation instead would
    /// break every intake already in review when L3-R ships.
    public static let fallbackKind: KindID = "implement-simple"

    public struct Outcome: Equatable, Sendable {
        /// Temp id → the whole `agent_context` JSON for `br create --agent-context`.
        public var contexts: [String: String] = [:]
        public var blocks: [String: ExecutionBlock] = [:]
        /// Temp id → why it has no block. Such a task is written without one; the launch-time
        /// re-route (L3-S) tries again, and the swarm skips it until something routes it.
        public var unroutable: [String: String] = [:]
        /// Kinds this release added to the registry.
        public var proposed: [KindID] = []
        public init() {}
    }

    public static func route(_ steps: [ApplyStep], project: URL, registry: any KindRegistry, router: any Router,
                             catalogs: AdapterCatalogs, now: Date) -> Outcome {
        var outcome = Outcome()
        for step in steps {
            guard case .create(let bead) = step else { continue }
            let (kind, classified) = classify(bead, project: project, registry: registry, now: now, proposed: &outcome.proposed)
            let assignment = router.assign(kind: kind, project: project, catalogs: catalogs, now: now)
            // `Assignment.isUnroutable` is the contract's one test for "no route" (deviation 5).
            // The reason keeps its "unroutable: " prefix; an unroutable block must never reach
            // `contexts`, or `br create` would store an agent_context the swarm cannot launch.
            guard !assignment.isUnroutable else {
                outcome.unroutable[bead.tempId] = assignment.block.source.reason
                continue
            }
            var block = assignment.block
            if !classified { block.source.reason = "no kind from planning; " + block.source.reason }
            guard let json = try? ExecutionBlockCodec.encode(block, into: nil) else { continue }
            outcome.blocks[bead.tempId] = block
            outcome.contexts[bead.tempId] = json
        }
        return outcome
    }

    /// The task's kind, and whether planning classified it. A proposal wins over an id; a
    /// proposal whose name normalizes to nothing, an unknown id, or nothing at all is the fallback.
    static func classify(_ bead: NewBead, project: URL, registry: any KindRegistry, now: Date,
                         proposed: inout [KindID]) -> (TaskKind, Bool) {
        let known = (try? registry.kinds(project: project)) ?? SeedKinds.all(createdAt: now)
        if let p = bead.kindProposal {
            let id = KindID.normalized(p.name)
            if !id.rawValue.isEmpty {
                // Unknown dimensions are dropped and weights clamped rather than the proposal
                // refused: the agent's classification is still the best signal this task has.
                let dims = p.dimensions.filter { Dimensions.isKnown($0.key) }.mapValues { min(max($0, 0), 1) }
                let candidate = TaskKind(id: id, name: p.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                         description: p.description, dimensions: dims, origin: .planning,
                                         status: .active, createdAt: now)
                if let added = try? registry.propose(candidate, project: project) {
                    if !known.contains(where: { $0.id == added.id }), !proposed.contains(added.id) { proposed.append(added.id) }
                    return (added, true)
                }
            }
        }
        if let id = bead.taskKind,
           let k = known.first(where: { $0.id == id }) ?? known.first(where: { $0.id == KindID.normalized(id.rawValue) }) {
            return (k, true)
        }
        let fallback = known.first { $0.id == fallbackKind }
            ?? SeedKinds.all(createdAt: now).first { $0.id == fallbackKind }
            ?? TaskKind(id: fallbackKind, name: "Simple implementation", description: "Small, well-specified code changes",
                        dimensions: [:], origin: .seed, createdAt: now)
        return (fallback, false)
    }
}
