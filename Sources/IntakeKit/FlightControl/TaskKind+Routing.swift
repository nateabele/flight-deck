import Foundation

extension TaskKind {
    /// False for a kind merged into another. Written once (R9) because the compiler prompt and
    /// later routing surfaces must agree: a condition on a merged kind would only ever match
    /// through its merge target, which should be named instead.
    public var isLive: Bool {
        if case .merged = status { return false }
        return true
    }

    /// The kind's dimension weights as `id 0.9, id 0.4`, sorted by id so a prompt is stable
    /// run to run, or `none` when it weighs nothing.
    public var weightsText: String {
        let parts = dimensions.sorted { $0.key < $1.key }.map { "\($0.key) \(RuleText.number($0.value))" }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
