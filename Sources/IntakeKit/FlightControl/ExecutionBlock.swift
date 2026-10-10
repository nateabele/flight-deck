import Foundation

/// A model as an agent names it, with the knobs it runs at.
public struct ModelRef: Codable, Hashable, Sendable {
    public var agent: AgentID
    public var model: String
    public var knobs: [String: String]
    public init(agent: AgentID, model: String, knobs: [String: String] = [:]) {
        self.agent = agent; self.model = model; self.knobs = knobs
    }

    /// `agent` keeps its pre-unification JSON key, `harness` (unify brief R1).
    private enum CodingKeys: String, CodingKey {
        case agent = "harness"
        case model, knobs
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
    /// Stored at whole-second precision (ISO 8601 without fractions), so a block built from
    /// `Date()` is not equal to itself after a codec round trip. Truncate before comparing.
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
    public var agent: AgentID
    public var model: String
    public var knobs: [String: String]
    public var pool: PoolID
    public var source: AssignmentSource
    /// Set by a manual edit. The router never overwrites a pinned block, and it never spills.
    public var pinned: Bool
    /// Reserved for remote hosts; always nil in v1.
    public var host: String?

    public init(v: Int = ExecutionBlock.currentVersion, kind: KindID, agent: AgentID, model: String,
                knobs: [String: String] = [:], pool: PoolID, source: AssignmentSource,
                pinned: Bool = false, host: String? = nil) {
        self.v = v; self.kind = kind; self.agent = agent; self.model = model; self.knobs = knobs
        self.pool = pool; self.source = source; self.pinned = pinned; self.host = host
    }

    public var modelRef: ModelRef { ModelRef(agent: agent, model: model, knobs: knobs) }
}
