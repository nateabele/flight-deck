import Foundation

/// Fleet-wide, human-needed-only notification gate for Observe. `evaluate` is called on
/// every poll tick across every open project's projection and fires through the
/// `Notifying` seam on exactly two conditions a human actually needs to act on: a
/// persistent block, or a collision where the holder can't clear itself. Everything else
/// (a transient block, an actively-worked collision) is deliberately silent — see
/// `docs/superpowers/specs/2026-09-24-flywheel-observe` for the "don't cry wolf" rationale.
@MainActor
final class FlywheelNotifier {
    /// One notification per distinct reason we'd wake a human, so the same agent can be
    /// both "blocked" and "the stalled holder of a contended file" without one clearing
    /// the other's fired/withdraw bookkeeping.
    private enum Cause: Hashable {
        case block
        case collision(file: String)
        case depCycle
    }

    private let notifier: Notifying
    private let blockThreshold: TimeInterval
    private let now: () -> Date

    /// Route resolution: map a (project, agentName) to the FD session UUID to notify/route to.
    /// Defaulted so tests (and the wiring task) can assign it after `init`.
    var route: (_ project: String, _ agentName: String) -> UUID? = { _, _ in nil }

    /// First-seen timestamp per stable cause key, recorded the first `evaluate()` at which
    /// the condition is observed. Deliberately notifier-owned rather than read off
    /// `FlywheelProjection.stalledSince`: a refreshed reservation lease resets that
    /// projection field (continuity is handled there for the *stall* clock, not for "when
    /// did we first see this needs a human"), and threshold timing here must survive that
    /// churn on its own clock.
    private var firstSeen: [String: Date] = [:]

    /// Which stable cause keys have already fired, plus the routed UUID we fired to — kept
    /// so a later `withdraw` targets the same session even though `route` may mint a fresh
    /// UUID on every call (the wiring's `route` closures do exactly that).
    private var fired: [String: UUID] = [:]

    private var didRequestAuthorization = false

    init(notifier: Notifying, blockThreshold: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.notifier = notifier
        self.blockThreshold = blockThreshold
        self.now = now
    }

    func evaluate(projectsByKey: [String: FlywheelProjection]) {
        var observedKeys: Set<String> = []

        for (projectKey, projection) in projectsByKey {
            evaluateBlocks(projectKey: projectKey, projection: projection, observedKeys: &observedKeys)
            evaluateCollisions(projectKey: projectKey, projection: projection, observedKeys: &observedKeys)
            evaluateDependencyCycle(projectKey: projectKey, projection: projection, observedKeys: &observedKeys)
        }

        clearStaleConditions(observedKeys: observedKeys)
    }

    // MARK: - Persistent block

    private func evaluateBlocks(projectKey: String, projection: FlywheelProjection, observedKeys: inout Set<String>) {
        for agent in projection.agents where agent.status == .blocked {
            let key = causeKey(projectKey: projectKey, agentName: agent.name, cause: .block)
            observedKeys.insert(key)

            let since = firstSeen[key] ?? now()
            firstSeen[key] = since

            guard fired[key] == nil, now().timeIntervalSince(since) >= blockThreshold else { continue }
            fire(key: key, projectKey: projectKey, agentName: agent.name,
                 title: "\(agent.name) is blocked",
                 subtitle: projectKey,
                 body: "\(agent.name) has been blocked for over \(Int(blockThreshold))s and needs a human.")
        }
    }

    // MARK: - Collision needing a human

    private func evaluateCollisions(projectKey: String, projection: FlywheelProjection, observedKeys: inout Set<String>) {
        let agentsByName = Dictionary(uniqueKeysWithValues: projection.agents.map { ($0.name, $0) })

        for reservation in projection.reservations where !reservation.waiters.isEmpty {
            let holder = agentsByName[reservation.holder]
            // No agent row for the holder reads as "dead" — the process that took the
            // lease is no longer in the agents lane at all, which is strictly worse than
            // stalled (there's no one left to even self-clear).
            let holderIsStalledOrDead = holder == nil || holder?.status == .stalled
            guard holderIsStalledOrDead else { continue }

            let key = causeKey(projectKey: projectKey, agentName: reservation.holder, cause: .collision(file: reservation.file))
            observedKeys.insert(key)
            guard fired[key] == nil else { continue }

            fire(key: key, projectKey: projectKey, agentName: reservation.holder,
                 title: "\(reservation.holder) is blocking \(reservation.waiters.count == 1 ? reservation.waiters[0] : "\(reservation.waiters.count) agents")",
                 subtitle: projectKey,
                 body: "\(reservation.holder) holds \(reservation.file) and can't clear it — needs a human.")
        }
    }

    // MARK: - Dependency cycle

    private func evaluateDependencyCycle(projectKey: String, projection: FlywheelProjection, observedKeys: inout Set<String>) {
        guard let cycleParticipants = firstDependencyCycle(in: projection.depEdges), let leader = cycleParticipants.min() else { return }

        let key = causeKey(projectKey: projectKey, agentName: leader, cause: .depCycle)
        observedKeys.insert(key)
        guard fired[key] == nil else { return }

        fire(key: key, projectKey: projectKey, agentName: leader,
             title: "Dependency cycle involving \(leader)",
             subtitle: projectKey,
             body: "A dependency cycle needs a human to break it: \(cycleParticipants.sorted().joined(separator: ", ")).")
    }

    /// Standard visited/in-progress DFS back-edge detection over `.dependency` edges only —
    /// reservation-derived edges are lock contention, not a real dependency cycle, and are
    /// handled by `evaluateCollisions` instead. Returns the set of node names on the first
    /// cycle found, or nil if the dependency subgraph is acyclic.
    private func firstDependencyCycle(in depEdges: [FlywheelProjection.DepEdge]) -> Set<String>? {
        var adjacency: [String: [String]] = [:]
        for edge in depEdges where edge.kind == .dependency {
            adjacency[edge.from, default: []].append(edge.to)
        }
        guard !adjacency.isEmpty else { return nil }

        var visited: Set<String> = []
        var inProgress: [String] = []
        var onStack: Set<String> = []

        func visit(_ node: String) -> Set<String>? {
            if onStack.contains(node) {
                // Found the back edge — the cycle is everything from this node's first
                // occurrence on the stack to the top.
                guard let startIndex = inProgress.firstIndex(of: node) else { return [node] }
                return Set(inProgress[startIndex...])
            }
            guard !visited.contains(node) else { return nil }

            visited.insert(node)
            inProgress.append(node)
            onStack.insert(node)
            defer {
                inProgress.removeLast()
                onStack.remove(node)
            }

            for next in adjacency[node] ?? [] {
                if let cycle = visit(next) { return cycle }
            }
            return nil
        }

        // Sorted for determinism — dictionary iteration order is not stable across runs,
        // and "first cycle found" must mean the same thing every evaluate().
        for node in adjacency.keys.sorted() {
            if let cycle = visit(node) { return cycle }
        }
        return nil
    }

    // MARK: - Shared fire/clear machinery

    private func causeKey(projectKey: String, agentName: String, cause: Cause) -> String {
        switch cause {
        case .block: return "\(projectKey)|\(agentName)|block"
        case .collision(let file): return "\(projectKey)|\(agentName)|collision:\(file)"
        case .depCycle: return "\(projectKey)|\(agentName)|depCycle"
        }
    }

    private func fire(key: String, projectKey: String, agentName: String, title: String, subtitle: String, body: String) {
        guard let sessionID = route(projectKey, agentName) else { return }
        if !didRequestAuthorization {
            didRequestAuthorization = true
            notifier.requestAuthorization()
        }
        notifier.notify(sessionID: sessionID, title: title, subtitle: subtitle, body: body)
        fired[key] = sessionID
    }

    /// Anything that fired (or was being timed toward firing) on a previous evaluate but
    /// wasn't observed this time has cleared — a transient block that self-heals before
    /// threshold simply drops out of `firstSeen` with no notification ever sent; a fired
    /// condition additionally gets withdrawn from Notification Center.
    private func clearStaleConditions(observedKeys: Set<String>) {
        // Collect first, then mutate — removing from a dictionary while a for-in loop is
        // enumerating it is undefined behavior, not just untidy.
        let staleFirstSeen = firstSeen.keys.filter { !observedKeys.contains($0) }
        for key in staleFirstSeen {
            firstSeen.removeValue(forKey: key)
        }

        let staleFired = fired.filter { !observedKeys.contains($0.key) }
        for (key, sessionID) in staleFired {
            fired.removeValue(forKey: key)
            notifier.withdraw(sessionID: sessionID)
        }
    }
}
