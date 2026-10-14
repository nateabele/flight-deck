import AppKit

/// A GitHub-style pipe table, parsed from the source of one table block (`MarkdownBlock.kind ==
/// .table`): a header row, a `|---|:--:|` delimiter row, then body rows. Offsets are UTF-16 units
/// from the start of the block's text, so the same table anywhere in the plan parses the same.
///
/// A block with no delimiter row on its second line is not a table (GFM says so too) and `parse`
/// returns nil: the editor shows its lines as plain source.
struct PlanTable {
    enum Alignment { case left, center, right }

    struct Cell {
        /// The cell's content, trimmed of the spaces around it.
        let range: NSRange
        /// Inline Markdown inside it (`MarkdownStyler`'s own pass), and the delimiters it hides.
        let spans: [MarkdownSpan]
        let syntax: [NSRange]
    }

    struct Row {
        /// The row's line, without its newline.
        let line: NSRange
        let cells: [Cell]
    }

    let rows: [Row]
    /// One per column, left unless the delimiter row says otherwise (`:--`, `--:`, `:-:`).
    let alignments: [Alignment]
    var columnCount: Int { alignments.count }
    /// The delimiter row: never drawn.
    static let delimiterRow = 1

    static func parse(_ u: [UInt16]) -> PlanTable? {
        var lines: [NSRange] = []
        var start = 0
        for i in 0...u.count where i == u.count || u[i] == 10 {
            lines.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        guard lines.count >= 2, let alignments = delimiter(u, lines[1]) else { return nil }
        var rows: [Row] = []
        for (i, line) in lines.enumerated() {
            var cells: [Cell] = []
            for range in split(u, line) {
                var spans: [MarkdownSpan] = []
                var syntax: [NSRange] = []
                // The delimiter row's cells are never drawn; their dashes are not Markdown.
                if i != delimiterRow { MarkdownStyler.inline(u, range.location, NSMaxRange(range), spans: &spans, syntax: &syntax) }
                cells.append(Cell(range: range, spans: spans, syntax: syntax))
            }
            rows.append(Row(line: line, cells: cells))
        }
        let columns = max(rows.map(\.cells.count).max() ?? 0, alignments.count)
        return PlanTable(rows: rows, alignments: alignments + Array(repeating: .left, count: columns - alignments.count))
    }

    /// The cells of a line: the trimmed spans between unescaped pipes, less the empty piece a
    /// leading or trailing pipe leaves.
    private static func split(_ u: [UInt16], _ line: NSRange) -> [NSRange] {
        let end = NSMaxRange(line)
        var i = line.location
        while i < end, isSpace(u[i]) { i += 1 }
        if i < end, u[i] == 124 { i += 1 }
        var cells: [NSRange] = []
        var from = i
        while i <= end {
            if i == end || (u[i] == 124 && u[i - 1] != 92) {
                var a = from, b = i
                while a < b, isSpace(u[a]) { a += 1 }
                while b > a, isSpace(u[b - 1]) { b -= 1 }
                // After the last pipe there is nothing, not an empty cell.
                if i < end || b > a { cells.append(NSRange(location: a, length: b - a)) }
                from = i + 1
            }
            i += 1
        }
        return cells
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }

    /// The alignments the delimiter line `line` declares; nil when it is not a delimiter row.
    private static func delimiter(_ u: [UInt16], _ line: NSRange) -> [Alignment]? {
        let cells = split(u, line)
        guard !cells.isEmpty else { return nil }
        var out: [Alignment] = []
        for cell in cells {
            var a = cell.location, b = NSMaxRange(cell)
            let left = a < b && u[a] == 58
            let right = b > a + (left ? 1 : 0) && u[b - 1] == 58
            if left { a += 1 }
            if right { b -= 1 }
            guard b > a, (a..<b).allSatisfy({ u[$0] == 45 }) else { return nil }
            out.append(left && right ? .center : right ? .right : .left)
        }
        return out
    }
}

/// A table laid out for a given width: the column widths, each row's height and each cell's
/// styled text, everything the editor needs to give the table's source lines their height and to
/// draw them as a grid (`EditLayerFragment`) — and to turn a click back into a place in the source.
///
/// Built once per (table source, width, type size) and cached; the cache is why a keystroke
/// elsewhere in a long plan never lays a table again.
final class PlanTableLayout: NSObject {
    struct Cell {
        let text: NSAttributedString
        /// `map[i]` is where display character `i` sits in the source, from the row's line start.
        let map: [Int]
        /// The cell's source extent, from the row's line start: where a click on empty space goes.
        let sourceStart: Int
        let sourceEnd: Int
    }

    struct Row {
        let top: CGFloat
        let height: CGFloat
        let cells: [Cell]
        let isHeader: Bool
        /// The delimiter row, which takes no room.
        let isHidden: Bool
    }

    let rows: [Row]
    /// Column widths, and the x each starts at.
    let columns: [CGFloat]
    let columnX: [CGFloat]
    let alignments: [PlanTable.Alignment]
    let width: CGFloat
    let height: CGFloat
    let padding: CGSize
    /// The last row that is drawn.
    let lastVisible: Int

    init(rows: [Row], columns: [CGFloat], alignments: [PlanTable.Alignment], padding: CGSize) {
        self.rows = rows
        self.columns = columns
        self.alignments = alignments
        self.padding = padding
        var x: CGFloat = 0
        var starts: [CGFloat] = []
        for column in columns { starts.append(x); x += column }
        columnX = starts
        width = x
        height = rows.last.map { $0.top + $0.height } ?? 0
        lastVisible = rows.lastIndex { !$0.isHidden } ?? 0
    }

    // MARK: Building

    /// What the delimiter row's line is told to be: a hairline, not zero (a zero maximum line
    /// height means "no maximum").
    static let hiddenHeight: CGFloat = 0.01

    private static let cache: NSCache<NSString, PlanTableLayout> = {
        let cache = NSCache<NSString, PlanTableLayout>()
        cache.countLimit = 256
        return cache
    }()

    /// The layout of `table` (parsed from `u`) in `available` points of width.
    static func cached(_ table: PlanTable, _ u: [UInt16], theme: PlanTheme, available: CGFloat) -> PlanTableLayout {
        let source = String(utf16CodeUnits: u, count: u.count)
        let key = "\(Int(available.rounded()))|\(theme.body.pointSize)|\(theme.tablePadding.width)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let layout = make(table, u, theme: theme, available: available)
        cache.setObject(layout, forKey: key)
        return layout
    }

    /// Layouts built, cache hits not counted — for tests of what a keystroke costs.
    nonisolated(unsafe) private(set) static var built = 0

    static func make(_ table: PlanTable, _ u: [UInt16], theme: PlanTheme, available: CGFloat) -> PlanTableLayout {
        built += 1
        let basePad = theme.tablePadding
        let count = table.columnCount
        // Every row's cells, styled, padded to the column count.
        var styled: [[Cell]] = []
        for (r, row) in table.rows.enumerated() {
            var cells: [Cell] = []
            for c in 0..<count {
                cells.append(c < row.cells.count
                    ? cell(u, row.cells[c], lineStart: row.line.location, header: r == 0, alignment: table.alignments[c], theme)
                    : Cell(text: NSAttributedString(), map: [], sourceStart: row.line.length, sourceEnd: row.line.length))
            }
            styled.append(cells)
        }
        // Natural width: the cell on one line. Minimum: its longest word.
        var natural = [CGFloat](repeating: 0, count: count)
        var longest = [CGFloat](repeating: 0, count: count)
        for (r, cells) in styled.enumerated() where r != PlanTable.delimiterRow {
            for (c, cell) in cells.enumerated() where cell.text.length > 0 {
                natural[c] = max(natural[c], ceil(measure(cell.text, width: 100_000).width))
                longest[c] = max(longest[c], ceil(longestWord(cell.text)))
            }
        }
        /// The columns at a cell padding: the table's own width is the room it has, and only when
        /// even every column's longest word won't fit does it give up some padding, then words.
        func fit(_ padX: CGFloat) -> (widths: [CGFloat], needsBreaks: Bool) {
            let floorWidth = 2 * padX + theme.body.pointSize * 1.5
            let n = natural.map { max($0 + 2 * padX, floorWidth) }
            let m = zip(longest, n).map { min(max($0 + 2 * padX, floorWidth), $1) }
            return (columnWidths(natural: n, minimum: m, available: available), m.reduce(0, +) > available)
        }
        var padX = basePad.width
        var fitted = fit(padX)
        for squeeze in [0.6, 0.4] where fitted.needsBreaks {
            padX = basePad.width * squeeze
            fitted = fit(padX)
        }
        let widths = fitted.widths
        let pad = CGSize(width: padX, height: basePad.height)

        var rows: [Row] = []
        var top: CGFloat = 0
        for (r, cells) in styled.enumerated() {
            let hidden = r == PlanTable.delimiterRow
            var height: CGFloat = 0
            if !hidden {
                for (c, cell) in cells.enumerated() where cell.text.length > 0 {
                    height = max(height, ceil(measure(cell.text, width: widths[c] - 2 * pad.width).height))
                }
                height = max(height, ceil(theme.body.ascender - theme.body.descender + theme.body.leading)) + 2 * pad.height
            }
            rows.append(Row(top: top, height: hidden ? hiddenHeight : height, cells: cells, isHeader: r == 0, isHidden: hidden))
            top += hidden ? hiddenHeight : height
        }
        return PlanTableLayout(rows: rows, columns: widths, alignments: table.alignments, padding: pad)
    }

    /// Column widths for `available` points: a column keeps its natural width unless the table
    /// is too wide for the room; then the long columns are capped at one shared width — the
    /// "water level" at which the table fits — and the short ones stay as they are. No column
    /// goes below its `minimum` (its longest word) unless even those won't fit, when they all
    /// shrink together. A table with room to spare is as wide as its content, not stretched.
    static func columnWidths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        if natural.reduce(0, +) <= available { return natural }
        let floors = zip(natural, minimum).map { min($0, $1) }
        let floorTotal = floors.reduce(0, +)
        // A level `L` at which `Σ min(width, max(floor, L))` is the room: the cap of the long columns.
        func level(_ total: (CGFloat) -> CGFloat, upTo top: CGFloat) -> CGFloat {
            var lo: CGFloat = 0, hi = top
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if total(mid) > available { hi = mid } else { lo = mid }
            }
            return lo
        }
        if floorTotal >= available {
            // Not even the words fit: the widest words break first, and the short ones stay whole.
            let cap = level({ level in floors.reduce(0) { $0 + min($1, level) } }, upTo: floors.max() ?? 0)
            return floors.map { min($0, cap) }
        }
        let cap = level({ level in zip(natural, floors).reduce(0) { $0 + min($1.0, max($1.1, level)) } }, upTo: natural.max() ?? 0)
        return zip(natural, floors).map { min($0, max($1, cap)) }
    }

    private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        text.boundingRect(with: CGSize(width: max(width, 1), height: 100_000), options: drawOptions).size
    }

    fileprivate static let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private static func longestWord(_ text: NSAttributedString) -> CGFloat {
        let ns = text.string as NSString
        var best = NSRange(location: 0, length: 0)
        var from = 0
        while from <= ns.length {
            var end = ns.rangeOfCharacter(from: .whitespaces, range: NSRange(location: from, length: ns.length - from)).location
            if end == NSNotFound { end = ns.length }
            if end - from > best.length { best = NSRange(location: from, length: end - from) }
            from = end + 1
        }
        return best.length == 0 ? 0 : measure(text.attributedSubstring(from: best), width: 100_000).width
    }

    /// One cell's text as the grid shows it: the source less its Markdown delimiters and the
    /// backslash of an escaped pipe, with the inline styling the rest of the editor gives it.
    private static func cell(_ u: [UInt16], _ cell: PlanTable.Cell, lineStart: Int, header: Bool,
                             alignment: PlanTable.Alignment, _ theme: PlanTheme) -> Cell {
        let a = cell.range.location, b = NSMaxRange(cell.range)
        var dropped = [Bool](repeating: false, count: b - a)
        for r in cell.syntax { for i in max(r.location, a)..<min(NSMaxRange(r), b) { dropped[i - a] = true } }
        if b - a >= 2 { for i in a..<b - 1 where u[i] == 92 && u[i + 1] == 124 { dropped[i - a] = true } }
        var chars: [UInt16] = []
        var map: [Int] = []
        // `before[k]`: display characters ahead of source offset `a + k`.
        var before = [Int](repeating: 0, count: b - a + 1)
        for i in a..<b {
            before[i - a] = chars.count
            if !dropped[i - a] { chars.append(u[i]); map.append(i - lineStart) }
        }
        before[b - a] = chars.count

        let font = header ? NSFont.systemFont(ofSize: theme.body.pointSize, weight: .semibold) : theme.body
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = theme.lineSpacing * 0.5
        para.alignment = alignment == .center ? .center : alignment == .right ? .right : .left
        let text = NSMutableAttributedString(string: String(utf16CodeUnits: chars, count: chars.count),
                                             attributes: [.font: font, .foregroundColor: theme.text, .paragraphStyle: para])
        for span in cell.spans {
            let range = NSRange(location: before[span.range.location - a], length: before[NSMaxRange(span.range) - a] - before[span.range.location - a])
            guard range.length > 0 else { continue }
            switch span.kind {
            case .bold:
                text.addAttribute(.font, value: header ? NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                                  : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
            case .italic: text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: range)
            case .code:
                text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                                    .backgroundColor: theme.codeBackground], range: range)
            case .link: text.addAttribute(.foregroundColor, value: theme.link, range: range)
            }
        }
        return Cell(text: text, map: map, sourceStart: cell.range.location - lineStart, sourceEnd: b - lineStart)
    }

    // MARK: Drawing

    /// Row `index` with its top-left corner at `origin` (flipped coordinates). A row paints its
    /// own share of the table's frame, so rows drawn by separate fragments meet without a seam:
    /// the rounded border is the whole table's, clipped to this row.
    func draw(row index: Int, at origin: CGPoint, in context: CGContext, theme: PlanTheme, tint: NSColor? = nil, selected: Bool = false) {
        let row = rows[index]
        guard !row.isHidden else { return }
        let band = CGRect(x: origin.x - 1, y: origin.y, width: width + 2, height: row.height)
        let frame = CGRect(x: origin.x, y: origin.y - row.top, width: width, height: height)
        let outline = CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: theme.tableRadius, cornerHeight: theme.tableRadius, transform: nil)

        context.saveGState()
        context.clip(to: band)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: theme.tableRadius, cornerHeight: theme.tableRadius, transform: nil))
        context.clip()
        if row.isHeader {
            context.setFillColor(theme.tableHeaderBackground.cgColor)
            context.fill(band)
        }
        if let tint {
            context.setFillColor(tint.cgColor)
            context.fill(band)
        }
        if selected {
            context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).cgColor)
            context.fill(band)
        }
        context.restoreGState()

        context.saveGState()
        context.clip(to: band)
        context.setLineWidth(1)
        context.setStrokeColor(theme.tableBorder.cgColor)
        // Between the table's own top and bottom edges, which are the outline's.
        let top = origin.y + (index == 0 ? 1 : 0), bottom = origin.y + row.height - (index == lastVisible ? 1 : 0)
        for x in columnX.dropFirst() {
            let line = origin.x + x.rounded() + 0.5
            context.move(to: CGPoint(x: line, y: top))
            context.addLine(to: CGPoint(x: line, y: bottom))
        }
        if index != lastVisible, !row.isHeader {
            context.move(to: CGPoint(x: origin.x, y: origin.y + row.height - 0.5))
            context.addLine(to: CGPoint(x: origin.x + width, y: origin.y + row.height - 0.5))
        }
        context.strokePath()
        if row.isHeader, index != lastVisible {
            // The rule under the header, a step darker than the grid.
            context.setLineWidth(1)
            context.setStrokeColor(theme.tableHeaderRule.cgColor)
            context.move(to: CGPoint(x: origin.x, y: origin.y + row.height - 0.5))
            context.addLine(to: CGPoint(x: origin.x + width, y: origin.y + row.height - 0.5))
            context.strokePath()
        }
        context.setLineWidth(1)
        context.setStrokeColor(theme.tableBorder.cgColor)
        context.addPath(outline)
        context.strokePath()
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (c, cell) in row.cells.enumerated() where cell.text.length > 0 {
            let rect = CGRect(x: origin.x + columnX[c] + padding.width, y: origin.y + padding.height,
                              width: columns[c] - 2 * padding.width, height: row.height - 2 * padding.height)
            cell.text.draw(with: rect, options: Self.drawOptions)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Hit-testing

    /// Where in the source a click at `point` — x from the table's left edge, y from the top of
    /// row `index` — puts the caret: the character under it in that cell's text, or the cell's
    /// end when the click is past its words. From the row's line start. Nil outside the table.
    func sourceOffset(row index: Int, at point: CGPoint) -> Int? {
        guard rows.indices.contains(index), !rows[index].isHidden, point.x >= 0, point.x <= width,
              let column = columnX.lastIndex(where: { $0 <= point.x }) else { return nil }
        let cell = rows[index].cells[column]
        guard cell.text.length > 0 else { return cell.sourceStart }
        let storage = NSTextStorage(attributedString: cell.text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: columns[column] - 2 * padding.width, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let local = CGPoint(x: point.x - columnX[column] - padding.width, y: point.y - padding.height)
        let used = manager.usedRect(for: container)
        // Past the last line or the last word: the cell's end.
        guard local.y <= used.maxY else { return cell.sourceEnd }
        var fraction: CGFloat = 0
        let at = manager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard at < cell.map.count else { return cell.sourceEnd }
        return cell.map[at] + (fraction > 0.5 ? 1 : 0)
    }
}

/// A table source line's place in its laid-out grid — the value of `.planTableRow`, which the
/// styler puts on a row's line when the table is drawn as a grid and `EditLayerFragment` reads.
final class PlanTableRowRef: NSObject {
    let layout: PlanTableLayout
    let row: Int

    init(layout: PlanTableLayout, row: Int) {
        self.layout = layout
        self.row = row
    }
}

extension NSAttributedString.Key {
    /// A table row's line while the table is drawn as a grid (`PlanTableRowRef`): the line's
    /// text is hidden and `EditLayerFragment` draws the row's cells in its place.
    static let planTableRow = NSAttributedString.Key("FlightDeck.planTableRow")
}
