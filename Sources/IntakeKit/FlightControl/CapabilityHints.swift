import Foundation

/// "opus scores 0.14 higher on test-authoring (confidence 0.8)": one dimension where a rule's
/// assigned model looks clearly weaker than another candidate. L3-R draws it on the rule;
/// it never changes routing — rules always win.
public struct CapabilityHint: Equatable, Sendable {
    public var dimension: String
    public var assigned: ModelRef
    public var assignedScore: Double
    public var better: ModelRef
    public var betterScore: Double
    /// The better model's confidence on this dimension.
    public var confidence: Double
    /// Source ids behind the better model's score, so the hint can say where it came from.
    public var sources: [String]

    public init(dimension: String, assigned: ModelRef, assignedScore: Double, better: ModelRef,
                betterScore: Double, confidence: Double, sources: [String]) {
        self.dimension = dimension; self.assigned = assigned; self.assignedScore = assignedScore
        self.better = better; self.betterScore = betterScore; self.confidence = confidence; self.sources = sources
    }

    public var margin: Double { betterScore - assignedScore }

    public var message: String {
        "\(better.model) scores \(String(format: "%.2f", margin)) higher on \(dimension) (confidence \(String(format: "%.1f", confidence)))"
    }
}

public enum CapabilityHints {
    public static let minimumMargin = 0.10
    public static let minimumConfidence = 0.6
    /// Float slack: 0.7 − 0.6 is 0.0999…98, and a margin the user reads as "0.10" must hint.
    static let epsilon = 1e-9

    /// Compares `assigned` with every candidate on each dimension the rule matches on.
    /// `ruleDimensions` is the rule's compiled `{dimension: atLeast}` terms; only the KEYS are
    /// used — the thresholds decide whether the rule matches a kind, not how good a model is.
    /// A dimension where the assigned model has no score is skipped: there is nothing to be
    /// weaker than. Largest margin first, then dimension, then candidate order.
    public static func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef],
                             scores: [ModelScores]) -> [CapabilityHint] {
        var found: [(order: Int, hint: CapabilityHint)] = []
        for d in ruleDimensions.keys.sorted() where Dimensions.isKnown(d) {
            guard let mine = CapabilityScoring.dimensionScore(assigned, d, in: scores) else { continue }
            for (i, candidate) in candidates.enumerated() {
                guard let theirs = CapabilityScoring.dimensionScore(candidate, d, in: scores),
                      theirs.model != mine.model,
                      theirs.score.score - mine.score.score >= minimumMargin - epsilon,
                      theirs.score.confidence >= minimumConfidence - epsilon,
                      !found.contains(where: { $0.hint.dimension == d && $0.hint.better == theirs.model }) else { continue }
                found.append((i, CapabilityHint(dimension: d, assigned: mine.model, assignedScore: mine.score.score,
                                          better: theirs.model, betterScore: theirs.score.score,
                                          confidence: theirs.score.confidence, sources: theirs.score.sources)))
            }
        }
        return found.sorted {
            if abs($0.hint.margin - $1.hint.margin) > epsilon { return $0.hint.margin > $1.hint.margin }
            if $0.hint.dimension != $1.hint.dimension { return $0.hint.dimension < $1.hint.dimension }
            return $0.order < $1.order
        }.map(\.hint)
    }
}

extension SnapshotCapabilityIndex {
    /// The call L3-R makes for each confirmed rule (L3-R §7). Not on the `CapabilityIndex`
    /// protocol: the contract is frozen, and only the index's owner needs to offer it.
    public func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] {
        CapabilityHints.hints(for: ruleDimensions, assigned: assigned, candidates: candidates, scores: scores)
    }
}
