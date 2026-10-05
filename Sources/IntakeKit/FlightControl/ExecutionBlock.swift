import Foundation

/// A model as a harness names it, with the knobs it runs at.
public struct ModelRef: Codable, Hashable, Sendable {
    public var harness: HarnessID
    public var model: String
    public var knobs: [String: String]
    public init(harness: HarnessID, model: String, knobs: [String: String] = [:]) {
        self.harness = harness; self.model = model; self.knobs = knobs
    }
}

/// Who chose a block's assignment. `manual` always comes with `pinned`.
public enum AssignmentSourceKind: String, Codable, Sendable, CaseIterable {
    case rule, index, `default`, spill, manual
}

public struct AssignmentSource: Codable, Equatable, Sendable {
    public var by: AssignmentSourceKind
    public var ruleId: String?
    public var reason: String
    public var at: Date
    public init(by: AssignmentSourceKind, ruleId: String? = nil, reason: String, at: Date) {
        self.by = by; self.ruleId = ruleId; self.reason = reason; self.at = at
    }
}

/// How to run one task: stored at `agent_context.flight_deck.execution` on its br task.
///
/// Classification (`kind`) comes from the planning LLM; everything else is a deterministic
/// routing result. `pool` names capacity, not an account — the account is leased at spawn.
public struct ExecutionBlock: Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var kind: KindID
    public var harness: HarnessID
    public var model: String
    public var knobs: [String: String]
    public var pool: PoolID
    public var source: AssignmentSource
    /// Set by a manual edit. The router never overwrites a pinned block, and it never spills.
    public var pinned: Bool
    /// Reserved for remote hosts; always nil in v1.
    public var host: String?

    public init(v: Int = ExecutionBlock.currentVersion, kind: KindID, harness: HarnessID, model: String,
                knobs: [String: String] = [:], pool: PoolID, source: AssignmentSource,
                pinned: Bool = false, host: String? = nil) {
        self.v = v; self.kind = kind; self.harness = harness; self.model = model; self.knobs = knobs
        self.pool = pool; self.source = source; self.pinned = pinned; self.host = host
    }

    public var modelRef: ModelRef { ModelRef(harness: harness, model: model, knobs: knobs) }
}
