import Foundation
import IntakeKit

/// One change a pill popover makes to a compiled rule (spec L3-R §2).
enum RuleAdjustment: Equatable {
    case setTerm(at: Int, MatchTerm)
    case addTerm(MatchTerm)
    case removeTerm(at: Int)
    case setMode(all: Bool)
    /// Another agent: its default model, its default pool, and the rule's knobs where it takes them.
    case setHarness(HarnessID)
    /// A model of the rule's agent; knobs the new model does not take are dropped.
    case setModel(String)
    /// nil removes the knob, which leaves the choice to the agent.
    case setKnob(String, String?)
    case setPool(PoolID)
    /// Agent and model together, for a hint's "Switch to …".
    case setTarget(ModelRef)
}

/// What the target popover may offer for one rule: only what the adapter and the pools declare,
/// so an invalid choice is never on screen to pick.
struct RuleTargetOptions: Equatable {
    var harnesses: [HarnessID]
    var models: [ModelEntry]
    /// Knob → allowed values, for the knobs the rule's model takes.
    var knobs: [String: [String]]
    var pools: [PoolSummary]
}

extension RoutingService {
    // MARK: - Adding and rewording

    /// Return in a "New rule…" field: add the rule and start compiling it at once. There is no
    /// Compile button, so a rule that waited for one would sit as a draft nobody asked for.
    /// Confirming stays a separate click (Use): only confirmed rules route.
    @discardableResult
    func submitNewRule(_ sentence: String, to scope: RuleScope) -> String? {
        guard let id = addRule(sentence, to: scope) else { return nil }
        startCompile(id, in: scope)
        return id
    }

    /// Return in the inline sentence editor. New words go back to draft and compile at once,
    /// which also drops any pill adjustments. The same words recompile only a rule that has no
    /// compiled form; on a live rule they change nothing, so an idle Return cannot un-Use it.
    func reword(_ id: String, _ sentence: String, in scope: RuleScope) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rule = rules(scope).first(where: { $0.id == id }) else { return }
        if trimmed != rule.sentence {
            editSentence(id, trimmed, in: scope)
            if !startCompile(id, in: scope) { recompileWhenDone.insert(id) }
        } else if rule.state == .draft || rule.state == .failed {
            startCompile(id, in: scope)
        }
    }

    /// Context menu "Recompile from Sentence": throw the pill adjustments away and compile the
    /// words again. The result waits for Use like any fresh compile.
    func revertToSentence(_ id: String, in scope: RuleScope) {
        startCompile(id, in: scope)
    }

    // MARK: - Pill adjustments

    /// Applies a popover change to a compiled or live rule and returns nil, or returns why it was
    /// refused and leaves the rule untouched. The result goes through `RuleValidator` exactly as
    /// a compiler answer does, so a popover cannot save a rule the compile path would refuse.
    ///
    /// The rule keeps its state (a live rule stays live: the user is tuning it, not starting
    /// over) and is marked `adjusted`, because its pills no longer match its words.
    @discardableResult
    func adjust(_ id: String, in scope: RuleScope, _ change: RuleAdjustment) -> String? {
        guard !compiling.contains(id) else { return "the rule is compiling" }
        guard let rule = rules(scope).first(where: { $0.id == id }), let current = rule.compiled,
              rule.state == .compiled || rule.state == .confirmed else {
            return "only a compiled rule can be adjusted"
        }
        let catalogs = lastCatalogs
        let defaults = defaultPools(catalogs)
        let proposed = Self.applying(change, to: current, catalogs: catalogs, defaultPools: defaults)
        let input = RuleCompilerInput(sentence: rule.sentence, kinds: kinds(for: scope), catalogs: catalogs,
                                      pools: pools.pools(), defaultPools: defaults)
        let validated: CompiledRule
        switch RuleValidator.validate(Self.wire(proposed), input: input) {
        case .failure(let error): return error.message
        case .success(let c): validated = c
        }
        guard validated != current else { return nil }
        mutate(scope) { rules in
            // Re-read under the write: a compile that finished in between owns the rule now.
            guard let i = rules.firstIndex(where: { $0.id == id }), rules[i].compiled == current else { return }
            rules[i].compiled = validated
            rules[i].adjusted = true
        }
        return nil
    }

    /// The hint popover's "Switch to …".
    @discardableResult
    func applyHint(_ hint: RuleHint, in scope: RuleScope) -> String? {
        guard let target = hint.suggested else { return "the hint names no model" }
        return adjust(hint.ruleID, in: scope, .setTarget(target))
    }

    func targetOptions(for assign: RuleAssign) -> RuleTargetOptions {
        let catalogs = lastCatalogs
        let harnesses = catalogs.order.filter { catalogs.byHarness[$0]?.enabled == true }
        let catalog = catalogs.byHarness[assign.harness]
        let models = catalog?.models ?? []
        var knobs: [String: [String]] = [:]
        if let catalog, let entry = models.first(where: { $0.id == assign.model }) {
            for k in entry.knobs { if let values = catalog.knobSchema[k], !values.isEmpty { knobs[k] = values } }
        }
        return RuleTargetOptions(harnesses: harnesses, models: models, knobs: knobs,
                                 pools: pools.pools().filter { $0.harness == assign.harness })
    }

    // MARK: - Pure helpers

    static func applying(_ change: RuleAdjustment, to rule: CompiledRule, catalogs: AdapterCatalogs,
                         defaultPools: [HarnessID: PoolID]) -> CompiledRule {
        var out = rule
        var terms = rule.match.terms
        var all: Bool
        if case .all = rule.match { all = true } else { all = false }

        func retarget(harness: HarnessID, model: String?) {
            var a = out.assign
            if harness != a.harness {
                a.harness = harness
                a.pool = defaultPools[harness] ?? PoolID("")
                if a.fallbackPool == a.pool { a.fallbackPool = nil }
            }
            if let model {
                a.model = model
            } else if let catalog = catalogs.byHarness[harness] {
                a.model = catalog.defaultModel ?? catalog.models.first?.id ?? ""
            }
            // Keep only what the new model takes, so an effort carried across does not fail
            // validation on a model that declares none.
            a.knobs = a.knobs.filter { catalogs.knobsValid(ModelRef(harness: harness, model: a.model, knobs: [$0.key: $0.value])) }
            out.assign = a
        }

        switch change {
        case .setTerm(let i, let term):
            if terms.indices.contains(i) { terms[i] = term }
        case .addTerm(let term):
            if !terms.contains(term) { terms.append(term) }
        case .removeTerm(let i):
            if terms.indices.contains(i) { terms.remove(at: i) }
        case .setMode(let a):
            all = a
        case .setHarness(let h):
            retarget(harness: h, model: nil)
        case .setModel(let m):
            retarget(harness: rule.assign.harness, model: m)
        case .setKnob(let k, let v):
            out.assign.knobs[k] = v
        case .setPool(let p):
            out.assign.pool = p
            if out.assign.fallbackPool == p { out.assign.fallbackPool = nil }
        case .setTarget(let ref):
            retarget(harness: ref.harness, model: ref.model)
        }
        out.match = all ? .all(terms) : .any(terms)
        // The compiled text says "(default model)" only while the compiler's own default is
        // what routes. Once the user picks a target, it is their choice, not a silent default.
        out.assign.modelDefaulted = rule.assign.modelDefaulted
            && out.assign.harness == rule.assign.harness && out.assign.model == rule.assign.model
        return out
    }

    /// A compiled rule back in the compiler's answer shape, so the one validator checks it.
    static func wire(_ c: CompiledRule) -> RuleCompilerWire {
        let mode: String
        if case .all = c.match { mode = "all" } else { mode = "any" }
        let terms = c.match.terms.map { term -> RuleCompilerWire.Term in
            switch term {
            case .dimension(let d, let atLeast): return .init(dimension: d, atLeast: atLeast, kind: nil)
            case .kind(let k): return .init(dimension: nil, atLeast: nil, kind: k.rawValue)
            }
        }
        return RuleCompilerWire(ok: true, reason: nil, mode: mode, terms: terms, harness: c.assign.harness.rawValue,
                                model: c.assign.model, modelDefaulted: c.assign.modelDefaulted,
                                knobs: c.assign.knobs.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) },
                                pool: c.assign.pool.rawValue, fallbackPool: c.assign.fallbackPool?.rawValue)
    }
}
