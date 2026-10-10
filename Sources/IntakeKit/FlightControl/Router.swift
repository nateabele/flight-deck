import Foundation

public enum KindChain {
    /// `id`, then every kind it was merged into, in order. Bounded by the registry size and by
    /// repeats, so a hand-edited cycle ends instead of spinning.
    public static func ids(from id: KindID, in kinds: [TaskKind]) -> [KindID] {
        var out = [id]
        var current = id
        for _ in 0..<kinds.count {
            guard let k = kinds.first(where: { $0.id == current }),
                  case .merged(let next) = k.status,
                  !out.contains(next) else { break }
            out.append(next)
            current = next
        }
        return out
    }
}

/// Everything one routing decision reads. A value, so the router is a pure function of it.
public struct RoutingContext: Sendable {
    public var projectRules: [RoutingRule]
    public var globalRules: [RoutingRule]
    public var kinds: [TaskKind]
    public var catalogs: AdapterCatalogs
    public var pools: [PoolSummary]
    public var defaultPools: [AgentID: PoolID]
    /// The project's default agent (its Projects-pane agent, else the first global agent).
    public var defaultAgent: AgentID?
    public var index: any CapabilityIndex
    public var confidenceFloor: Double
    public var now: Date

    public init(projectRules: [RoutingRule], globalRules: [RoutingRule], kinds: [TaskKind], catalogs: AdapterCatalogs,
                pools: [PoolSummary], defaultPools: [AgentID: PoolID], defaultAgent: AgentID?,
                index: any CapabilityIndex, confidenceFloor: Double = RouterCore.defaultConfidenceFloor, now: Date) {
        self.projectRules = projectRules; self.globalRules = globalRules; self.kinds = kinds; self.catalogs = catalogs
        self.pools = pools; self.defaultPools = defaultPools; self.defaultAgent = defaultAgent
        self.index = index; self.confidenceFloor = confidenceFloor; self.now = now
    }
}

public enum RouteOutcome: Equatable, Sendable {
    case routed(Assignment)
    case unroutable(String)
}

/// The router (spec L3-R §5), as a pure function over a `RoutingContext`.
public enum RouterCore {
    public static let defaultConfidenceFloor = 0.5

    /// 1. Resolve the kind. 2. First confirmed matching rule, project list then global.
    /// 3. Else the index's best candidate at or above the floor. 4. Else the default agent's
    /// default model. 5. The pool is the rule's, else the agent's default.
    ///
    /// The block keeps `kind.id`, not the resolved id: a merge must never require rewriting
    /// tasks, so resolution happens on every read instead.
    public static func assign(kind: TaskKind, _ ctx: RoutingContext) -> RouteOutcome {
        let live = KindResolution.resolve(kind.id, in: ctx.kinds) ?? kind
        let chain = KindChain.ids(from: kind.id, in: ctx.kinds)

        for rule in ctx.projectRules + ctx.globalRules where rule.state == .confirmed {
            guard let compiled = rule.compiled,
                  compiled.match.holds(weights: live.dimensions, chain: chain),
                  let a = usable(compiled.assign, ctx) else { continue }
            let reason = ruleReason(compiled.match, live: live, chain: chain, agent: a.agent)
            return .routed(Assignment(block: ExecutionBlock(
                kind: kind.id, agent: a.agent, model: a.model, knobs: a.knobs, pool: a.pool,
                source: AssignmentSource(by: .rule, ruleId: rule.id, reason: reason, at: ctx.now))))
        }

        let candidates = ctx.catalogs.enabledModels.filter { ctx.defaultPools[$0.agent] != nil }
        if !candidates.isEmpty,
           let best = ctx.index.rank(kind: live, candidates: candidates).first(where: { $0.confidence >= ctx.confidenceFloor }),
           candidates.contains(where: { $0.agent == best.model.agent && $0.model == best.model.model }),
           let pool = ctx.defaultPools[best.model.agent] {
            let reason = "index: \(best.model.agent.rawValue)/\(best.model.model) scores \(RuleText.number(best.score))"
                + " for \(live.id.rawValue) (confidence \(RuleText.number(best.confidence)))"
            return .routed(Assignment(block: ExecutionBlock(
                kind: kind.id, agent: best.model.agent, model: best.model.model, pool: pool,
                source: AssignmentSource(by: .index, reason: reason, at: ctx.now))))
        }

        guard let choice = defaultChoice(ctx) else { return .unroutable("no enabled agent has a model and a pool") }
        return .routed(Assignment(block: ExecutionBlock(
            kind: kind.id, agent: choice.agent, model: choice.model, pool: choice.pool,
            source: AssignmentSource(by: .default,
                                     reason: "default agent \(choice.agent.rawValue): no rule matched and the index had no confident answer",
                                     at: ctx.now))))
    }

    /// Re-routes ONE spawn with `exhausted` pools removed (spec §5). Called by L3-S at spawn,
    /// never by encode, and the caller never writes the result back to the task: a spill is a
    /// detour for this spawn, not a new decision about the task.
    ///
    /// The rule's `fallbackPool` goes first — it is the spill target the sentence named. A
    /// pinned block never spills: a manual choice waits for its pool rather than being undone.
    public static func spill(_ block: ExecutionBlock, kind: TaskKind, exhausted: Set<PoolID>,
                             _ ctx: RoutingContext) -> Assignment? {
        guard !block.pinned else { return nil }
        var open = ctx
        open.pools = ctx.pools.filter { !exhausted.contains($0.id) }
        open.defaultPools = ctx.defaultPools.filter { !exhausted.contains($0.value) }

        func spilled(_ b: ExecutionBlock, ruleId: String?) -> Assignment {
            var out = b
            out.kind = block.kind
            out.source = AssignmentSource(by: .spill, ruleId: ruleId,
                                          reason: "\(block.pool.rawValue) exhausted → \(b.pool.rawValue)/\(b.model)", at: ctx.now)
            return Assignment(block: out)
        }

        if let ruleId = block.source.ruleId,
           let rule = (ctx.projectRules + ctx.globalRules).first(where: { $0.id == ruleId }),
           let compiled = rule.compiled, let fallback = compiled.assign.fallbackPool,
           let pool = open.pools.first(where: { $0.id == fallback }),
           let cat = open.catalogs.byAgent[pool.agent], cat.enabled {
            let sameAgent = pool.agent == compiled.assign.agent
            let model = sameAgent ? compiled.assign.model : (cat.defaultModel ?? cat.models.first?.id)
            let knobs = sameAgent ? compiled.assign.knobs : [:]
            if let model, open.catalogs.contains(ModelRef(agent: pool.agent, model: model)) {
                let b = ExecutionBlock(kind: block.kind, agent: pool.agent, model: model, knobs: knobs,
                                       pool: pool.id, source: block.source)
                return spilled(b, ruleId: ruleId)
            }
        }

        guard case .routed(let a) = assign(kind: kind, open) else { return nil }
        return spilled(a.block, ruleId: a.block.source.ruleId)
    }

    /// The rule's assignment if it can still run: agent enabled, model listed, knobs accepted,
    /// pool present and the agent's. A rule written for a model that has since left the catalog
    /// is skipped — routing to it would hand the swarm a block nothing can launch.
    static func usable(_ a: RuleAssign, _ ctx: RoutingContext) -> RuleAssign? {
        guard ctx.catalogs.byAgent[a.agent]?.enabled == true else { return nil }
        let ref = ModelRef(agent: a.agent, model: a.model, knobs: a.knobs)
        guard ctx.catalogs.contains(ref), ctx.catalogs.knobsValid(ref) else { return nil }
        guard ctx.pools.contains(where: { $0.id == a.pool && $0.agent == a.agent }) else { return nil }
        return a
    }

    static func defaultChoice(_ ctx: RoutingContext) -> (agent: AgentID, model: String, pool: PoolID)? {
        var order = ctx.catalogs.order
        if let preferred = ctx.defaultAgent { order.insert(preferred, at: 0) }
        for h in order {
            guard let cat = ctx.catalogs.byAgent[h], cat.enabled, let pool = ctx.defaultPools[h],
                  let model = cat.defaultModel ?? cat.models.first?.id,
                  cat.models.contains(where: { $0.id == model }) else { continue }
            return (h, model, pool)
        }
        return nil
    }

    /// The terms that held, with the kind's actual weight — "test-authoring 0.8 → codex".
    static func ruleReason(_ match: RuleMatch, live: TaskKind, chain: [KindID], agent: AgentID) -> String {
        let held = match.terms.compactMap { term -> String? in
            switch term {
            case .dimension(let d, let atLeast):
                let w = live.dimensions[d] ?? 0
                return w >= atLeast ? "\(d) \(RuleText.number(w))" : nil
            case .kind(let k):
                return chain.contains(k) ? "kind \(k.rawValue)" : nil
            }
        }
        return held.joined(separator: " + ") + " → \(agent.rawValue)"
    }
}

/// The contract's `Router` (L3-0 §7): reads its context from injected sources, then defers to
/// `RouterCore`. L3-S calls `assign` at launch and `spill` at spawn through the protocol.
public struct RuleRouter: Router {
    public let rules: any RoutingRuleSource
    public let kinds: any KindRegistry
    public let index: any CapabilityIndex
    public let pools: any PoolDirectory
    public let defaultAgent: @Sendable (URL) -> AgentID?
    public let confidenceFloor: Double

    public init(rules: any RoutingRuleSource, kinds: any KindRegistry, index: any CapabilityIndex,
                pools: any PoolDirectory, defaultAgent: @escaping @Sendable (URL) -> AgentID?,
                confidenceFloor: Double = RouterCore.defaultConfidenceFloor) {
        self.rules = rules; self.kinds = kinds; self.index = index; self.pools = pools
        self.defaultAgent = defaultAgent; self.confidenceFloor = confidenceFloor
    }

    /// An unreadable registry routes with no kinds: the task's own weights still decide, and
    /// a broken `kinds.json` must not stop the swarm.
    public func context(project: URL, catalogs: AdapterCatalogs, now: Date) -> RoutingContext {
        let lists = rules.rules(project: project)
        return RoutingContext(projectRules: lists.project, globalRules: lists.global,
                              kinds: (try? kinds.kinds(project: project)) ?? [],
                              catalogs: catalogs, pools: pools.pools(), defaultPools: pools.defaultPools(for: catalogs.order),
                              defaultAgent: defaultAgent(project), index: index,
                              confidenceFloor: confidenceFloor, now: now)
    }

    public func route(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> RouteOutcome {
        RouterCore.assign(kind: kind, context(project: project, catalogs: catalogs, now: now))
    }

    /// The contract's `assign` cannot fail (deviation 5), so an unroutable task gets
    /// `Assignment.unroutable`: empty harness, model and pool. `ExecutionBlockCodec` refuses to
    /// decode an empty field, so nothing downstream can launch it; callers that can fail use
    /// `route` instead.
    public func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        switch route(kind: kind, project: project, catalogs: catalogs, now: now) {
        case .routed(let a):
            return a
        case .unroutable(let why):
            return Assignment.unroutable(kind: kind.id, reason: why, at: now)
        }
    }

    public func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
                      catalogs: AdapterCatalogs, now: Date) -> Assignment? {
        RouterCore.spill(block, kind: kind, exhausted: exhausted, context(project: project, catalogs: catalogs, now: now))
    }
}
