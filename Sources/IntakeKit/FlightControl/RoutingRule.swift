import Foundation

/// One condition of a compiled rule (spec L3-R §2).
///
/// A dimension term holds when the task kind's weight on that dimension is at least `atLeast`;
/// a kind term holds when the task's kind is that kind or was merged into it. Dimension terms
/// are what let a rule route a kind that did not exist when the rule was written (success
/// criterion 2) — a rule made only of kind names would need recompiling for every new kind.
public enum MatchTerm: Codable, Hashable, Sendable {
    case dimension(String, atLeast: Double)
    case kind(KindID)

    private enum Key: String, CodingKey { case dimension, atLeast, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let kind = try c.decodeIfPresent(KindID.self, forKey: .kind) {
            self = .kind(kind)
        } else {
            self = .dimension(try c.decode(String.self, forKey: .dimension),
                              atLeast: try c.decode(Double.self, forKey: .atLeast))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .dimension(let d, let atLeast):
            try c.encode(d, forKey: .dimension)
            try c.encode(atLeast, forKey: .atLeast)
        case .kind(let k):
            try c.encode(k, forKey: .kind)
        }
    }
}

/// `{"any": [...]}` or `{"all": [...]}`.
public enum RuleMatch: Codable, Equatable, Sendable {
    case any([MatchTerm])
    case all([MatchTerm])

    public var terms: [MatchTerm] {
        switch self {
        case .any(let t): return t
        case .all(let t): return t
        }
    }

    private enum Key: String, CodingKey { case any, all }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let t = try c.decodeIfPresent([MatchTerm].self, forKey: .any) {
            self = .any(t)
        } else if let t = try c.decodeIfPresent([MatchTerm].self, forKey: .all) {
            self = .all(t)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a match needs `any` or `all`"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .any(let t): try c.encode(t, forKey: .any)
        case .all(let t): try c.encode(t, forKey: .all)
        }
    }

    /// `chain` is the task's kind followed by every kind it was merged into (`KindChain`).
    ///
    /// An empty `any` and an empty `all` both fail. `all` of nothing is vacuously true in logic,
    /// and a rule that compiled to no conditions would then route every task in the project.
    public func holds(weights: [String: Double], chain: [KindID]) -> Bool {
        func one(_ term: MatchTerm) -> Bool {
            switch term {
            case .dimension(let d, let atLeast): return (weights[d] ?? 0) >= atLeast
            case .kind(let k): return chain.contains(k)
            }
        }
        switch self {
        case .any(let t): return t.contains(where: one)
        case .all(let t): return !t.isEmpty && t.allSatisfy(one)
        }
    }
}

/// Where a matching rule sends the task.
public struct RuleAssign: Codable, Equatable, Sendable {
    public var harness: HarnessID
    public var model: String
    public var knobs: [String: String]
    /// Never absent once validated: a sentence that names no pool gets the adapter's default
    /// pool at compile time, so the compiled text says where the work will go.
    public var pool: PoolID
    /// The explicit spill target a sentence names ("…, else claude-subs"). Tried first by spill.
    public var fallbackPool: PoolID?
    /// The sentence named no model and the compiler took the adapter's default. Shown in the
    /// compiled form so a later change of default is not a silent re-route.
    public var modelDefaulted: Bool

    public init(harness: HarnessID, model: String, knobs: [String: String] = [:], pool: PoolID,
                fallbackPool: PoolID? = nil, modelDefaulted: Bool = false) {
        self.harness = harness; self.model = model; self.knobs = knobs; self.pool = pool
        self.fallbackPool = fallbackPool; self.modelDefaulted = modelDefaulted
    }

    private enum CodingKeys: String, CodingKey { case harness, model, knobs, pool, fallbackPool, modelDefaulted }

    /// `knobs` and `modelDefaulted` are optional on read: the spec's own example omits
    /// `modelDefaulted`, and a hand-edited `routing.json` should not stop decoding over it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        harness = try c.decode(HarnessID.self, forKey: .harness)
        model = try c.decode(String.self, forKey: .model)
        knobs = try c.decodeIfPresent([String: String].self, forKey: .knobs) ?? [:]
        pool = try c.decode(PoolID.self, forKey: .pool)
        fallbackPool = try c.decodeIfPresent(PoolID.self, forKey: .fallbackPool)
        modelDefaulted = try c.decodeIfPresent(Bool.self, forKey: .modelDefaulted) ?? false
    }
}

public struct CompiledRule: Codable, Equatable, Sendable {
    public var match: RuleMatch
    public var assign: RuleAssign
    public init(match: RuleMatch, assign: RuleAssign) { self.match = match; self.assign = assign }
}

/// `draft` → `compiled` (waiting for you) → `confirmed`, or `failed`. Only `confirmed` routes.
public enum RuleState: String, Codable, Sendable { case draft, compiled, confirmed, failed }

/// Which model compiled a rule — recorded so a surprising compile can be traced to its compiler.
public struct CompilerRef: Codable, Equatable, Sendable {
    public var harness: HarnessID
    public var model: String
    public init(harness: HarnessID, model: String) { self.harness = harness; self.model = model }
}

/// The headless call that compiles a sentence. A cheap model by default: the output is a small,
/// schema-constrained object that a validator checks anyway (spec §3).
public struct RuleCompilerSettings: Codable, Equatable, Sendable {
    public var harness: Harness
    public var model: String
    public var effort: String
    public init(harness: Harness = .claude, model: String = "haiku", effort: String = "low") {
        self.harness = harness; self.model = model; self.effort = effort
    }
    public static let `default` = RuleCompilerSettings()
    public var ref: CompilerRef { CompilerRef(harness: HarnessID(harness.rawValue), model: model) }
}

public struct RoutingRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sentence: String
    public var compiled: CompiledRule?
    public var state: RuleState
    /// The first validation error of the last compile, shown inline when `state == .failed`.
    public var failure: String?
    public var compiledAt: Date?
    public var compiler: CompilerRef?

    public init(id: String, sentence: String, compiled: CompiledRule? = nil, state: RuleState = .draft,
                failure: String? = nil, compiledAt: Date? = nil, compiler: CompilerRef? = nil) {
        self.id = id; self.sentence = sentence; self.compiled = compiled; self.state = state
        self.failure = failure; self.compiledAt = compiledAt; self.compiler = compiler
    }

    /// Editing the sentence moves the rule back to draft (spec §2). The compiled form is dropped,
    /// not kept: a confirmed form compiled from the old words must not keep routing under new ones.
    public mutating func edit(sentence new: String) {
        guard new != sentence else { return }
        sentence = new
        compiled = nil; state = .draft; failure = nil; compiledAt = nil; compiler = nil
    }

    /// Only a compiled rule that is waiting for you can be confirmed.
    @discardableResult
    public mutating func confirm() -> Bool {
        guard state == .compiled, compiled != nil else { return false }
        state = .confirmed
        return true
    }
}

/// `.flightdeck/routing.json`.
public struct RoutingRuleFile: Codable, Equatable, Sendable {
    public var v: Int
    public var rules: [RoutingRule]
    public init(v: Int = 1, rules: [RoutingRule]) { self.v = v; self.rules = rules }
}

/// The compiled form in plain words, as Settings shows it under the sentence (spec §3). Kind
/// names are wrapped in `*…*` so the pane can render them italic through Markdown.
public enum RuleText {
    /// `%g`, so thresholds read `0.5`, not `0.500000`.
    public static func number(_ x: Double) -> String { String(format: "%g", x) }

    public static func compiled(_ c: CompiledRule) -> String {
        let parts = c.match.terms.map { term -> String in
            switch term {
            case .dimension(let d, let atLeast): return "\(d) ≥ \(number(atLeast))"
            case .kind(let k): return "kind *\(k.rawValue)*"
            }
        }
        let joiner: String
        if case .all = c.match { joiner = "and" } else { joiner = "or" }
        let lhs: String
        switch parts.count {
        case 0: lhs = "nothing"
        case 1: lhs = parts[0]
        case 2: lhs = "\(parts[0]) \(joiner) \(parts[1])"
        default: lhs = parts.dropLast().joined(separator: ", ") + ", \(joiner) " + parts[parts.count - 1]
        }
        var rhs = [c.assign.harness.rawValue, c.assign.model + (c.assign.modelDefaulted ? " (default model)" : "")]
        rhs += c.assign.knobs.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        rhs.append("pool \(c.assign.pool.rawValue)")
        if let fallback = c.assign.fallbackPool { rhs.append("else pool \(fallback.rawValue)") }
        return "matches \(lhs) → " + rhs.joined(separator: " · ")
    }
}
