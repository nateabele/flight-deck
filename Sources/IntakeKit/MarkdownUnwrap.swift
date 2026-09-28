import Foundation

/// Joins soft-wrapped Markdown back into one line per paragraph, list item and blockquote
/// paragraph. The seats hard-wrap plan prose at ~80–100 columns out of habit, and a wrapped
/// paragraph is miserable to edit in the plan editor: the editor soft-wraps it again at ITS
/// width, so every edit leaves ragged half-lines and breaks mid-sentence. The rendered Markdown
/// is identical either way — a single newline inside a paragraph is only a space — so joining
/// loses nothing.
///
/// Only a soft wrap is joined. Everything whose line breaks mean something is copied as is:
/// front matter, fenced and indented code, tables, headings (ATX and setext), thematic breaks,
/// HTML blocks, link reference definitions, hard breaks (two trailing spaces or a trailing
/// backslash), list item boundaries, nested lists, blank lines, and a change of blockquote
/// depth. When a line is ambiguous the rule is "leave the break": a break left in costs a
/// ragged line, a break wrongly joined can change what the document means.
///
/// Idempotent (a joined line is classified by its first segment's start and its last
/// segment's end, exactly as the lines were before), line endings are kept (CRLF in, CRLF
/// out), and a line that is not joined is not otherwise touched.
public enum MarkdownUnwrap {
    public static func unwrap(_ text: String) -> String {
        // Scalars, not Characters: "\r\n" is ONE Character, so a Character search for "\n"
        // misses every line break of a CRLF plan.
        guard text.unicodeScalars.contains("\n") else { return text }
        let newline = text.unicodeScalars.contains("\r") ? "\r\n" : "\n"
        let lines = planLines(text).map(String.init)
        var out: [String] = []
        out.reserveCapacity(lines.count)

        var start = 0
        if let end = frontMatterEnd(lines) {
            out.append(contentsOf: lines[...end])
            start = end + 1
        }
        let tableRows = tableLines(lines)

        var fence: Fence?
        var html: HTMLEnd?
        var indentedCode = false
        var previousBlank = true
        /// The content column of the most recent list item — an indented line under it is the
        /// item's own content, not an indented code block, until something at the margin ends
        /// the list.
        var listColumn: Int?
        /// The output line the next line may join onto, and the blockquote depth it sits at.
        var open: (index: Int, depth: Int)?

        for i in lines.indices where i >= start {
            let line = lines[i]
            let (depth, content) = quoted(line)

            if let f = fence {
                out.append(line)
                if f.isClosed(by: content) { fence = nil }
                previousBlank = false
                continue
            }
            if let end = html {
                out.append(line)
                switch end {
                case .blankLine where isBlank(content): html = nil; previousBlank = true
                case .marker(let m) where line.contains(m): html = nil; previousBlank = false
                default: break
                }
                continue
            }
            if isBlank(content) {
                out.append(line)
                open = nil
                previousBlank = true
                continue
            }

            let indent = columns(content)
            let body = content.drop { $0 == " " || $0 == "\t" }
            let afterBlank = previousBlank
            previousBlank = false

            let codeColumn = (listColumn ?? 0) + 4
            if indentedCode, indent >= codeColumn { out.append(line); continue }
            indentedCode = false
            if open == nil, afterBlank, indent >= codeColumn {
                indentedCode = true
                out.append(line)
                continue
            }

            let item = listItem(body)
            if afterBlank, indent == 0, item == nil { listColumn = nil }

            // Lines that are never joined, onto or from.
            if let f = Fence(opening: body) {
                fence = f
            } else if indent < 4, let end = htmlStart(body) {
                html = end
                if case .marker(let m) = end, body.dropFirst(4).contains(m) { html = nil }
            } else if isHeading(body) {
                listColumn = nil
            } else if tableRows.contains(i) || isThematicBreak(body) || isSetextUnderline(body) || isLinkDefinition(body, indent) {
                // copied below
            } else if let item {
                // A list item starts a new line of its own, which its continuation lines join.
                listColumn = indent + item
                out.append(line)
                let rest = body.dropFirst(item).drop { $0 == " " || $0 == "\t" }
                open = rest.isEmpty || endsWithHardBreak(line) ? nil : (out.count - 1, depth)
                continue
            } else {
                // Paragraph text: onto the open line when there is one at this depth, else a
                // new paragraph of its own.
                if let o = open, o.depth == depth {
                    out[o.index] = trimmingTrailingWhitespace(out[o.index]) + " " + body
                    if endsWithHardBreak(out[o.index]) { open = nil }
                } else {
                    out.append(line)
                    open = endsWithHardBreak(line) ? nil : (out.count - 1, depth)
                }
                continue
            }
            out.append(line)
            open = nil
        }
        return out.joined(separator: newline)
    }

    // MARK: - Line classification

    /// A fenced code block's opening fence: its character and length, which its closing fence
    /// must repeat at least that many times.
    private struct Fence {
        let marker: Character
        let length: Int
        init?(opening body: Substring) {
            guard let first = body.first, first == "`" || first == "~" else { return nil }
            let run = body.prefix { $0 == first }.count
            // A backtick fence's info string may not itself contain a backtick.
            guard run >= 3, first == "~" || !body.dropFirst(run).contains("`") else { return nil }
            marker = first; length = run
        }
        func isClosed(by content: Substring) -> Bool {
            let body = content.drop { $0 == " " || $0 == "\t" }
            let run = body.prefix { $0 == marker }.count
            return run >= length && body.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    private enum HTMLEnd { case blankLine, marker(String) }

    /// CommonMark's HTML block starts, reduced to what a plan can contain: a comment, a
    /// `<pre>`/`<script>`/`<style>`/`<textarea>` (each running to its closing tag), any other
    /// tag, processing instruction or declaration (running to the next blank line).
    private static func htmlStart(_ body: Substring) -> HTMLEnd? {
        guard body.hasPrefix("<"), body.count > 1 else { return nil }
        if body.hasPrefix("<!--") { return .marker("-->") }
        let lower = body.lowercased()
        for tag in ["pre", "script", "style", "textarea"] where lower.hasPrefix("<\(tag)") {
            let after = lower.dropFirst(tag.count + 1).first
            if after == nil || after == ">" || after == " " || after == "\t" { return .marker("</\(tag)>") }
        }
        let next = body[body.index(after: body.startIndex)]
        return next.isLetter || next == "/" || next == "!" || next == "?" ? .blankLine : nil
    }

    private static func isHeading(_ body: Substring) -> Bool {
        let hashes = body.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let rest = body.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    /// `***`, `---`, `___`, spaced or not.
    private static func isThematicBreak(_ body: Substring) -> Bool {
        let chars = body.filter { $0 != " " && $0 != "\t" }
        guard let c = chars.first, c == "*" || c == "-" || c == "_", chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == c }
    }

    /// `===` or `---` alone on a line — joined onto the line above, it would stop underlining it.
    private static func isSetextUnderline(_ body: Substring) -> Bool {
        let trimmed = body.reversed().drop { $0 == " " || $0 == "\t" }
        guard let c = trimmed.first, c == "=" || c == "-" else { return false }
        return trimmed.allSatisfy { $0 == c }
    }

    /// `[label]: destination …`
    private static func isLinkDefinition(_ body: Substring, _ indent: Int) -> Bool {
        guard indent < 4, body.hasPrefix("["), let close = body.firstIndex(of: "]"),
              close > body.index(after: body.startIndex) else { return false }
        let after = body[body.index(after: close)...]
        return after.hasPrefix(":") && !after.dropFirst().allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The width of a list item's marker plus the space after it (`- ` is 2, `10. ` is 4), or
    /// nil when `body` does not start a list item. A marker with nothing after it is still an
    /// item (an empty one).
    private static func listItem(_ body: Substring) -> Int? {
        func spaced(_ width: Int) -> Int? {
            let rest = body.dropFirst(width)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            return width + (rest.isEmpty ? 0 : 1)
        }
        guard let first = body.first else { return nil }
        if first == "-" || first == "*" || first == "+" { return spaced(1) }
        let digits = body.prefix { $0.isASCII && $0.isNumber }.count
        guard (1...9).contains(digits), let delimiter = body.dropFirst(digits).first,
              delimiter == "." || delimiter == ")" else { return nil }
        return spaced(digits + 1)
    }

    /// Every line that belongs to a table: a delimiter row (`| --- | :-: |`), the header row
    /// right above it, and the rows under it up to the first line without a pipe — plus any
    /// line that starts with a pipe, table or not, since joining one would put a cell mid-row.
    private static func tableLines(_ lines: [String]) -> Set<Int> {
        var rows = Set<Int>()
        for (i, line) in lines.enumerated() {
            let body = quoted(line).content.drop { $0 == " " || $0 == "\t" }
            if body.hasPrefix("|") { rows.insert(i) }
            guard isDelimiterRow(body) else { continue }
            rows.insert(i)
            if i > 0, quoted(lines[i - 1]).content.contains("|") { rows.insert(i - 1) }
            var j = i + 1
            while j < lines.count, quoted(lines[j]).content.contains("|") { rows.insert(j); j += 1 }
        }
        return rows
    }

    private static func isDelimiterRow(_ body: Substring) -> Bool {
        body.contains("|") && body.contains("-") && body.allSatisfy { "|:- \t".contains($0) }
    }

    /// Front matter: a `---` first line and its closing `---` (or `...`), both lines included.
    /// nil without a close — a lone `---` on line one is then a thematic break.
    private static func frontMatterEnd(_ lines: [String]) -> Int? {
        guard lines.count > 2, trimmingTrailingWhitespace(lines[0]) == "---" else { return nil }
        return lines.indices.dropFirst().first {
            let t = trimmingTrailingWhitespace(lines[$0]); return t == "---" || t == "..."
        }
    }

    // MARK: - Helpers

    /// A line's blockquote depth (how many `>` markers open it) and what follows them.
    private static func quoted(_ line: String) -> (depth: Int, content: Substring) {
        var rest = Substring(line)
        var depth = 0
        while true {
            let spaces = rest.prefix { $0 == " " }.count
            guard spaces < 4, rest.dropFirst(spaces).first == ">" else { break }
            rest = rest.dropFirst(spaces + 1)
            if rest.first == " " { rest = rest.dropFirst() }
            depth += 1
        }
        return (depth, rest)
    }

    private static func isBlank(_ s: Substring) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    /// Leading indentation in columns, a tab to the next multiple of four.
    private static func columns(_ s: Substring) -> Int {
        var n = 0
        for c in s {
            if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break }
        }
        return n
    }

    private static func endsWithHardBreak(_ line: String) -> Bool {
        line.hasSuffix("  ") || line.hasSuffix("\\")
    }

    private static func trimmingTrailingWhitespace(_ s: String) -> String {
        String(s.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
