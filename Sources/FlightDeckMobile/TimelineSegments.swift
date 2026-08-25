import Foundation

/// One run of a prose body, split by what can and cannot be an `NSAttributedString`.
///
/// **The split exists because selection does.** A `UITextView` is the only view that can hand a
/// custom edit-menu action the range it was invoked on, and a `UITextView` renders attributed
/// text — so everything that survives as attributed text becomes selectable, and everything
/// that does not keeps MarkdownUI and stays press-to-copy. That boundary is not a style
/// preference; it is the list of things an attributed run cannot express.
enum TimelineSegment: Equatable {
    /// Paragraphs, headings, emphasis, links, inline code. Becomes the selectable text view.
    case prose(String)
    /// A fenced block, carrying its contents **without the fences** — that is what a reader
    /// copying it wants, and the press-to-copy block takes plain text.
    case code(language: String?, String)
    /// A table, a list or a blockquote: markdown that MarkdownUI draws as views and an
    /// attributed string has no run for. Carries its raw markdown, because MarkdownUI is what
    /// renders it.
    case richBlock(String)

    /// The text this segment shows. For `.code` that is the contents; for the other two it is
    /// the markdown source, which is also what they render from.
    var text: String {
        switch self {
        case .prose(let text), .richBlock(let text): return text
        case .code(_, let text): return text
        }
    }

    /// A `.code` segment put back into markdown source, so MarkdownUI can render it with the
    /// very fill and font the same block had before it was split out.
    ///
    /// **The fence is as long as it needs to be.** Three backticks would end the block early on
    /// contents that contain a fence of their own — which is exactly what a message about
    /// markdown looks like — so the opening run is one longer than the longest run inside.
    static func fenced(language: String?, _ contents: String) -> String {
        var longest = 0
        var run = 0
        for character in contents {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + (language ?? "") + "\n" + contents + "\n" + fence
    }

    /// Whether this segment is the selectable kind. One place to ask, so a fourth kind added
    /// later cannot become silently selectable by defaulting into the wrong arm of a `switch`.
    var isSelectable: Bool {
        if case .prose = self { return true }
        return false
    }
}

/// Splitting a body into segments, and spending a line budget across them.
///
/// **Line-based, not a Markdown parse.** The only decisions here are which lines start a fenced
/// block, a list, a table or a quote — every other construct is prose, and prose is handed on
/// as markdown source for something else to render. A real block parser would be more correct
/// about pathological input and would also mean carrying a second Markdown implementation
/// beside MarkdownUI, which is the thing this file exists to avoid.
enum TimelineSegmenter {

    /// What a row draws: the segments it shows, and whether anything was held back.
    ///
    /// **`hasMore` is the walk's own answer, not an inference from a line count.** It used to be
    /// safe to infer: `TimelineStyle.exceeds` decided *whether* to clamp and
    /// `TimelineStyle.firstLines` decided *where*, they counted the same lines, and so a body
    /// called over-ceiling was always cut strictly shorter than itself. The overshoot rule below
    /// breaks that agreement in one case — a fenced block that runs to the end of the message —
    /// and an inferred `hasMore` would draw a More link there with nothing behind it. That is
    /// the exact defect `firstLines` was written to prevent, so the answer moves to where it can
    /// still be told the truth.
    struct Clamped: Equatable {
        var segments: [TimelineSegment]
        var hasMore: Bool
    }

    /// Split `text` whole, spending no budget. What an expanded row draws.
    static func segments(of text: String) -> [TimelineSegment] {
        clamp(text, budget: nil).segments
    }

    /// Split `text`, stopping once `budget` lines are spent.
    ///
    /// **A fenced or rich block that starts inside the budget is drawn whole**, overshooting by
    /// whatever it costs. The alternative is a visibly cut panel — half a code block with no
    /// closing edge — and a panel that lies about where the code ends is worse than a row that
    /// runs long. Prose is still cut mid-line and mid-word, which is the older decision and
    /// still the right one: a row that ends on a whole line looks finished.
    ///
    /// **The walk is bounded by the budget, not by the body**, so a 64 KB paste costs a
    /// collapsed row no more than a short answer does — with the one exception the overshoot
    /// buys, a single block read to its end. `budget: nil` means draw everything and is the
    /// expanded row, which has asked for exactly that.
    static func clamp(_ text: String, budget: Int?, columns: Int = TimelineStyle.proseColumns) -> Clamped {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var segments: [TimelineSegment] = []
        var remaining = budget
        var index = 0
        var cut = false

        while index < lines.count {
            if let left = remaining, left <= 0 { break }

            if let fence = Fence(lines[index]) {
                let (block, next) = fence.consume(lines, from: index)
                index = next
                if !block.contents.isEmpty || block.language != nil {
                    segments.append(.code(language: block.language, block.contents))
                }
                remaining = spend(block.rawLineCount(columns: columns, cap: remaining), from: remaining)
            } else if isRichStart(lines[index]) {
                let (raw, next) = consumeRich(lines, from: index)
                index = next
                segments.append(.richBlock(raw))
                remaining = spend(countLines(raw, columns: columns, cap: remaining), from: remaining)
            } else {
                let (raw, next) = consumeProse(lines, from: index)
                index = next
                let trimmed = trimBlankLines(raw)
                guard !trimmed.isEmpty else { continue }
                let cost = countLines(trimmed, columns: columns, cap: remaining)
                if let left = remaining, cost > left {
                    let kept = TimelineStyle.firstLines(left, of: trimmed, columns: columns)
                    if !kept.isEmpty { segments.append(.prose(kept)) }
                    cut = kept.count < trimmed.count
                    remaining = 0
                    break
                }
                segments.append(.prose(trimmed))
                remaining = spend(cost, from: remaining)
            }
        }

        // Everything after `index` is unrendered. Blank lines are not content, so a body whose
        // remainder is only whitespace was in fact drawn whole — this is the case that decides
        // whether a message ending on an overshooting code block gets a More link. It does not.
        let restHasContent = lines[index...].contains { !$0.allSatisfy(\.isWhitespace) }
        return Clamped(segments: segments, hasMore: cut || restHasContent)
    }

    private static func spend(_ cost: Int, from remaining: Int?) -> Int? {
        guard let remaining else { return nil }
        return max(0, remaining - cost)
    }

    // MARK: Block boundaries

    /// A fenced block's opening line: three or more backticks or tildes, indented no more than
    /// three spaces, with an optional info string. The closing fence must use the same
    /// character and be at least as long, which is what lets a ```` ``` ```` sit inside a
    /// ```` ```` ```` block.
    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?

        init?(_ line: Substring) {
            let body = line.drop { $0 == " " }
            guard line.count - body.count <= 3,
                  let first = body.first, first == "`" || first == "~" else { return nil }
            let run = body.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A backtick fence may not carry a backtick in its info string; that is an inline
            // code span being mistaken for a fence.
            if first == "`" && info.contains("`") { return nil }
            marker = first
            length = run.count
            language = info.isEmpty ? nil : String(info.split(separator: " ").first ?? "")
        }

        func closes(_ line: Substring) -> Bool {
            let body = line.drop { $0 == " " }
            guard line.count - body.count <= 3 else { return false }
            let run = body.prefix { $0 == marker }
            return run.count >= length && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
        }

        /// The block's contents and the line after it. **An unclosed fence runs to the end of
        /// the body** rather than being reinterpreted as prose: a fence that opened is a fence,
        /// and the alternative renders a half-written code block as a wall of markdown.
        func consume(_ lines: [Substring], from start: Int) -> (block: Block, next: Int) {
            var index = start + 1
            var contents: [Substring] = []
            while index < lines.count {
                if closes(lines[index]) { index += 1; break }
                contents.append(lines[index])
                index += 1
            }
            return (Block(language: language, lines: contents, fenceLines: index - start - contents.count), index)
        }

        struct Block {
            let language: String?
            let lines: [Substring]
            /// One for the opening fence, plus one for a closing fence that was present.
            let fenceLines: Int

            var contents: String { trimBlankLines(lines.joined(separator: "\n")) }

            /// The cost of the block as the reader sees it, fences included — the same lines
            /// `TimelineStyle.exceeds` would have counted over the raw body.
            func rawLineCount(columns: Int, cap: Int?) -> Int {
                fenceLines + countLines(lines.joined(separator: "\n"), columns: columns, cap: cap)
            }
        }
    }

    /// A list bullet, an ordered item, a blockquote, or a table row — the block kinds MarkdownUI
    /// draws as views. Indented up to three spaces, like every other block start.
    private static func isRichStart(_ line: Substring) -> Bool {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3, let first = body.first else { return false }
        if first == ">" || first == "|" { return true }
        if first == "-" || first == "*" || first == "+" {
            // A bullet needs a space after it; `**bold**` and a `---` rule are not lists.
            return body.dropFirst().first == " "
        }
        if first.isNumber {
            let digits = body.prefix(while: \.isNumber)
            let rest = body.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
            return rest.dropFirst().first == " "
        }
        return false
    }

    /// A run of rich-block lines, including the blank lines *inside* it — a loose list is one
    /// list, and splitting it at its own paragraph breaks would draw each item as a table of
    /// one. A blank line ends the run only when what follows is not more of the same block.
    private static func consumeRich(_ lines: [Substring], from start: Int) -> (String, Int) {
        var index = start
        var end = start
        while index < lines.count {
            let line = lines[index]
            if line.allSatisfy(\.isWhitespace) {
                // Look past the blank run: more rich lines continue the block, anything else
                // ends it.
                var probe = index
                while probe < lines.count, lines[probe].allSatisfy(\.isWhitespace) { probe += 1 }
                guard probe < lines.count, isRichStart(lines[probe]) else { break }
                index = probe
                continue
            }
            if Fence(line) != nil { break }
            // A non-blank line that is neither a new rich start nor a fence is a lazy
            // continuation of the item above it, and belongs to this block.
            index += 1
            end = index
        }
        return (lines[start..<end].joined(separator: "\n"), end)
    }

    /// Everything up to the next block start. Prose is the default, so this is the arm that
    /// runs for most of most messages.
    private static func consumeProse(_ lines: [Substring], from start: Int) -> (String, Int) {
        var index = start
        while index < lines.count {
            if Fence(lines[index]) != nil || isRichStart(lines[index]) { break }
            index += 1
        }
        return (lines[start..<index].joined(separator: "\n"), index)
    }

    // MARK: Counting

    /// Lines in the prose column — hard breaks plus wraps — counted exactly as
    /// `TimelineStyle.exceeds` counts them, and stopping at `cap` so the walk stays bounded by
    /// the budget rather than by the body.
    static func lineCount(_ text: String, columns: Int = TimelineStyle.proseColumns, cap: Int? = nil) -> Int {
        countLines(text, columns: columns, cap: cap)
    }
}

/// A segment's own text, without the blank lines that separated it from its neighbours.
///
/// **Both ends, and the leading end is the one that bites.** A block separator is a blank line,
/// so the prose run after a fenced block starts with one; handed on it would open the segment
/// with a newline MarkdownUI has no use for, and cost a line of the budget to say nothing. The
/// gaps between segments are drawn by `markdownMargin`, not by the source.
private func trimBlankLines(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
    while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
    return lines.joined(separator: "\n")
}

private func countLines(_ text: String, columns: Int, cap: Int?) -> Int {
    guard !text.isEmpty else { return 0 }
    var lines = 1
    var column = 0
    for character in text {
        if character == "\n" {
            lines += 1
            column = 0
        } else {
            column += 1
            if column > columns {
                lines += 1
                column = 1
            }
        }
        if let cap, lines > cap { return lines }
    }
    return lines
}
