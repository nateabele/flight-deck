import Foundation

/// The compiler's raw answer, in the strict shape `RuleCompilerPrompt.schemaJSON` forces. Flat
/// and nullable because strict-mode schemas cannot express "one of two term shapes" or an
/// open-keyed knob object; `RuleValidator` turns it into a `CompiledRule`.
public struct RuleCompilerWire: Codable, Equatable, Sendable {
    public struct Term: Codable, Equatable, Sendable {
        public var dimension: String?
        public var atLeast: Double?
        public var kind: String?
        public init(dimension: String?, atLeast: Double?, kind: String?) {
            self.dimension = dimension; self.atLeast = atLeast; self.kind = kind
        }
    }
    public struct Knob: Codable, Equatable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public var ok: Bool
    public var reason: String?
    public var mode: String
    public var terms: [Term]
    public var harness: String?
    public var model: String?
    public var modelDefaulted: Bool
    public var knobs: [Knob]
    public var pool: String?
    public var fallbackPool: String?

    public init(ok: Bool, reason: String?, mode: String, terms: [Term], harness: String?, model: String?,
                modelDefaulted: Bool, knobs: [Knob], pool: String?, fallbackPool: String?) {
        self.ok = ok; self.reason = reason; self.mode = mode; self.terms = terms; self.harness = harness
        self.model = model; self.modelDefaulted = modelDefaulted; self.knobs = knobs; self.pool = pool
        self.fallbackPool = fallbackPool
    }
}

/// Everything the compiler is told and the validator checks against (spec §3).
public struct RuleCompilerInput: Equatable, Sendable {
    public var sentence: String
    public var kinds: [TaskKind]
    public var catalogs: AdapterCatalogs
    public var pools: [PoolSummary]
    public var defaultPools: [HarnessID: PoolID]
    public init(sentence: String, kinds: [TaskKind], catalogs: AdapterCatalogs, pools: [PoolSummary],
                defaultPools: [HarnessID: PoolID]) {
        self.sentence = sentence; self.kinds = kinds; self.catalogs = catalogs; self.pools = pools
        self.defaultPools = defaultPools
    }
}

public enum RuleValidationError: Error, Equatable, Sendable {
    case declined(String)
    case malformedTerm
    case unknownDimension(String)
    case thresholdOutOfRange(String)
    case unknownKind(String)
    case emptyMatch
    case unknownMode(String)
    case missingHarness
    case unknownHarness(String)
    case harnessDisabled(String)
    case noDefaultModel(String)
    case unknownModel(String, String)
    case knobRejected(String, String, String, String)
    case noPool(String)
    case unknownPool(String)
    case poolBelongsElsewhere(String, owner: String, harness: String)
    case fallbackIsPrimary(String)

    /// Shown inline under a failed rule (spec §2: "failed (shown inline with the reason)").
    public var message: String {
        switch self {
        case .declined(let why): return why
        case .malformedTerm: return "a condition names neither one dimension nor one kind"
        case .unknownDimension(let d): return "unknown dimension \(d)"
        case .thresholdOutOfRange(let d): return "\(d) needs a threshold between 0 and 1"
        case .unknownKind(let k): return "unknown task kind \(k)"
        case .emptyMatch: return "the rule has no conditions"
        case .unknownMode(let m): return "unknown match mode \(m)"
        case .missingHarness: return "the rule names no agent"
        case .unknownHarness(let h): return "\(h) is not a registered agent"
        case .harnessDisabled(let h): return "\(h) is not enabled"
        case .noDefaultModel(let h): return "\(h) has no default model to fall back to"
        case .unknownModel(let h, let m): return "\(m) is not in \(h)'s model list"
        case .knobRejected(let h, let m, let k, let v): return "\(h) · \(m) does not accept \(k) \(v)"
        case .noPool(let h): return "\(h) has no pool"
        case .unknownPool(let p): return "unknown pool \(p)"
        case .poolBelongsElsewhere(let p, let owner, let h): return "pool \(p) belongs to \(owner), not \(h)"
        case .fallbackIsPrimary(let p): return "the fallback pool \(p) is the rule's own pool"
        }
    }
}

/// Checks a compiler answer against the dimensions, the project's kinds, the registered
/// adapters' catalogs and knob schemas, and the pools (spec §3). The first error wins: the rule
/// shows one reason, and fixing it and recompiling is the loop, not a wall of errors.
public enum RuleValidator {
    public static func validate(_ w: RuleCompilerWire, input: RuleCompilerInput) -> Result<CompiledRule, RuleValidationError> {
        guard w.ok else { return .failure(.declined(w.reason ?? "the compiler could not read this sentence as a rule")) }

        var terms: [MatchTerm] = []
        for t in w.terms {
            switch (t.dimension, t.kind) {
            case (let d?, nil):
                guard Dimensions.isKnown(d) else { return .failure(.unknownDimension(d)) }
                guard let atLeast = t.atLeast, (0...1).contains(atLeast) else { return .failure(.thresholdOutOfRange(d)) }
                terms.append(.dimension(d, atLeast: atLeast))
            case (nil, let k?):
                guard input.kinds.contains(where: { $0.id.rawValue == k }) else { return .failure(.unknownKind(k)) }
                terms.append(.kind(KindID(k)))
            default:
                return .failure(.malformedTerm)
            }
        }
        guard !terms.isEmpty else { return .failure(.emptyMatch) }
        let match: RuleMatch
        switch w.mode {
        case "any": match = .any(terms)
        case "all": match = .all(terms)
        default: return .failure(.unknownMode(w.mode))
        }

        guard let harnessName = w.harness, !harnessName.isEmpty else { return .failure(.missingHarness) }
        let harness = HarnessID(harnessName)
        guard let catalog = input.catalogs.byHarness[harness] else { return .failure(.unknownHarness(harnessName)) }
        guard catalog.enabled else { return .failure(.harnessDisabled(harnessName)) }

        var defaulted = w.modelDefaulted
        var modelName = w.model
        if modelName?.isEmpty ?? true {
            modelName = catalog.defaultModel
            defaulted = true
        }
        guard let model = modelName else { return .failure(.noDefaultModel(harnessName)) }
        guard catalog.models.contains(where: { $0.id == model }) else { return .failure(.unknownModel(harnessName, model)) }

        var knobs: [String: String] = [:]
        for k in w.knobs { knobs[k.name] = k.value }
        for (k, v) in knobs.sorted(by: { $0.key < $1.key })
        where !input.catalogs.knobsValid(ModelRef(harness: harness, model: model, knobs: [k: v])) {
            return .failure(.knobRejected(harnessName, model, k, v))
        }

        let pool: PoolID
        if let p = w.pool, !p.isEmpty {
            guard let summary = input.pools.first(where: { $0.id.rawValue == p }) else { return .failure(.unknownPool(p)) }
            guard summary.harness == harness else {
                return .failure(.poolBelongsElsewhere(p, owner: summary.harness.rawValue, harness: harnessName))
            }
            pool = summary.id
        } else {
            guard let d = input.defaultPools[harness] else { return .failure(.noPool(harnessName)) }
            pool = d
        }

        var fallback: PoolID?
        if let f = w.fallbackPool, !f.isEmpty {
            guard input.pools.contains(where: { $0.id.rawValue == f }) else { return .failure(.unknownPool(f)) }
            guard f != pool.rawValue else { return .failure(.fallbackIsPrimary(f)) }
            fallback = PoolID(f)
        }

        return .success(CompiledRule(match: match, assign: RuleAssign(harness: harness, model: model, knobs: knobs, pool: pool,
                                                                      fallbackPool: fallback, modelDefaulted: defaulted)))
    }
}
