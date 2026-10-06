import Foundation
import IntakeKit

/// Builds `[ModelScores]` from one line per (model, dimension) so a hint test reads as the
/// scores it pins, not as the nested initializers that carry them.
enum IndexTestScores {
    static func make(_ rows: [(ModelRef, String, Double, Double)]) -> [ModelScores] {
        var byModel: [ModelRef: [String: DimensionScore]] = [:]
        var order: [ModelRef] = []
        for (model, dimension, score, confidence) in rows {
            if byModel[model] == nil { order.append(model) }
            byModel[model, default: [:]][dimension] = DimensionScore(score: score, confidence: confidence)
        }
        return order.map { ModelScores(model: $0, dimensions: byModel[$0] ?? [:]) }
    }
}
