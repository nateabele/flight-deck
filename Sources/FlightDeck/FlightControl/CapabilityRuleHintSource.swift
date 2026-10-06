import Foundation
import IntakeKit

/// L3-R's rule list asks "is there a better model for this rule?"; L3-I's index answers in its
/// own terms. This is the one translation: the rule's dimension terms become the dimensions to
/// compare, every enabled catalog model except the assigned one is a candidate, and the
/// largest-margin hint wins. The snapshot date rides along so a dismissed hint stays dismissed
/// only until the index moves.
struct CapabilityRuleHintSource: RuleHintSource {
    let scores: @Sendable () -> (scores: [ModelScores], snapshotDate: Date)?

    init(scores: @escaping @Sendable () -> (scores: [ModelScores], snapshotDate: Date)?) { self.scores = scores }

    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? {
        guard let current = scores(), let compiled = rule.compiled else { return nil }
        let dims = compiled.match.dimensionThresholds
        // A kind-only rule names no dimension, so there is nothing to compare models on.
        guard !dims.isEmpty else { return nil }
        let assigned = ModelRef(harness: compiled.assign.harness, model: compiled.assign.model,
                                knobs: compiled.assign.knobs)
        // The exclusion keeps the knobbed ref's identity: only the assigned model is dropped.
        // Other knob variants of it are never suggested, since "same model, other effort" is
        // not a better model.
        let candidates = catalogs.enabledModels.filter { $0.harness != assigned.harness || $0.model != assigned.model }
        // L3-I matches a knobbed ref to that exact scored variant only, and the index usually
        // scores a model bare or at another effort. Without a fallback a rule pinning
        // effort=high would never get a hint. When no row matches the exact variant, compare
        // from the bare model, which resolves to its best variant. That can overstate the
        // assigned score and so suppress some hints, the safer direction for a hint.
        let exact = current.scores.contains { CapabilityScoring.matches(candidate: assigned, scored: $0.model) }
        let compareFrom = exact ? assigned : ModelRef(harness: assigned.harness, model: assigned.model)
        guard let best = CapabilityHints.hints(for: dims, assigned: compareFrom, candidates: candidates,
                                               scores: current.scores).first else { return nil }
        // Bare: the index may have scored a knobbed variant, and "Switch to" re-validates the
        // rule's own effort against the new model rather than adopting the scored one.
        return RuleHint(ruleID: rule.id, text: best.message, snapshotDate: current.snapshotDate,
                        suggested: ModelRef(harness: best.better.harness, model: best.better.model))
    }
}

extension RuleMatch {
    /// The `{dimension, atLeast}` terms of an `any`/`all` match, flattened; kind terms are skipped.
    var dimensionThresholds: [String: Double] {
        var out: [String: Double] = [:]
        for term in terms { if case .dimension(let id, let atLeast) = term { out[id] = atLeast } }
        return out
    }
}
