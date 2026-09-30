import Foundation

/// Maps text the phone selected back to its range in the Markdown source (spec §6.6).
///
/// The phone renders a plan into attributed text, so a `UITextView` selection is RENDERED text:
/// markers are gone (`**bold**` reads `bold`, a link reads as its label) and soft-wrapped lines
/// are reflowed. Searching the raw source for that string would miss every quote that crosses a
/// marker or a line break, so both sides are normalised the same way and the match is mapped
/// back through the source index each kept character remembers.
public enum RenderedQuoteLocator {
    /// The source range whose rendered text equals `rendered` (both normalised), or nil.
    public static func range(of rendered: String, within scope: Range<String.Index>, of markdown: String) -> Range<String.Index>? {
        let needle = normalise(rendered, from: rendered.startIndex..<rendered.endIndex, atLineStart: true).map(\.char)
        guard !needle.isEmpty else { return nil }
        let atLineStart = scope.lowerBound == markdown.startIndex
            || markdown[markdown.index(before: scope.lowerBound)].isNewline
        let kept = normalise(markdown, from: scope, atLineStart: atLineStart)
        guard kept.count >= needle.count else { return nil }

        for start in 0...(kept.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where kept[start + offset].char != needle[offset] {
                matched = false
                break
            }
            guard matched else { continue }
            let last = kept[start + needle.count - 1].index
            return kept[start].index..<markdown.index(after: last)
        }
        return nil
    }

    /// Drops inline markers, link syntax and heading prefixes, collapses whitespace runs to one
    /// space (indexed at the run's first character), and trims — remembering each kept
    /// character's source index.
    private static func normalise(_ text: String, from scope: Range<String.Index>, atLineStart: Bool)
        -> [(char: Character, index: String.Index)] {
        var kept: [(char: Character, index: String.Index)] = []
        var lineStart = atLineStart
        var i = scope.lowerBound
        while i < scope.upperBound {
            let c = text[i]
            if lineStart, c == "#" {
                var j = i
                while j < scope.upperBound, text[j] == "#" { j = text.index(after: j) }
                if j < scope.upperBound, text[j] == " " {
                    i = text.index(after: j)
                    lineStart = false
                    continue
                }
            }
            lineStart = false
            if c.isWhitespace {
                if c.isNewline { lineStart = true }
                var j = text.index(after: i)
                while j < scope.upperBound, text[j].isWhitespace {
                    if text[j].isNewline { lineStart = true }
                    j = text.index(after: j)
                }
                if !kept.isEmpty { kept.append((" ", i)) }
                i = j
                continue
            }
            if c == "]" {
                let next = text.index(after: i)
                if next < scope.upperBound, text[next] == "(",
                   let close = text[next..<scope.upperBound].firstIndex(of: ")") {
                    i = text.index(after: close)
                    continue
                }
            }
            if c == "[" || c == "*" || c == "_" || c == "`" {
                i = text.index(after: i)
                continue
            }
            kept.append((c, i))
            i = text.index(after: i)
        }
        if kept.last?.char == " " { kept.removeLast() }
        return kept
    }
}
