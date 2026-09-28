import AppKit

/// An inline run inside a block: `range` is the content only (`bold`, not `**bold**`); its
/// delimiters are in the block's `syntaxRanges`.
struct MarkdownSpan: Hashable {
    enum Kind: Hashable { case bold, italic, code, link }
    let kind: Kind
    let range: NSRange
}

/// One Markdown block of the plan, in UTF-16 offsets of the source text (the units
/// `NSTextStorage` counts in). `syntaxRanges` are the characters the rendered view hides —
/// `## `, `**`, backticks, link brackets and URL, code fences. A list `marker` is kept apart:
/// attributes can't draw a bullet in place of a hidden `- `, so hiding it would leave a list
/// that reads as prose, and a hidden `1.` would lose the number.
struct MarkdownBlock: Hashable {
    enum Kind: Hashable { case heading(Int), paragraph, listItem, code, table, blank }
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
                             spans: spans.map { MarkdownSpan(kind: $0.kind, range: move($0.range)) },
                             marker: marker.map(move))
    }
}

/// Fonts and colours for the rendered plan. A struct rather than constants so a render test
/// or a later density setting can swap it without touching the styler.
struct PlanTheme {
    var body = NSFont.systemFont(ofSize: 13)
    var mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var headingSizes: [CGFloat] = [22, 18, 15, 13, 13, 13]
    var text = NSColor.labelColor
    /// Revealed syntax, list markers, table pipes: present but quieter than the words.
    var syntax = NSColor.tertiaryLabelColor
    var link = NSColor.linkColor
    var codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
    /// A point size small enough that hidden syntax takes no visible width; paired with a
    /// clear colour so nothing of it shows even where a glyph keeps a sliver of advance.
    var hidden = NSFont.systemFont(ofSize: 0.01)

    static let standard = PlanTheme()

    var monoAdvance: CGFloat { ("0" as NSString).size(withAttributes: [.font: mono]).width }

    func heading(_ level: Int) -> NSFont {
        .systemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1], weight: .semibold)
    }

    func font(for kind: MarkdownBlock.Kind) -> NSFont {
        switch kind {
        case .heading(let level): heading(level)
        case .code, .table: mono
        case .paragraph, .listItem, .blank: body
        }
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
        let u = Array(text.utf16)
        var lines: [(start: Int, end: Int)] = []
        var start = 0
        var i = 0
        // Plain index loops here and in `lineKind`: `enumerated()` and friends run
        // unspecialised in a Debug build, which alone cost most of a frame on a long plan.
        while i < u.count {
            if u[i] == 10 {
                lines.append((start, i > start && u[i - 1] == 13 ? i - 1 : i))
                start = i + 1
            }
            i += 1
        }
        if start < u.count { lines.append((start, u.count)) }

        // Once per line: the fence, table and paragraph scans look ahead at the next lines' kinds.
        var kinds: [LineKind] = []
        kinds.reserveCapacity(lines.count)
        for line in lines { kinds.append(lineKind(u, line.start, line.end)) }
        var out: [MarkdownBlock] = []
        var li = 0
        while li < lines.count {
            let (s, e) = lines[li]
            switch kinds[li] {
            case .fence:
                // An unclosed fence runs to the end: un-fencing the rest would style code as
                // headings the moment the human types the opening ```.
                let close = (li + 1..<lines.count).first { kinds[$0] == .fence }
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
                while last + 1 < lines.count, kinds[last + 1] == .table { last += 1 }
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
            case .plain:
                var last = li
                while last + 1 < lines.count, kinds[last + 1] == .plain { last += 1 }
                var syntax: [NSRange] = []
                var spans: [MarkdownSpan] = []
                for l in li...last { inline(u, lines[l].start, lines[l].end, spans: &spans, syntax: &syntax) }
                out.append(block(.paragraph, s, lines[last].end, syntax, spans))
                li = last + 1
            }
        }
        return out
    }

    private static func block(_ kind: MarkdownBlock.Kind, _ s: Int, _ e: Int, _ syntax: [NSRange], _ spans: [MarkdownSpan]) -> MarkdownBlock {
        MarkdownBlock(kind: kind, range: NSRange(location: s, length: e - s),
                      syntaxRanges: syntax.sorted { $0.location < $1.location },
                      spans: spans.sorted { $0.range.location < $1.range.location })
    }

    private enum LineKind: Equatable { case blank, fence, heading(Int, contentStart: Int), table, listItem(contentStart: Int), plain }

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
        guard b - a >= 2 else { return }
        var any = false
        var scan = a
        while scan < b, !any { any = u[scan] == 96 || u[scan] == 91 || u[scan] == 42; scan += 1 }
        guard any else { return }
        var taken = [Bool](repeating: false, count: b - a)
        func free(_ i: Int) -> Bool { !taken[i - a] }
        func take(_ r: Range<Int>) { for i in r { taken[i - a] = true } }
        func emit(_ kind: MarkdownSpan.Kind, open: NSRange, content: NSRange, close: NSRange) {
            syntax.append(open)
            syntax.append(close)
            spans.append(MarkdownSpan(kind: kind, range: content))
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

        // [text](url)
        i = a
        while i < b {
            guard u[i] == 91, free(i), let rb = (i + 1..<b).first(where: { u[$0] == 93 && free($0) }), rb > i + 1,
                  rb + 1 < b, u[rb + 1] == 40, let rp = (rb + 2..<b).first(where: { u[$0] == 41 && free($0) })
            else { i += 1; continue }
            emit(.link, open: NSRange(location: i, length: 1), content: NSRange(location: i + 1, length: rb - i - 1),
                 close: NSRange(location: rb, length: rp - rb + 1))
            take(i..<i + 1)
            take(rb..<rp + 1)
            i = rp + 1
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

    // MARK: - Lookup and diff

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
        switch block.kind {
        case .heading(let level):
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = level <= 2 ? 10 : 6
            para.paragraphSpacing = 4
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
        case .listItem:
            // A hanging indent, so a wrapped item lines up under its text, not its marker.
            if let marker = block.marker {
                let para = NSMutableParagraphStyle()
                let width = (storage.mutableString.substring(with: NSRange(location: block.range.location,
                                                                        length: NSMaxRange(marker) - block.range.location)) as NSString).size(withAttributes: [.font: font]).width
                para.headIndent = width
                storage.addAttribute(.paragraphStyle, value: para, range: whole)
                storage.addAttribute(.foregroundColor, value: theme.syntax, range: marker)
            }
        case .code:
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: block.range)
        case .table:
            styleTable(storage, block, theme)
        case .paragraph, .blank:
            break
        }
        for span in block.spans {
            switch span.kind {
            case .bold: storage.addAttribute(.font, value: convert(font, .boldFontMask), range: span.range)
            case .italic: storage.addAttribute(.font, value: convert(font, .italicFontMask), range: span.range)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: span.range)
                storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: span.range)
            case .link:
                storage.addAttribute(.foregroundColor, value: theme.link, range: span.range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
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
