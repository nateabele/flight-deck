import Foundation

/// How well a query matches a name, as a tier rather than a score.
///
/// Shared with transcript hits, which always occupy the last tier — see `SearchRanker`.
/// `Comparable` on the raw value so "better" is `<`, which reads correctly at every call
/// site (`.exact < .fuzzy`).
public enum MatchTier: Int, Comparable, Sendable {
    case exact = 0
    case prefix = 1
    case fuzzy = 2
    case transcript = 3

    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One name's match, and where it matched.
public struct NameMatch: Equatable {
    public let tier: MatchTier
    /// Ranges into the *original* candidate, so the row can underline them without
    /// re-deriving anything from a lowercased copy.
    public let matchedRanges: [Range<String.Index>]
}

/// Fuzzy matching for session, project and conversation names.
///
/// This is the cheap half of search: a few hundred candidates, rescored on every keystroke
/// with no I/O, which is what lets name results update with no debounce at all while
/// transcript results wait 90 ms behind them.
///
/// **Why tiers instead of a score.** A single blended number has to answer "is an exact
/// match from March better than a fuzzy match from ten minutes ago" with a magic constant,
/// and every such constant is wrong for somebody. Tiering the *kind* of match and letting
/// recency order within a tier makes both halves explainable.
public enum NameMatcher {
    /// Below this length a subsequence match is meaningless — one or two characters appear
    /// in order inside almost any name, so fuzzy matching on the first keystroke would bury
    /// the exact and prefix hits under the entire fleet.
    private static let minimumFuzzyQueryLength = 3

    public static func score(_ candidate: String, against query: String) -> NameMatch? {
        let needle = query.lowercased()
        let haystack = candidate.lowercased()
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        if haystack == needle {
            return NameMatch(tier: .exact, matchedRanges: [candidate.startIndex..<candidate.endIndex])
        }
        if haystack.hasPrefix(needle) {
            let end = candidate.index(candidate.startIndex, offsetBy: needle.count)
            return NameMatch(tier: .prefix, matchedRanges: [candidate.startIndex..<end])
        }
        guard needle.count >= minimumFuzzyQueryLength,
              let ranges = subsequenceRanges(of: needle, in: haystack, mappedInto: candidate)
        else { return nil }

        return NameMatch(tier: .fuzzy, matchedRanges: ranges)
    }

    /// Greedy left-to-right subsequence walk: take the first occurrence of each query
    /// character at or after the previous one.
    ///
    /// Greedy is not optimal — it will not find the *tightest* run of matches — but it is
    /// linear, and the alternative (searching for the best alignment) buys a slightly nicer
    /// underline for real cost on every keystroke. Match/no-match is identical either way,
    /// which is what the tier depends on.
    ///
    /// `haystack` is the lowercased copy that is walked; `original` is what the returned
    /// ranges index into. Lowercasing can change length in general, so the two are walked in
    /// step rather than by offsetting into `original` afterwards.
    private static func subsequenceRanges(
        of needle: String, in haystack: String, mappedInto original: String
    ) -> [Range<String.Index>]? {
        var ranges: [Range<String.Index>] = []
        var hayIndex = haystack.startIndex
        var originalIndex = original.startIndex
        var needleIndex = needle.startIndex

        while needleIndex < needle.endIndex, hayIndex < haystack.endIndex {
            if haystack[hayIndex] == needle[needleIndex] {
                let next = original.index(after: originalIndex)
                // Extend the previous range when this character continues it, so an
                // adjacent run underlines as one span rather than as separate letters.
                if let last = ranges.last, last.upperBound == originalIndex {
                    ranges[ranges.count - 1] = last.lowerBound..<next
                } else {
                    ranges.append(originalIndex..<next)
                }
                needleIndex = needle.index(after: needleIndex)
            }
            hayIndex = haystack.index(after: hayIndex)
            // The walk advances two indices in lockstep over a string and its lowercased copy,
            // on the assumption that both have the same Character count. The guard is what makes
            // a violated assumption cost the remaining highlight rather than a trap: index(after:)
            // past endIndex is a crash, and returning the ranges built so far degrades to a
            // partial underline on a match that is still correct.
            guard originalIndex < original.endIndex else { break }
            originalIndex = original.index(after: originalIndex)
        }
        return needleIndex == needle.endIndex ? ranges : nil
    }
}
