import Foundation

/// A plan, split into the units a reader can pin a comment to.
///
/// **In `FleetKit` for `OpenPrompt`'s reason.** The phone decides what to draw a tap target
/// around and the Mac decides what `originalText` to POST to Plannotator. Two implementations
/// of this rule is how a comment detaches from the phrase it was written about — silently,
/// because Plannotator falls back to sidebar-only when a substring does not match.
///
/// **The rule was measured, not chosen.** Over 120 archived plans in `~/.plannotator/plans/`
/// (6,442 blocks): 229 thematic breaks, 109 further non-unique blocks (1.7%), leaving 94.8%
/// tappable at a median of 77 characters. Splitting list items individually beat keeping a
/// list whole on both axes — 4.9% non-unique against 6.5%, at finer granularity — which is why
/// the list rule is here despite adding a case.
public struct PlanBlocks: Equatable, Sendable {

    /// One annotatable unit.
    ///
    /// `text` is **verbatim source**, never trimmed or re-wrapped: Plannotator matches it as a
    /// substring of the plan, so any normalisation here is a comment that does not pin.
    public struct Block: Equatable, Sendable {
        public let index: Int
        public let text: String
        /// Whether a comment may be pinned here. A non-target still renders — it just takes no
        /// tap, and anything a reader wants to say about it goes in a global comment.
        public let isTarget: Bool

        public init(index: Int, text: String, isTarget: Bool) {
            self.index = index
            self.text = text
            self.isTarget = isTarget
        }
    }

    public let blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    /// Bounds-checked, because the caller is a wire command. A phone naming a block this plan
    /// does not have is refused, not clamped.
    public func block(at index: Int) -> Block? {
        guard blocks.indices.contains(index) else { return nil }
        return blocks[index]
    }

    public static func split(_ plan: String) -> PlanBlocks {
        var raw: [String] = []
        var current: [String] = []
        var inFence = false

        func flush() {
            guard !current.isEmpty else { return }
            raw.append(current.joined(separator: "\n"))
            current.removeAll()
        }

        let lines = plan
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for line in lines {
            // A fence's own blank lines are not separators, and the closing fence ends the
            // block — otherwise the prose after it joins the code.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                current.append(line)
                if !inFence { flush() }
                continue
            }
            if inFence { current.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if isListItem(line) { flush(); current.append(line); continue }
            current.append(line)
        }
        flush()

        let blocks = raw.enumerated().map { index, text in
            Block(
                index: index,
                text: text,
                isTarget: !isThematicBreak(text)
                    && occurrences(of: text, in: plan, stoppingAt: 2) == 1
            )
        }
        return PlanBlocks(blocks: blocks)
    }

    /// Counts occurrences, stopping once `limit` is reached.
    ///
    /// The early stop is the point: every caller only asks "exactly one, or more than one?",
    /// and a full count over a 6 KB plan for each of 39 blocks would be work done to be
    /// thrown away.
    static func occurrences(of needle: String, in haystack: String, stoppingAt limit: Int) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            if count >= limit { return count }
            searchStart = found.lowerBound < found.upperBound
                ? found.upperBound
                : haystack.index(after: found.lowerBound)
        }
        return count
    }

    /// `- `, `* `, `+ `, `1. `, `1) ` — the marker must be followed by a space, so `---` is a
    /// thematic break and not a list item with an empty label.
    static func isListItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            return rest.dropFirst().first == " "
        }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        rest = rest.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// Three or more of one of `-`, `*`, `_`, and nothing else.
    static func isThematicBreak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_"
        else { return false }
        return trimmed.allSatisfy { $0 == first }
    }
}
