import AppKit

/// An inline run inside a block: `range` is the content only (`bold`, not `**bold**`); its
/// delimiters are in the block's `syntaxRanges`.
///
/// A link's `target` is where its destination sits in the source — the `url` of `[text](url)`,
/// or the URL itself for `<url>` and a bare `https://…`. ⌘-click reads it from here, not from the
/// glyphs: off the caret block the `(url)` is hidden syntax, so the visible text has no target.
struct MarkdownSpan: Hashable {
    enum Kind: Hashable { case bold, italic, code, link }
    let kind: Kind
    let range: NSRange
    var target: NSRange? = nil
}

/// One Markdown block of the plan, in UTF-16 offsets of the source text (the units
/// `NSTextStorage` counts in). `syntaxRanges` are the characters the rendered view hides —
/// `## `, `**`, backticks, link brackets and URL, code fences, a quote's `> `. A list `marker` is kept apart:
/// attributes can't draw a bullet in place of a hidden `- `, so hiding it would leave a list
/// that reads as prose, and a hidden `1.` would lose the number.
struct MarkdownBlock: Hashable {
    enum Kind: Hashable { case heading(Int), paragraph, listItem, code, table, quote, blank }
    let kind: Kind
    let range: NSRange
    let syntaxRanges: [NSRange]
    var spans: [MarkdownSpan] = []
    var marker: NSRange?

    /// The same block `delta` characters later — how a block after an edit looks if the edit
    /// didn't touch it.
    func shifted(by delta: Int) -> MarkdownBlock {
        func move(_ r: NSRange) -> NSRange { NSRange(location: r.location + delta, length: r.length) }
        return MarkdownBlock(kind: kind, range: move(range), syntaxRanges: syntaxRanges.map(move),
                             spans: spans.map { MarkdownSpan(kind: $0.kind, range: move($0.range), target: $0.target.map(move)) },
                             marker: marker.map(move))
    }
}

/// Fonts, colours and spacing for the rendered plan. A struct rather than constants so a render
/// test or a later density setting can swap it without touching the styler.
///
/// Set for reading, not for density: a 15 pt proportional body at a 1.5 line pitch, a clear
/// heading scale with its room above, and a plan's blank lines drawn as gaps rather than full
/// empty lines. The 13 pt body with every Markdown blank line a whole line tall read as a wall
/// of text broken by random holes (Nate: "still really dense").
struct PlanTheme {
    /// 15 pt, not the body text style: macOS has no Dynamic Type, so `.body` is always 13 pt —
    /// the size that read as dense.
    var body = NSFont.systemFont(ofSize: 15)
    var mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var headingSizes: [CGFloat] = [24, 20, 17, 15, 15, 15]
    var text = NSColor.labelColor
    /// Revealed syntax, list markers, table pipes: present but quieter than the words.
    var syntax = NSColor.tertiaryLabelColor
    var link = NSColor.linkColor
    var codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
    /// A fenced block's box, drawn behind its lines by `EditLayerFragment`.
    var codeBlockBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
    var quoteText = NSColor.secondaryLabelColor
    var quoteBar = NSColor.tertiaryLabelColor.withAlphaComponent(0.45)
    /// A point size small enough that hidden syntax takes no visible width; paired with a
    /// clear colour so nothing of it shows even where a glyph keeps a sliver of advance.
    var hidden = NSFont.systemFont(ofSize: 0.01)

    // MARK: Spacing

    /// Leading between wrapped lines, as `lineSpacing` — a 15 pt body's 18 pt line becomes a
    /// 22.5 pt pitch. Not `lineHeightMultiple` or a minimum line height: measured on TextKit 2,
    /// both grow the caret to the padded line (27 and 22 pt tall) with the glyphs sat at its
    /// bottom, where `lineSpacing` keeps the caret the text's own 18 pt.
    var lineSpacing: CGFloat = 4.5
    /// After a paragraph, before whatever follows it.
    var paragraphSpacing: CGFloat = 6
    /// Between list items.
    var itemSpacing: CGFloat = 4
    /// A blank line's font: the gap between blocks the plan's blank lines make — about half a
    /// line — rather than a whole empty line on top of the paragraph spacing. Its caret is as
    /// short as the gap; typing into it makes it a paragraph at once.
    var gap = NSFont.systemFont(ofSize: 7)
    /// Room a heading keeps above and below itself, by level.
    var headingSpaceBefore: [CGFloat] = [14, 24, 16, 12, 12, 12]
    var headingSpaceAfter: CGFloat = 4
    /// A list's items sit this far in; wrapped lines hang under the item's text.
    var listIndent: CGFloat = 4
    /// A fenced block's inner padding: side indent, and the room its (hidden) fences give it.
    var codePadding: CGFloat = 12
    var codeVerticalPadding: CGFloat = 8
    var quoteIndent: CGFloat = 16

    static let standard = PlanTheme()

    var monoAdvance: CGFloat { ("0" as NSString).size(withAttributes: [.font: mono]).width }

    func heading(_ level: Int) -> NSFont {
        .systemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1], weight: level == 1 ? .bold : .semibold)
    }

    func font(for kind: MarkdownBlock.Kind) -> NSFont {
        switch kind {
        case .heading(let level): heading(level)
        case .code, .table: mono
        case .blank: gap
        case .paragraph, .listItem, .quote: body
        }
    }

    /// The paragraph style every line of a `kind` block starts from. A list item's hanging
    /// indent and a code block's fence padding depend on the block's own text and are added
    /// by the styler.
    func paragraphStyle(for kind: MarkdownBlock.Kind) -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        switch kind {
        case .heading(let level):
            let index = min(max(level, 1), 6) - 1
            para.lineSpacing = headingSizes[index] * 0.2
            para.paragraphSpacingBefore = headingSpaceBefore[index]
            para.paragraphSpacing = headingSpaceAfter
        case .paragraph:
            para.lineSpacing = lineSpacing
            para.paragraphSpacing = paragraphSpacing
        case .listItem:
            para.lineSpacing = lineSpacing
            para.paragraphSpacing = itemSpacing
        case .quote:
            para.lineSpacing = lineSpacing
            para.paragraphSpacing = paragraphSpacing
            para.firstLineHeadIndent = quoteIndent
            para.headIndent = quoteIndent
        case .code:
            para.lineSpacing = 3
            para.firstLineHeadIndent = codePadding
            para.headIndent = codePadding
            para.tailIndent = -codePadding
        case .table:
            para.lineSpacing = 3
        case .blank:
            break
        }
        return para
    }
}

/// The live-preview Markdown pass (spec §7.1): a hand-written, line-based block parse, then
/// attributes over the untouched source. The text is never rewritten — the stored plan is
/// always the raw Markdown the runner reads — so every "rendered" effect is an attribute,
/// and hiding syntax means a near-zero font and a clear colour on those characters.
///
/// Parsing is over a `[UInt16]` copy of the text rather than regexes: it runs on every
/// keystroke over the whole plan, and four `NSRegularExpression`s per line of a 2,000-line
/// plan would blow the frame budget on their own.
enum MarkdownStyler {
    // MARK: - Blocks

    static func blocks(_ text: String) -> [MarkdownBlock] {
        let u = units(text)
        return parse(u, from: 0) { _ in false }.blocks
    }

    /// The same blocks `blocks(text)` gives, re-parsed only around one edit: `old` were the
    /// blocks before it, `edited` and `delta` the edit as the text storage reported it. Parsing
    /// restarts two blocks before the edit and stops at the first new block that starts where
    /// an old one past the edit did — from a block start the parse depends only on the text
    /// from there on, which the edit didn't change, so the rest is the old blocks moved by
    /// `delta`. On a 2,000-line plan a whole re-parse was the largest part of a keystroke.
    static func blocks(_ text: String, after old: [MarkdownBlock], edited: NSRange, delta: Int) -> [MarkdownBlock] {
        let u = units(text)
        let oldEnd = NSMaxRange(edited) - delta
        let containing = old.lastIndex { $0.range.location <= edited.location } ?? 0
        let first = max(containing - 2, 0)
        guard first < old.count else { return parse(u, from: 0) { _ in false }.blocks }
        // Old block starts past the edit, by where they start now.
        var resume: [Int: Int] = [:]
        for i in (first + 1)..<old.count where old[i].range.location > oldEnd { resume[old[i].range.location + delta] = i }
        let (fresh, stoppedAt) = parse(u, from: old[first].range.location) { resume[$0] != nil }
        let tail = stoppedAt.map { at in old[resume[at]!...].map { $0.shifted(by: delta) } } ?? []
        return Array(old[..<first]) + fresh + tail
    }

    private static func units(_ text: String) -> [UInt16] {
        // `getCharacters`, not `Array(text.utf16)`: the editor's text is NSString-backed, and
        // the UTF-16 view walked it through the bridge one character at a time.
        let ns = text as NSString
        var u = [UInt16](repeating: 0, count: ns.length)
        u.withUnsafeMutableBufferPointer { if let base = $0.baseAddress { ns.getCharacters(base, range: NSRange(location: 0, length: ns.length)) } }
        return u
    }

    /// The blocks from `start` (a line start) on, stopping before a block that would start at
    /// an offset `stop` accepts; `stopped` is that offset, nil at the end of the text. Lines
    /// are scanned as the parse reaches them, so a parse that stops early reads only its part.
    private static func parse(_ u: [UInt16], from start: Int, stop: (Int) -> Bool) -> (blocks: [MarkdownBlock], stopped: Int?) {
        var lines: [(start: Int, end: Int)] = []
        // Once per line: the fence, table and paragraph scans look ahead at the next lines' kinds.
        var kinds: [LineKind] = []
        var next = start
        /// Whether line `li` exists, scanning up to it. Plain index loops here and in
        /// `lineKind`: `enumerated()` and friends run unspecialised in a Debug build, which
        /// alone cost most of a frame on a long plan.
        func has(_ li: Int) -> Bool {
            while lines.count <= li, next < u.count {
                var i = next
                while i < u.count, u[i] != 10 { i += 1 }
                let end = i > next && i <= u.count && u[i - 1] == 13 ? i - 1 : i
                lines.append((next, end))
                kinds.append(lineKind(u, next, end))
                next = i + 1
            }
            return li < lines.count
        }

        var out: [MarkdownBlock] = []
        var li = 0
        while has(li) {
            let (s, e) = lines[li]
            if !out.isEmpty || s != start, stop(s) { return (out, s) }
            switch kinds[li] {
            case .fence:
                // An unclosed fence runs to the end: un-fencing the rest would style code as
                // headings the moment the human types the opening ```.
                var close: Int?
                var j = li + 1
                while has(j) { if kinds[j] == .fence { close = j; break }; j += 1 }
                let last = close ?? lines.count - 1
                // The opening fence's newline is syntax too, so a hidden fence collapses to a
                // hairline instead of leaving an empty code line.
                var syntax = [NSRange(location: s, length: min(e + 1, lines[last].end) - s)]
                if let close { syntax.append(NSRange(location: lines[close].start, length: lines[close].end - lines[close].start)) }
                out.append(MarkdownBlock(kind: .code, range: NSRange(location: s, length: lines[last].end - s), syntaxRanges: syntax))
                li = last + 1
            case .blank:
                out.append(MarkdownBlock(kind: .blank, range: NSRange(location: s, length: e - s), syntaxRanges: []))
                li += 1
            case .heading(let level, let contentStart):
                var syntax = [NSRange(location: s, length: contentStart - s)]
                var spans: [MarkdownSpan] = []
                inline(u, contentStart, e, spans: &spans, syntax: &syntax)
                out.append(block(.heading(level), s, e, syntax, spans))
                li += 1
            case .table:
                var last = li
                while has(last + 1), kinds[last + 1] == .table { last += 1 }
                out.append(MarkdownBlock(kind: .table, range: NSRange(location: s, length: lines[last].end - s), syntaxRanges: []))
                li = last + 1
            case .listItem(let contentStart):
                var syntax: [NSRange] = []
                var spans: [MarkdownSpan] = []
                inline(u, contentStart, e, spans: &spans, syntax: &syntax)
                var item = block(.listItem, s, e, syntax, spans)
                let indent = (s..<contentStart).first { u[$0] != 32 && u[$0] != 9 } ?? s
                item.marker = NSRange(location: indent, length: contentStart - indent)
                out.append(item)
                li += 1
            case .quote:
                // Consecutive `>` lines are one quote, as consecutive prose lines are one paragraph.
                var last = li
                while has(last + 1), case .quote = kinds[last + 1] { last += 1 }
                var syntax: [NSRange] = []
                var spans: [MarkdownSpan] = []
                for l in li...last {
                    guard case .quote(let contentStart) = kinds[l] else { continue }
                    syntax.append(NSRange(location: lines[l].start, length: contentStart - lines[l].start))
                    inline(u, contentStart, lines[l].end, spans: &spans, syntax: &syntax)
                }
                out.append(block(.quote, s, lines[last].end, syntax, spans))
                li = last + 1
            case .plain:
                var last = li
                while has(last + 1), kinds[last + 1] == .plain { last += 1 }
                var syntax: [NSRange] = []
                var spans: [MarkdownSpan] = []
                for l in li...last { inline(u, lines[l].start, lines[l].end, spans: &spans, syntax: &syntax) }
                out.append(block(.paragraph, s, lines[last].end, syntax, spans))
                li = last + 1
            }
        }
        return (out, nil)
    }

    private static func block(_ kind: MarkdownBlock.Kind, _ s: Int, _ e: Int, _ syntax: [NSRange], _ spans: [MarkdownSpan]) -> MarkdownBlock {
        MarkdownBlock(kind: kind, range: NSRange(location: s, length: e - s),
                      syntaxRanges: syntax.sorted { $0.location < $1.location },
                      spans: spans.sorted { $0.range.location < $1.range.location })
    }

    private enum LineKind: Equatable { case blank, fence, heading(Int, contentStart: Int), table, listItem(contentStart: Int), quote(contentStart: Int), plain }

    private static func lineKind(_ u: [UInt16], _ s: Int, _ e: Int) -> LineKind {
        var i = s
        while i < e, u[i] == 32 || u[i] == 9 { i += 1 }
        if i == e { return .blank }
        let indent = i - s
        let c = u[i]
        // ``` or ~~~, at most three spaces in (four is an indented code line in CommonMark).
        if indent <= 3, c == 96 || c == 126, i + 2 < e, u[i + 1] == c, u[i + 2] == c { return .fence }
        if indent <= 3, c == 35 {
            var j = i
            while j < e, u[j] == 35 { j += 1 }
            let level = j - i
            if level <= 6, j == e || u[j] == 32 {
                while j < e, u[j] == 32 { j += 1 }
                return .heading(level, contentStart: j)
            }
        }
        if c == 124 { return .table }
        if indent <= 3, c == 62 { return .quote(contentStart: i + 1 < e && u[i + 1] == 32 ? i + 2 : i + 1) }
        // `-`/`*`/`+` then a space; "---" and "**bold**" fail the space test and stay prose.
        if c == 45 || c == 42 || c == 43, i + 1 < e, u[i + 1] == 32 { return .listItem(contentStart: i + 2) }
        if c >= 48, c <= 57 {
            var j = i
            while j < e, u[j] >= 48, u[j] <= 57 { j += 1 }
            if j - i <= 9, j + 1 < e, u[j] == 46 || u[j] == 41, u[j + 1] == 32 { return .listItem(contentStart: j + 2) }
        }
        return .plain
    }

    /// Inline syntax on one line, by precedence: code spans first (nothing inside them is
    /// Markdown), then links, bold, italic — each pass skipping characters an earlier pass
    /// claimed, so the `*` of a `**` is never also read as an italic delimiter.
    private static func inline(_ u: [UInt16], _ a: Int, _ b: Int, spans: inout [MarkdownSpan], syntax: inout [NSRange]) {
        // Most plan lines have no inline syntax at all; skip them before allocating the mask.
        // `<` for an autolink, `://` for a bare URL.
        guard b - a >= 2 else { return }
        var any = false
        var scan = a
        while scan < b, !any {
            let c = u[scan]
            any = c == 96 || c == 91 || c == 42 || c == 60 || (c == 58 && scan + 2 < b && u[scan + 1] == 47 && u[scan + 2] == 47)
            scan += 1
        }
        guard any else { return }
        var taken = [Bool](repeating: false, count: b - a)
        func free(_ i: Int) -> Bool { !taken[i - a] }
        func take(_ r: Range<Int>) { for i in r { taken[i - a] = true } }
        func emit(_ kind: MarkdownSpan.Kind, open: NSRange, content: NSRange, close: NSRange, target: NSRange? = nil) {
            syntax.append(open)
            syntax.append(close)
            spans.append(MarkdownSpan(kind: kind, range: content, target: target))
        }

        // `code`, matching the opening run's length (``a ` b``).
        var i = a
        while i < b {
            guard u[i] == 96 else { i += 1; continue }
            var n = i
            while n < b, u[n] == 96 { n += 1 }
            let run = n - i
            var j = n, close: Int?
            while j < b {
                guard u[j] == 96 else { j += 1; continue }
                var k = j
                while k < b, u[k] == 96 { k += 1 }
                if k - j == run { close = j; break }
                j = k
            }
            guard let close, close > n else { i = n; continue }
            emit(.code, open: NSRange(location: i, length: run), content: NSRange(location: n, length: close - n),
                 close: NSRange(location: close, length: run))
            take(i..<close + run)
            i = close + run
        }

        // <scheme:…> — an autolink: the brackets are syntax, the URL is both text and target.
        i = a
        while i < b {
            guard u[i] == 60, free(i), let gt = (i + 1..<b).first(where: { u[$0] == 62 || u[$0] == 60 || u[$0] == 32 }),
                  u[gt] == 62, isScheme(u, i + 1, gt) else { i += 1; continue }
            let content = NSRange(location: i + 1, length: gt - i - 1)
            emit(.link, open: NSRange(location: i, length: 1), content: content, close: NSRange(location: gt, length: 1), target: content)
            take(i..<gt + 1)
            i = gt + 1
        }

        // [text](url)
        i = a
        while i < b {
            guard u[i] == 91, free(i), let rb = (i + 1..<b).first(where: { u[$0] == 93 && free($0) }), rb > i + 1,
                  rb + 1 < b, u[rb + 1] == 40, let rp = (rb + 2..<b).first(where: { u[$0] == 41 && free($0) })
            else { i += 1; continue }
            emit(.link, open: NSRange(location: i, length: 1), content: NSRange(location: i + 1, length: rb - i - 1),
                 close: NSRange(location: rb, length: rp - rb + 1), target: NSRange(location: rb + 2, length: rp - rb - 2))
            take(i..<i + 1)
            take(rb..<rp + 1)
            i = rp + 1
        }

        // A bare http(s):// URL, to the next space, less the sentence punctuation after it (and a
        // `)` it didn't open — "(see https://x.y)"). No syntax: the text is the URL.
        i = a
        while i + 3 < b {
            guard u[i] == 58, u[i + 1] == 47, u[i + 2] == 47, free(i),
                  !spans.contains(where: { $0.kind == .link && NSLocationInRange(i, $0.range) }) else { i += 1; continue }
            var s = i
            while s > a, (u[s - 1] | 0x20) >= 97, (u[s - 1] | 0x20) <= 122 { s -= 1 }
            let scheme = String(utf16CodeUnits: Array(u[s..<i]), count: i - s).lowercased()
            guard scheme == "http" || scheme == "https", s == a || !isWordUnit(u[s - 1]), (s..<i).allSatisfy(free) else { i += 3; continue }
            var e = i + 3
            while e < b, u[e] != 32, u[e] != 9, u[e] != 60, free(e) { e += 1 }
            var opens = 0
            for k in s..<e where u[k] == 40 { opens += 1 }
            while e > i + 3 {
                let c = u[e - 1]
                if c == 46 || c == 44 || c == 59 || c == 58 || c == 33 || c == 63 || c == 39 || c == 34 { e -= 1; continue }
                if c == 41, opens < (s..<e).filter({ u[$0] == 41 }).count { e -= 1; continue }
                break
            }
            guard e > i + 3 else { i += 3; continue }
            let url = NSRange(location: s, length: e - s)
            spans.append(MarkdownSpan(kind: .link, range: url, target: url))
            take(s..<e)
            i = e
        }

        // **bold** — only the delimiters are claimed, so code or a link inside still counts.
        i = a
        while i + 1 < b {
            guard u[i] == 42, u[i + 1] == 42, free(i), free(i + 1),
                  let j = (i + 3..<max(i + 3, b - 1)).first(where: { u[$0] == 42 && u[$0 + 1] == 42 && free($0) && free($0 + 1) })
            else { i += 1; continue }
            emit(.bold, open: NSRange(location: i, length: 2), content: NSRange(location: i + 2, length: j - i - 2),
                 close: NSRange(location: j, length: 2))
            take(i..<i + 2)
            take(j..<j + 2)
            i = j + 2
        }

        // *italic* — flanking: no space just inside either delimiter, so "a * b * c" is prose.
        i = a
        while i + 2 < b {
            guard u[i] == 42, free(i), u[i + 1] != 32, u[i + 1] != 42,
                  let j = (i + 2..<b).first(where: { u[$0] == 42 && free($0) && u[$0 - 1] != 32 })
            else { i += 1; continue }
            emit(.italic, open: NSRange(location: i, length: 1), content: NSRange(location: i + 1, length: j - i - 1),
                 close: NSRange(location: j, length: 1))
            take(i..<i + 1)
            take(j..<j + 1)
            i = j + 1
        }
    }

    /// `u[s..<e]` starts with a URL scheme — `https:`, `mailto:`, `file:` — as an autolink's
    /// content must (CommonMark: a letter, then 1–31 letters, digits, `+ . -`, then `:`).
    private static func isScheme(_ u: [UInt16], _ s: Int, _ e: Int) -> Bool {
        guard s < e, (u[s] | 0x20) >= 97, (u[s] | 0x20) <= 122 else { return false }
        var k = s + 1
        while k < e, k - s <= 32 {
            let c = u[k]
            if c == 58 { return k - s >= 2 && k + 1 < e }
            guard isWordUnit(c) || c == 43 || c == 46 || c == 45 else { return false }
            k += 1
        }
        return false
    }

    /// An ASCII letter or digit — what can't come right before a bare URL's scheme.
    private static func isWordUnit(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || ((c | 0x20) >= 97 && (c | 0x20) <= 122)
    }

    // MARK: - Lookup and diff

    /// The link span at `location` in `blocks`, its content taken as the clickable part.
    static func link(at location: Int, in blocks: [MarkdownBlock]) -> MarkdownSpan? {
        guard let index = blockIndex(at: location, in: blocks) else { return nil }
        return blocks[index].spans.first { $0.kind == .link && NSLocationInRange(location, $0.range) }
    }

    /// The block holding `location`, a caret sitting at a block's end included (the caret
    /// after the last character of a heading is still "in" it). Binary search: the caret
    /// moves on every arrow key.
    static func blockIndex(at location: Int, in blocks: [MarkdownBlock]) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = blocks[mid].range
            if location < r.location { hi = mid - 1 }
            else if location > NSMaxRange(r) { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// Indices of `new` blocks that need restyling after an edit: everything between the
    /// longest run of blocks unchanged at the front and the longest run merely shifted by
    /// `delta` at the back. Outside that window the text and its attributes moved together,
    /// so the styling is still right. `edited` is the edited range in the new text
    /// (`NSTextStorage.editedRange`). A keystroke re-kinds one block; an opened fence re-kinds
    /// everything after it — this finds both without restyling the whole plan.
    static func changedBlocks(old: [MarkdownBlock], new: [MarkdownBlock], edited: NSRange, delta: Int) -> [Int] {
        var front = 0
        while front < old.count, front < new.count, NSMaxRange(old[front].range) < edited.location, old[front] == new[front] {
            front += 1
        }
        let oldEnd = NSMaxRange(edited) - delta
        var back = 0
        while back < old.count - front, back < new.count - front {
            let o = old[old.count - 1 - back]
            guard o.range.location > oldEnd, o.shifted(by: delta) == new[new.count - 1 - back] else { break }
            back += 1
        }
        return Array(front..<new.count - back)
    }

    // MARK: - Attributes

    /// Styles the whole text. Syntax is hidden everywhere except in `revealBlock` — the one
    /// holding the caret — where it shows, quieter than the words.
    static func apply(to storage: NSTextStorage, blocks: [MarkdownBlock], revealBlock: Int?, theme: PlanTheme) {
        storage.beginEditing()
        storage.setAttributes(baseAttributes(theme.body, theme), range: NSRange(location: 0, length: storage.length))
        for (i, block) in blocks.enumerated() { style(storage, block, revealed: i == revealBlock, theme) }
        storage.endEditing()
    }

    /// Restyles only `indices` — a caret move touches the block it left and the one it
    /// entered, never the rest of the plan.
    static func restyle(_ storage: NSTextStorage, blocks: [MarkdownBlock], indices: [Int], revealBlock: Int?, theme: PlanTheme) {
        storage.beginEditing()
        for i in Set(indices) where blocks.indices.contains(i) {
            let block = blocks[i]
            storage.setAttributes(baseAttributes(theme.font(for: block.kind), theme), range: paragraphRange(block, storage))
            style(storage, block, revealed: i == revealBlock, theme)
        }
        storage.endEditing()
    }

    /// The block plus its trailing newline: a line's height and paragraph style come from its
    /// newline too, so a heading styled without it keeps a body-height line under it.
    private static func paragraphRange(_ block: MarkdownBlock, _ storage: NSTextStorage) -> NSRange {
        let end = NSMaxRange(block.range)
        let newline = end < storage.length && storage.mutableString.character(at: end) == 10
        return NSRange(location: block.range.location, length: block.range.length + (newline ? 1 : 0))
    }

    private static func baseAttributes(_ font: NSFont, _ theme: PlanTheme) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: theme.text]
    }

    private static func style(_ storage: NSTextStorage, _ block: MarkdownBlock, revealed: Bool, _ theme: PlanTheme) {
        let font = theme.font(for: block.kind)
        let whole = paragraphRange(block, storage)
        storage.addAttribute(.font, value: font, range: whole)
        let para = theme.paragraphStyle(for: block.kind)
        switch block.kind {
        case .heading, .paragraph, .blank, .table:
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
            if case .table = block.kind { styleTable(storage, block, theme) }
        case .quote:
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
            storage.addAttribute(.foregroundColor, value: theme.quoteText, range: block.range)
            storage.addAttribute(.planQuote, value: true, range: whole)
        case .listItem:
            // A hanging indent, so a wrapped item lines up under its text, not its marker.
            para.firstLineHeadIndent = theme.listIndent
            para.headIndent = theme.listIndent
            if let marker = block.marker {
                let width = (storage.mutableString.substring(with: NSRange(location: block.range.location,
                                                                        length: NSMaxRange(marker) - block.range.location)) as NSString).size(withAttributes: [.font: font]).width
                para.headIndent += width
                storage.addAttribute(.foregroundColor, value: theme.syntax, range: marker)
            }
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
        case .code:
            styleCode(storage, block, whole: whole, para: para, theme)
        }
        for span in block.spans {
            switch span.kind {
            case .bold: storage.addAttribute(.font, value: convert(font, .boldFontMask), range: span.range)
            case .italic: storage.addAttribute(.font, value: convert(font, .italicFontMask), range: span.range)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: span.range)
                storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: span.range)
            case .link:
                // Tinted, not underlined: an editor's links are text first — the underline is
                // the ⌘-hover cue (`PlanNSTextView`), as in Xcode. `.link` carries the target for
                // VoiceOver (an AXLink with its URL); what a click does is `PlanNSTextView`'s.
                storage.addAttribute(.foregroundColor, value: theme.link, range: span.range)
                if let target = span.target, NSMaxRange(target) <= storage.length {
                    let raw = storage.mutableString.substring(with: target)
                    storage.addAttribute(.link, value: URL(string: raw).map { $0 as Any } ?? raw, range: span.range)
                }
            }
        }
        for range in block.syntaxRanges {
            if revealed {
                storage.addAttribute(.foregroundColor, value: theme.syntax, range: range)
            } else {
                storage.addAttributes([.font: theme.hidden, .foregroundColor: NSColor.clear], range: range)
            }
        }
    }

    /// A fenced block as a padded box: every line takes the block's indents, the first (the
    /// opening fence, a hairline while hidden) carries the top padding as spacing after it and
    /// the last the bottom padding before it, and each line is marked with its place in the box
    /// (`CodeBox`) for `EditLayerFragment` to draw the background behind. `.backgroundColor`
    /// alone paints only behind glyphs — a ragged run per line, not a block.
    private static func styleCode(_ storage: NSTextStorage, _ block: MarkdownBlock, whole: NSRange, para: NSMutableParagraphStyle,
                                  _ theme: PlanTheme) {
        let ns = storage.mutableString
        var lines: [NSRange] = []
        var at = whole.location
        while at < NSMaxRange(whole) {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            lines.append(NSIntersectionRange(line, whole))
            at = NSMaxRange(line)
        }
        let closed = block.syntaxRanges.count > 1
        for (i, line) in lines.enumerated() {
            let style = para.mutableCopy() as! NSMutableParagraphStyle
            var place: CodeBox = []
            if i == 0 {
                place.insert(.first)
                style.paragraphSpacing = theme.codeVerticalPadding
            }
            if i == lines.count - 1 {
                place.insert(.last)
                // An unclosed fence's last line is code, not a hidden fence to pad with.
                if closed, lines.count > 1 { style.paragraphSpacingBefore = theme.codeVerticalPadding }
            }
            storage.addAttributes([.paragraphStyle: style, .planCodeBox: place.rawValue], range: line)
        }
    }

    private static func convert(_ font: NSFont, _ trait: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }

    /// Pipe tables as a monospace block with aligned columns. The source can't be padded (it
    /// is the plan), so each cell shorter than its column's widest gets the missing width as
    /// kern on its last character. A full grid layout is out of scope; this keeps columns
    /// readable without touching a byte.
    private static func styleTable(_ storage: NSTextStorage, _ block: MarkdownBlock, _ theme: PlanTheme) {
        let u = Array(storage.mutableString.substring(with: block.range).utf16)
        let base = block.range.location
        // Each row's pipe offsets, split on newlines.
        var rows: [[Int]] = [[]]
        for (i, c) in u.enumerated() {
            if c == 10 { rows.append([]) }
            else if c == 124, i == 0 || u[i - 1] != 92 { rows[rows.count - 1].append(i) }
        }
        var widths: [Int] = []
        for pipes in rows {
            for col in 0..<max(pipes.count - 1, 0) {
                let w = pipes[col + 1] - pipes[col] - 1
                if col < widths.count { widths[col] = max(widths[col], w) } else { widths.append(w) }
            }
        }
        let advance = theme.monoAdvance
        for pipes in rows {
            for p in pipes { storage.addAttribute(.foregroundColor, value: theme.syntax, range: NSRange(location: base + p, length: 1)) }
            for col in 0..<max(pipes.count - 1, 0) {
                let pad = widths[col] - (pipes[col + 1] - pipes[col] - 1)
                guard pad > 0 else { continue }
                storage.addAttribute(.kern, value: CGFloat(pad) * advance, range: NSRange(location: base + pipes[col + 1] - 1, length: 1))
            }
        }
    }
}

/// A line's place in a fenced block's box: the first line draws the box's top corners, the
/// last its bottom ones, the rest a plain band. Stored as the raw value of `.planCodeBox`.
struct CodeBox: OptionSet {
    let rawValue: Int
    static let first = CodeBox(rawValue: 1)
    static let last = CodeBox(rawValue: 2)
}

extension NSAttributedString.Key {
    /// A fenced block's line (`CodeBox` raw value): `EditLayerFragment` draws the box behind it.
    static let planCodeBox = NSAttributedString.Key("FlightDeck.planCodeBox")
    /// A quote's line: `EditLayerFragment` draws the quiet bar beside it.
    static let planQuote = NSAttributedString.Key("FlightDeck.planQuote")
}
