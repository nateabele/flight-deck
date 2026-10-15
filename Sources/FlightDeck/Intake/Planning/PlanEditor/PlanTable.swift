import AppKit
import FleetKit

/// A pipe table in the editor: `PipeTable`'s rows and cells (FleetKit, shared with the phone's
/// reader), each cell with the inline Markdown the rest of the editor styles — bold, italic,
/// `code`, links — found by the same pass (`MarkdownStyler.inline`). Offsets are UTF-16 units
/// from the start of the block's text, so the same table anywhere in the plan parses the same.
struct PlanTable {
    typealias Alignment = PipeTable.Alignment

    struct Cell {
        /// The cell's content, trimmed of the spaces around it.
        let range: NSRange
        /// Inline Markdown inside it, and the delimiters it hides.
        let spans: [MarkdownSpan]
        let syntax: [NSRange]
    }

    struct Row {
        /// The row's line, without its newline.
        let line: NSRange
        let cells: [Cell]
    }

    let rows: [Row]
    let alignments: [Alignment]
    var columnCount: Int { alignments.count }
    /// The delimiter row: never drawn.
    static let delimiterRow = PipeTable.delimiterRow

    /// Nil when it is not a table (no delimiter row): the editor shows its lines as plain source.
    static func parse(_ u: [UInt16]) -> PlanTable? {
        guard let table = PipeTable.parse(u) else { return nil }
        let rows = table.rows.enumerated().map { i, row in
            Row(line: row.line, cells: row.cells.map { range in
                var spans: [MarkdownSpan] = []
                var syntax: [NSRange] = []
                // The delimiter row's cells are never drawn; their dashes are not Markdown.
                if i != delimiterRow { MarkdownStyler.inline(u, range.location, NSMaxRange(range), spans: &spans, syntax: &syntax) }
                return Cell(range: range, spans: spans, syntax: syntax)
            })
        }
        return PlanTable(rows: rows, alignments: table.alignments)
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
        /// A ghost character (words the edit layer shows as removed) is not in the source: it
        /// carries the place the words were.
        let map: [Int]
        /// Display characters that are ghosts.
        let ghost: [Bool]
        /// The cell's source extent, from the row's line start: where a click on empty space goes.
        let sourceStart: Int
        let sourceEnd: Int

        init(text: NSAttributedString, map: [Int], ghost: [Bool]? = nil, sourceStart: Int, sourceEnd: Int) {
            self.text = text
            self.map = map
            self.ghost = ghost ?? [Bool](repeating: false, count: map.count)
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
        }

        var hasGhost: Bool { ghost.contains(true) }
    }

    /// A removed row, drawn struck through above or below a real one.
    struct GhostRow {
        let cells: [Cell]
        let height: CGFloat
    }

    struct Row {
        /// The row's band: any removed rows above it, the row, any below. `top` and `height` are
        /// the band's — what the source line is held to.
        let top: CGFloat
        let height: CGFloat
        let above: [GhostRow]
        let below: [GhostRow]
        let cells: [Cell]
        let isHeader: Bool
        /// The delimiter row, which takes no room.
        let isHidden: Bool
        /// The row's own length, from its line start.
        let lineLength: Int

        /// The row itself within its band.
        var bodyTop: CGFloat { above.reduce(0) { $0 + $1.height } }
        var bodyHeight: CGFloat { height - bodyTop - below.reduce(0) { $0 + $1.height } }
        /// Words were removed from one of its cells.
        var hasGhost: Bool { cells.contains { $0.hasGhost } }
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
    let theme: PlanTheme

    init(rows: [Row], columns: [CGFloat], alignments: [PlanTable.Alignment], padding: CGSize, theme: PlanTheme = .standard) {
        self.rows = rows
        self.columns = columns
        self.alignments = alignments
        self.padding = padding
        self.theme = theme
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

    /// The layout of `table` (parsed from `u`) in `available` points of width, with room for the
    /// words and rows the edit layer removed (`marks`).
    static func cached(_ table: PlanTable, _ u: [UInt16], theme: PlanTheme, available: CGFloat,
                       marks: PlanTableMarks = .none) -> PlanTableLayout {
        let source = String(utf16CodeUnits: u, count: u.count)
        let key = "\(Int(available.rounded()))|\(theme.body.pointSize)|\(theme.tablePadding.width)|\(marks.key)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let layout = make(table, u, theme: theme, available: available, marks: marks)
        cache.setObject(layout, forKey: key)
        return layout
    }

    /// Layouts built, cache hits not counted — for tests of what a keystroke costs.
    nonisolated(unsafe) private(set) static var built = 0

    static func make(_ table: PlanTable, _ u: [UInt16], theme: PlanTheme, available: CGFloat,
                     marks: PlanTableMarks = .none) -> PlanTableLayout {
        built += 1
        let basePad = theme.tablePadding
        let count = table.columnCount
        // Every row's cells, styled, padded to the column count.
        var styled: [[Cell]] = []
        for (r, row) in table.rows.enumerated() {
            var cells: [Cell] = []
            let ghosts = marks.inline.filter { $0.row == r }
            for c in 0..<count {
                cells.append(c < row.cells.count
                    ? cell(u, row.cells[c], lineStart: row.line.location, header: r == 0, alignment: table.alignments[c], theme,
                           ghosts: ghosts.filter { $0.column == c })
                    : Cell(text: NSAttributedString(), map: [], sourceStart: row.line.length, sourceEnd: row.line.length))
            }
            styled.append(cells)
        }
        // Removed rows sit above the row they were before, or below the last one drawn.
        let lastDrawn = table.rows.indices.last { $0 != PlanTable.delimiterRow } ?? 0
        var removed: [Int: (above: [[Cell]], below: [[Cell]])] = [:]
        for ghost in marks.rows {
            let below = ghost.before >= table.rows.count
            let row = below ? lastDrawn : ghost.before
            for line in ghost.lines {
                let cells = ghostCells(line, count: count, alignments: table.alignments, theme)
                if below { removed[row, default: ([], [])].below.append(cells) } else { removed[row, default: ([], [])].above.append(cells) }
            }
        }
        // Natural width: the cell on one line. Minimum: its longest word.
        var natural = [CGFloat](repeating: 0, count: count)
        var longest = [CGFloat](repeating: 0, count: count)
        let extra = removed.values.flatMap { $0.above + $0.below }
        for cells in styled.enumerated().filter({ $0.offset != PlanTable.delimiterRow }).map(\.element) + extra {
            for (c, cell) in cells.enumerated() where cell.text.length > 0 {
                natural[c] = max(natural[c], ceil(measure(cell.text, width: 100_000).width))
                longest[c] = max(longest[c], ceil(longestWord(cell.text)))
            }
        }
        let fitted = PipeTable.fit(natural: natural.map(Double.init), longestWord: longest.map(Double.init),
                                   available: Double(available), padding: Double(basePad.width),
                                   minimumContent: Double(theme.body.pointSize * 1.5), breakWords: true)
        let widths = fitted.widths.map { CGFloat($0) }
        let pad = CGSize(width: CGFloat(fitted.padding), height: basePad.height)

        func rowHeight(_ cells: [Cell]) -> CGFloat {
            var height: CGFloat = 0
            for (c, cell) in cells.enumerated() where cell.text.length > 0 {
                height = max(height, ceil(measure(cell.text, width: widths[c] - 2 * pad.width).height))
            }
            return max(height, ceil(theme.body.ascender - theme.body.descender + theme.body.leading)) + 2 * pad.height
        }
        func ghostRows(_ lines: [[Cell]]) -> [GhostRow] { lines.map { GhostRow(cells: $0, height: rowHeight($0)) } }

        var rows: [Row] = []
        var top: CGFloat = 0
        for (r, cells) in styled.enumerated() {
            let hidden = r == PlanTable.delimiterRow
            let above = ghostRows(removed[r]?.above ?? []), below = ghostRows(removed[r]?.below ?? [])
            let height = hidden ? hiddenHeight
                : above.reduce(0) { $0 + $1.height } + rowHeight(cells) + below.reduce(0) { $0 + $1.height }
            rows.append(Row(top: top, height: height, above: above, below: below, cells: cells, isHeader: r == 0, isHidden: hidden,
                            lineLength: table.rows[r].line.length))
            top += height
        }
        return PlanTableLayout(rows: rows, columns: widths, alignments: table.alignments, padding: pad, theme: theme)
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

    private static func paragraphStyle(_ theme: PlanTheme, _ alignment: PlanTable.Alignment) -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = theme.lineSpacing * 0.5
        para.alignment = alignment == .center ? .center : alignment == .right ? .right : .left
        return para
    }

    /// One cell's text as the grid shows it: the source less its Markdown delimiters and the
    /// backslash of an escaped pipe, with the inline styling the rest of the editor gives it —
    /// and `ghosts`, words the edit layer removed, struck through where they were (`offset`
    /// counts the shown characters ahead of them).
    private static func cell(_ u: [UInt16], _ cell: PlanTable.Cell, lineStart: Int, header: Bool,
                             alignment: PlanTable.Alignment, _ theme: PlanTheme, ghosts: [PlanTableMarks.Ghost] = []) -> Cell {
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

        let font = header ? PlanTheme.serif(theme.body.pointSize, weight: .semibold) : theme.body
        let para = paragraphStyle(theme, alignment)
        let text = NSMutableAttributedString(string: String(utf16CodeUnits: chars, count: chars.count),
                                             attributes: [.font: font, .foregroundColor: theme.text, .paragraphStyle: para])
        for span in cell.spans {
            let range = NSRange(location: before[span.range.location - a], length: before[NSMaxRange(span.range) - a] - before[span.range.location - a])
            guard range.length > 0 else { continue }
            switch span.kind {
            case .bold:
                text.addAttribute(.font, value: header ? PlanTheme.serif(font.pointSize, weight: .bold)
                                  : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
            case .italic: text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: range)
            case .code:
                text.addAttributes([.font: theme.codeSpan(in: font),
                                    .backgroundColor: theme.codeBackground], range: range)
            case .link: text.addAttribute(.foregroundColor, value: theme.link, range: range)
            }
        }

        // The removed words go in last, so the styling above found its characters where they
        // were. Latest first, so an insertion leaves the offsets of the ones before it alone.
        var isGhost = [Bool](repeating: false, count: map.count)
        for ghost in ghosts.enumerated().sorted(by: { ($0.element.offset, $0.offset) > ($1.element.offset, $1.offset) }).map(\.element) {
            let k = min(max(ghost.offset, 0), text.length)
            let words = EditGhost(text: ghost.text, font: text.length == 0 ? font : text.attribute(.font, at: min(k, text.length - 1), effectiveRange: nil) as? NSFont ?? font,
                                  placement: .inline).attributed(ghost.text)
            let struck = NSMutableAttributedString(attributedString: words)
            struck.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: struck.length))
            // The same air round them as in a paragraph (`EditGhost.room`).
            struck.addAttribute(.kern, value: 3, range: NSRange(location: struck.length - 1, length: 1))
            if k > 0 { text.addAttribute(.kern, value: 3, range: NSRange(location: k - 1, length: 1)) }
            text.insert(struck, at: k)
            map.insert(contentsOf: [Int](repeating: k < map.count ? map[k] : b - lineStart, count: struck.length), at: k)
            isGhost.insert(contentsOf: [Bool](repeating: true, count: struck.length), at: k)
        }
        return Cell(text: text, map: map, ghost: isGhost, sourceStart: cell.range.location - lineStart, sourceEnd: b - lineStart)
    }

    /// The cells of a removed row: the line read as the row it was, struck through like removed
    /// words (`EditGhost`) but for the tint, which the row has as a whole.
    private static func ghostCells(_ line: String, count: Int, alignments: [PlanTable.Alignment], _ theme: PlanTheme) -> [Cell] {
        let u = Array((line + "\n" + String(repeating: "|---", count: max(count, 1)) + "|").utf16)
        let pieces = PlanTable.parse(u)?.rows.first?.cells ?? []
        var strike = EditGhost(text: "", font: theme.body, placement: .above).attributed("x").attributes(at: 0, effectiveRange: nil)
        strike[.font] = nil
        strike[.backgroundColor] = nil
        return (0..<count).map { c in
            guard c < pieces.count, pieces[c].range.length > 0 else { return Cell(text: NSAttributedString(), map: [], sourceStart: 0, sourceEnd: 0) }
            let text = NSMutableAttributedString(attributedString: cell(u, pieces[c], lineStart: 0, header: false, alignment: alignments[c], theme).text)
            let all = NSRange(location: 0, length: text.length)
            text.removeAttribute(.backgroundColor, range: all)
            text.addAttributes(strike, range: all)
            return Cell(text: text, map: [Int](repeating: 0, count: text.length), ghost: [Bool](repeating: true, count: text.length),
                        sourceStart: 0, sourceEnd: 0)
        }
    }

    // MARK: Drawing

    /// A colour laid over a span of a row's source (offsets from the row's line start, and may
    /// reach past it): what the decoration layers tint — the edit layer's insertions, the churn
    /// wash, a note's highlight. A row's source is hidden, so the grid paints it in the cells
    /// the span reaches (`paintFills`).
    typealias Fill = (range: NSRange, color: NSColor)

    /// Row `index` with its top-left corner at `origin` (flipped coordinates). A row paints its
    /// own share of the table's frame, so rows drawn by separate fragments meet without a seam:
    /// the rounded border is the whole table's, clipped to this row.
    func draw(row index: Int, at origin: CGPoint, in context: CGContext, theme: PlanTheme, fills: [Fill] = []) {
        let row = rows[index]
        guard !row.isHidden else { return }
        let band = CGRect(x: origin.x - 1, y: origin.y, width: width + 2, height: row.height)
        let frame = CGRect(x: origin.x, y: origin.y - row.top, width: width, height: height)
        let outline = CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: theme.tableRadius, cornerHeight: theme.tableRadius, transform: nil)

        // The band's parts, top down: removed rows above, the row, removed rows below.
        var parts: [(top: CGFloat, height: CGFloat, cells: [Cell], removed: Bool)] = []
        var y = origin.y
        for ghost in row.above { parts.append((y, ghost.height, ghost.cells, true)); y += ghost.height }
        let body = CGRect(x: origin.x - 1, y: y, width: width + 2, height: row.bodyHeight)
        parts.append((y, row.bodyHeight, row.cells, false))
        y += row.bodyHeight
        for ghost in row.below { parts.append((y, ghost.height, ghost.cells, true)); y += ghost.height }

        context.saveGState()
        context.clip(to: band)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: theme.tableRadius, cornerHeight: theme.tableRadius, transform: nil))
        context.clip()
        if row.isHeader {
            context.setFillColor(theme.tableHeaderBackground.cgColor)
            context.fill(body)
        }
        // A removed row is tinted whole, as a paragraph's removed words are (`EditGhost.attributed`).
        context.setFillColor(EditLayer.deletedColor.withAlphaComponent(0.1).cgColor)
        for part in parts where part.removed { context.fill(CGRect(x: origin.x - 1, y: part.top, width: width + 2, height: part.height)) }
        paintFills(row: index, at: origin, fills: fills, in: context)
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
        // A rule under each part of the band; under the band itself too, but the table's last
        // row (the outline) and the header (its own, darker rule, below).
        var rules = parts.dropLast().map { $0.top + $0.height }
        if index != lastVisible, !row.isHeader { rules.append(origin.y + row.height) }
        for rule in rules {
            context.move(to: CGPoint(x: origin.x, y: rule - 0.5))
            context.addLine(to: CGPoint(x: origin.x + width, y: rule - 0.5))
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
        for part in parts {
            for (c, cell) in part.cells.enumerated() where cell.text.length > 0 {
                let rect = CGRect(x: origin.x + columnX[c] + padding.width, y: part.top + padding.height,
                                  width: columns[c] - 2 * padding.width, height: part.height - 2 * padding.height)
                cell.text.draw(with: rect, options: Self.drawOptions)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The fills under a row's words, cell by cell: a span over the whole line is the whole row;
    /// one over all of a cell's words is the cell; any other is the words it reaches, line by
    /// line — the same fill a paragraph's text gets.
    private func paintFills(row index: Int, at origin: CGPoint, fills: [Fill], in context: CGContext) {
        let row = rows[index]
        let bodyY = origin.y + row.bodyTop
        for (range, color) in fills where range.length > 0 {
            context.setFillColor(color.cgColor)
            if range.location <= 0, NSMaxRange(range) >= row.lineLength {
                context.fill(CGRect(x: origin.x - 1, y: bodyY, width: width + 2, height: row.bodyHeight))
                continue
            }
            for (c, cell) in row.cells.enumerated() {
                let runs = Self.runs(of: cell, in: range)
                guard !runs.isEmpty else { continue }
                if runs.reduce(0, { $0 + $1.length }) == cell.ghost.filter({ !$0 }).count {
                    context.fill(CGRect(x: origin.x + columnX[c], y: bodyY, width: columns[c], height: row.bodyHeight))
                    continue
                }
                let text = cellText(row: index, column: c)
                for run in runs {
                    for rect in text.rects(for: run) {
                        context.fill(rect.insetBy(dx: -1, dy: 0).offsetBy(dx: origin.x + columnX[c] + padding.width, dy: bodyY + padding.height))
                    }
                }
            }
        }
    }

    /// The runs of `cell`'s display characters that come from the source in `range` — never a
    /// ghost, which was not there to be changed.
    static func runs(of cell: Cell, in range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var start: Int?
        for i in 0...cell.map.count {
            let inside = i < cell.map.count && !cell.ghost[i] && NSLocationInRange(cell.map[i], range)
            if inside, start == nil { start = i }
            if !inside, let from = start { out.append(NSRange(location: from, length: i - from)); start = nil }
        }
        return out
    }

    // MARK: Cell text

    /// A cell's text in TextKit 1: the boxes of a span of it, where `NSAttributedString.draw`,
    /// which paints it, can't say. Made when first asked, kept with the layout.
    final class CellText {
        private let manager = NSLayoutManager()
        private let container: NSTextContainer
        private let storage: NSTextStorage

        init(_ text: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: text)
            container = NSTextContainer(size: CGSize(width: max(width, 1), height: 100_000))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }

        /// The boxes of the text in `range`, one per line, each the height of its line's text
        /// (not the leading under it), in the cell text's own coordinates.
        func rects(for range: NSRange) -> [CGRect] {
            guard range.length > 0, manager.numberOfGlyphs > 0 else { return [] }
            var lines: [CGRect] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, used, _, _, _ in
                lines.append(used)
            }
            var out: [CGRect] = []
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                let line = lines.first { rect.midY >= $0.minY && rect.midY <= $0.maxY + 0.5 } ?? rect
                out.append(CGRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height))
            }
            return out
        }
    }

    private var cellTexts: [Int: CellText] = [:]

    private func cellText(row: Int, column: Int) -> CellText {
        let key = row * 4096 + column
        if let hit = cellTexts[key] { return hit }
        let made = CellText(rows[row].cells[column].text, width: columns[column] - 2 * padding.width)
        cellTexts[key] = made
        return made
    }

    // MARK: Hit-testing

    /// Where in the source a click at `point` — x from the table's left edge, y from the top of
    /// row `index`'s band — puts the caret: the character under it in that cell's text, or the
    /// cell's end when the click is past its words. From the row's line start. Nil outside the
    /// table.
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
        let local = CGPoint(x: point.x - columnX[column] - padding.width, y: max(point.y, rows[index].bodyTop) - rows[index].bodyTop - padding.height)
        let used = manager.usedRect(for: container)
        // Past the last line or the last word: the cell's end.
        guard local.y <= used.maxY else { return cell.sourceEnd }
        var fraction: CGFloat = 0
        let at = manager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard at < cell.map.count else { return cell.sourceEnd }
        return cell.map[at] + (fraction > 0.5 && !cell.ghost[at] ? 1 : 0)
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
