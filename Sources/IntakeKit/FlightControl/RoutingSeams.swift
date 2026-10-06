import Foundation

// Pools come from L3-0 (`PoolSummary`, `PoolDirectory`, `DefaultPoolDirectory` live in the contract).
// L3-U's pool store conforms to the contract's `PoolDirectory` at integration. What this file adds
// are the seams the contract does not name: the null index, rule hints, and rule sources.

/// The index with no data: every task falls through to the default (spec §5 step 4). Stands in
/// for L3-I's index until integration.
public struct NullCapabilityIndex: CapabilityIndex {
    public init() {}
    public func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] { [] }
    public var snapshotDate: Date? { nil }
}

// CONTRACT GAP (L3-R deviation 4). L3-0's `CapabilityIndex` has no hint call. L3-R draws the
// hint (spec §7); L3-I computes it (its §6) and conforms to `RuleHintSource` at integration.

/// One dismissible line under a confirmed rule. `snapshotDate` is the index snapshot it came
/// from: a dismissal holds until that changes.
public struct RuleHint: Equatable, Sendable {
    public var ruleID: String
    public var text: String
    public var snapshotDate: Date
    /// The better model, bare (no knobs), for the hint popover's "Switch to …". nil when a
    /// source can only describe the hint, in which case the popover offers Dismiss alone.
    public var suggested: ModelRef?
    public init(ruleID: String, text: String, snapshotDate: Date, suggested: ModelRef? = nil) {
        self.ruleID = ruleID; self.text = text; self.snapshotDate = snapshotDate; self.suggested = suggested
    }
}

public protocol RuleHintSource: Sendable {
    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint?
}

public struct NoRuleHints: RuleHintSource {
    public init() {}
    public func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? { nil }
}

/// The two lists a project routes by, project first.
public struct RuleLists: Equatable, Sendable {
    public var project: [RoutingRule]
    public var global: [RoutingRule]
    public init(project: [RoutingRule], global: [RoutingRule]) { self.project = project; self.global = global }
}

public protocol RoutingRuleSource: Sendable {
    func rules(project: URL) -> RuleLists
}

/// Rules held in memory, keyed by standardized project path.
public struct StaticRuleSource: RoutingRuleSource {
    public let global: [RoutingRule]
    public let byProject: [String: [RoutingRule]]

    public init(global: [RoutingRule], byProject: [String: [RoutingRule]] = [:]) {
        self.global = global
        self.byProject = Dictionary(byProject.map { (URL(fileURLWithPath: $0.key, isDirectory: true).standardizedFileURL.path, $0.value) },
                                    uniquingKeysWith: { a, _ in a })
    }

    public func rules(project: URL) -> RuleLists {
        RuleLists(project: byProject[project.standardizedFileURL.path] ?? [], global: global)
    }
}

/// The app's source: a snapshot of the global list, and each project's `routing.json` read at
/// routing time, so a rule confirmed in another window applies at the next launch of a task.
public struct ProjectFileRuleSource: RoutingRuleSource {
    public let global: [RoutingRule]
    public let store: ProjectRoutingStore
    public init(global: [RoutingRule], store: ProjectRoutingStore = ProjectRoutingStore()) {
        self.global = global; self.store = store
    }
    public func rules(project: URL) -> RuleLists {
        RuleLists(project: store.load(project: project).rules, global: global)
    }
}

extension PoolDirectory {
    /// Each listed agent's default pool; an agent with none is left out, so routing never
    /// assigns an agent a pool that does not exist. One loop for the router and its callers.
    public func defaultPools(for harnesses: [HarnessID]) -> [HarnessID: PoolID] {
        var out: [HarnessID: PoolID] = [:]
        for h in harnesses { if let p = defaultPool(for: h) { out[h] = p } }
        return out
    }
}
