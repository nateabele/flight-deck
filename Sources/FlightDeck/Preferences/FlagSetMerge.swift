import Foundation

/// Combines a project's override with the global defaults, per flag.
///
/// Key *presence* is the override signal: an absent key inherits, while a present key —
/// even one holding an empty list — overrides. That is why `FlagSet.values` never uses a
/// sentinel "unset" value.
enum FlagSetMerge {
    static func merge(global: FlagSet, project: FlagSet) -> FlagSet {
        var merged = global
        for (key, value) in project.values {
            merged.values[key] = value
        }
        // Passthrough is unkeyed, so it cannot merge per-flag. Both tails are kept,
        // global first, and `claude`'s own last-wins parsing resolves any overlap.
        merged.passthrough = global.passthrough + project.passthrough
        return merged
    }
}
