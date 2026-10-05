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
    public var defaultPools: [HarnessID: PoolID]
    /// The project's default agent (its Projects-pane agent, else the first global agent).
    public var defaultHarness: HarnessID?
    public var index: any CapabilityIndex
    public var confidenceFloor: Double
    public var now: Date

    public init(projectRules: [RoutingRule], globalRules: [RoutingRule], kinds: [TaskKind], catalogs: AdapterCatalogs,
                pools: [PoolSummary], defaultPools: [HarnessID: PoolID], defaultHarness: HarnessID?,
                index: any CapabilityIndex, confidenceFloor: Double = RouterCore.defaultConfidenceFloor, now: Date) {
        self.projectRules = projectRules; self.globalRules = globalRules; self.kinds = kinds; self.catalogs = catalogs
        self.pools = pools; self.defaultPools = defaultPools; self.defaultHarness = defaultHarness
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
            let reason = ruleReason(compiled.match, live: live, chain: chain, harness: a.harness)
            return .routed(Assignment(block: ExecutionBlock(
                kind: kind.id, harness: a.harness, model: a.model, knobs: a.knobs, pool: a.pool,
                source: AssignmentSource(by: .rule, ruleId: rule.id, reason: reason, at: ctx.now))))
        }

        let candidates = ctx.catalogs.enabledModels.filter { ctx.defaultPools[$0.harness] != nil }
        if !candidates.isEmpty,
           let best = ctx.index.rank(kind: live, candidates: candidates).first(where: { $0.confidence >= ctx.confidenceFloor }),
           candidates.contains(where: { $0.harness == best.model.harness && $0.model == best.model.model }),
           let pool = ctx.defaultPools[best.model.harness] {
            let reason = "index: \(best.model.harness.rawValue)/\(best.model.model) scores \(RuleText.number(best.score))"
                + " for \(live.id.rawValue) (confidence \(RuleText.number(best.confidence)))"
            return .routed(Assignment(block: ExecutionBlock(
                kind: kind.id, harness: best.model.harness, model: best.model.model, pool: pool,
                source: AssignmentSource(by: .index, reason: reason, at: ctx.now))))
        }

        guard let choice = defaultChoice(ctx) else { return .unroutable("no enabled agent has a model and a pool") }
        return .routed(Assignment(block: ExecutionBlock(
            kind: kind.id, harness: choice.harness, model: choice.model, pool: choice.pool,
            source: AssignmentSource(by: .default,
                                     reason: "default agent \(choice.harness.rawValue): no rule matched and the index had no confident answer",
                                     at: ctx.now))))
    }

    /// The rule's assignment if it can still run: agent enabled, model listed, knobs accepted,
    /// pool present and the agent's. A rule written for a model that has since left the catalog
    /// is skipped — routing to it would hand the swarm a block nothing can launch.
    static func usable(_ a: RuleAssign, _ ctx: RoutingContext) -> RuleAssign? {
        guard ctx.catalogs.byHarness[a.harness]?.enabled == true else { return nil }
        let ref = ModelRef(harness: a.harness, model: a.model, knobs: a.knobs)
        guard ctx.catalogs.contains(ref), ctx.catalogs.knobsValid(ref) else { return nil }
        guard ctx.pools.contains(where: { $0.id == a.pool && $0.harness == a.harness }) else { return nil }
        return a
    }

    static func defaultChoice(_ ctx: RoutingContext) -> (harness: HarnessID, model: String, pool: PoolID)? {
        var order = ctx.catalogs.order
        if let preferred = ctx.defaultHarness { order.insert(preferred, at: 0) }
        for h in order {
            guard let cat = ctx.catalogs.byHarness[h], cat.enabled, let pool = ctx.defaultPools[h],
                  let model = cat.defaultModel ?? cat.models.first?.id,
                  cat.models.contains(where: { $0.id == model }) else { continue }
            return (h, model, pool)
        }
        return nil
    }

    /// The terms that held, with the kind's actual weight — "test-authoring 0.8 → codex".
    static func ruleReason(_ match: RuleMatch, live: TaskKind, chain: [KindID], harness: HarnessID) -> String {
        let held = match.terms.compactMap { term -> String? in
            switch term {
            case .dimension(let d, let atLeast):
                let w = live.dimensions[d] ?? 0
                return w >= atLeast ? "\(d) \(RuleText.number(w))" : nil
            case .kind(let k):
                return chain.contains(k) ? "kind \(k.rawValue)" : nil
            }
        }
        return held.joined(separator: " + ") + " → \(harness.rawValue)"
    }
}
