import Foundation
import IntakeKit

/// The routing inputs every L3-R table test routes against, in one place, so each test's own
/// lines are only the case it pins.
enum RoutingTestData {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func kind(_ id: KindID, _ dims: [String: Double], origin: KindOrigin = .seed,
                     status: KindStatus = .active) -> TaskKind {
        TaskKind(id: id, name: id.rawValue, description: "d", dimensions: dims, origin: origin, status: status, createdAt: at)
    }

    static let tests = kind("tests", ["test-authoring": 0.9, "agentic-coding": 0.4])
    static let snapshot = kind("snapshot-tests", ["test-authoring": 0.8, "agentic-coding": 0.3], origin: .planning)
    static let golden = kind("golden-tests", ["test-authoring": 0.8], origin: .planning, status: .merged(into: "snapshot-tests"))
    static let algorithm = kind("algorithm", ["algorithmic-reasoning": 0.9, "agentic-coding": 0.3])
    static let docs = kind("docs", ["docs-prose": 0.9])
    static let kinds = [tests, snapshot, golden, algorithm, docs]

    static let catalogs = AdapterCatalogs([
        AdapterCatalog(harness: "codex",
                       models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6-Sol", knobs: ["effort"]),
                                ModelEntry(id: "gpt-6-luna", displayName: "GPT-6-Luna", knobs: ["effort"])],
                       knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true),
        AdapterCatalog(harness: "claude",
                       models: [ModelEntry(id: "opus", displayName: "Opus", knobs: ["effort"]),
                                ModelEntry(id: "haiku", displayName: "Haiku", knobs: ["effort"])],
                       knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "opus", enabled: true),
    ])

    /// `catalogs` with the named harnesses switched off.
    static func catalogsDisabling(_ off: Set<HarnessID>) -> AdapterCatalogs {
        AdapterCatalogs(catalogs.order.compactMap { h -> AdapterCatalog? in
            guard var c = catalogs.byHarness[h] else { return nil }
            if off.contains(h) { c.enabled = false }
            return c
        })
    }

    static let pools = [
        PoolSummary(id: "codex-default", harness: "codex", label: "codex"),
        PoolSummary(id: "codex-subs", harness: "codex", label: "codex subscriptions"),
        PoolSummary(id: "claude-default", harness: "claude", label: "claude"),
        PoolSummary(id: "claude-subs", harness: "claude", label: "claude subscriptions"),
    ]
    static let defaultPools: [HarnessID: PoolID] = ["codex": "codex-default", "claude": "claude-default"]

    static func rule(_ id: String, _ match: RuleMatch, _ harness: HarnessID, _ model: String,
                     knobs: [String: String] = [:], pool: PoolID, fallbackPool: PoolID? = nil,
                     state: RuleState = .confirmed) -> RoutingRule {
        RoutingRule(id: id, sentence: "rule \(id)",
                    compiled: CompiledRule(match: match, assign: RuleAssign(harness: harness, model: model, knobs: knobs,
                                                                            pool: pool, fallbackPool: fallbackPool)),
                    state: state)
    }

    /// The spec's example (L3-R §2): codex for tests and hard algorithms.
    static func r3(pool: PoolID = "codex-subs", fallbackPool: PoolID? = nil, state: RuleState = .confirmed) -> RoutingRule {
        rule("r3", .any([.dimension("test-authoring", atLeast: 0.5), .dimension("algorithmic-reasoning", atLeast: 0.6),
                         .kind("tests")]),
             "codex", "gpt-6-sol", knobs: ["effort": "high"], pool: pool, fallbackPool: fallbackPool, state: state)
    }

    static func context(project: [RoutingRule] = [], global: [RoutingRule] = [], kinds: [TaskKind] = RoutingTestData.kinds,
                        catalogs: AdapterCatalogs = RoutingTestData.catalogs, pools: [PoolSummary] = RoutingTestData.pools,
                        defaultPools: [HarnessID: PoolID] = RoutingTestData.defaultPools,
                        defaultHarness: HarnessID? = "claude",
                        index: any CapabilityIndex = NullCapabilityIndex()) -> RoutingContext {
        RoutingContext(projectRules: project, globalRules: global, kinds: kinds, catalogs: catalogs, pools: pools,
                       defaultPools: defaultPools, defaultHarness: defaultHarness, index: index, now: at)
    }
}
