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

    /// The inverse of `merge`: given a merged set the user edited and the globals it was
    /// merged from, recover the project's own overrides. A key whose value equals the
    /// inherited one is dropped, so it keeps inheriting rather than becoming a redundant
    /// explicit override.
    ///
    /// `passthrough` is unkeyed, so it is recovered by multiset difference — which handles
    /// insertion and reordering without duplicating a token, unlike a prefix strip.
    static func unmerge(merged: FlagSet, inherited: FlagSet) -> FlagSet {
        var overrides = FlagSet()
        for (key, value) in merged.values where inherited.values[key] != value {
            overrides.values[key] = value
        }
        overrides.passthrough = passthroughDifference(merged: merged.passthrough, inherited: inherited.passthrough)
        return overrides
    }

    /// Recovers the project's own passthrough tokens from the merged passthrough, as a
    /// multiset difference: each token in `merged` that can still be matched against an
    /// unconsumed copy in `inherited` is attributed to the global and dropped; everything
    /// left over is the project's own. This handles the common edit shape correctly — the
    /// serializer emits passthrough *first*, so "type a new unknown flag at the start of the
    /// field" is the natural way to add one, and a plain prefix-strip would see the inserted
    /// token break the prefix match and misattribute the whole run, duplicating the inherited
    /// tokens into the override every time. A multiset diff tolerates insertion, deletion, and
    /// reordering of individual tokens without ever duplicating one.
    private static func passthroughDifference(merged: [String], inherited: [String]) -> [String] {
        var remaining = inherited
        var project: [String] = []
        for token in merged {
            if let index = remaining.firstIndex(of: token) {
                remaining.remove(at: index)
            } else {
                project.append(token)
            }
        }
        return project
    }
}
