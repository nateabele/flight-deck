import AppKit
import ObjectiveC

/// A cell's text in TextKit 1, for the questions a cell is asked that drawing doesn't answer:
/// where a character is, which character a point is on, which lines it wraps to. Made when first
/// asked and kept with its table's layout.
final class PlanCellText {
    let text: NSAttributedString
    let width: CGFloat
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private let storage: NSTextStorage
    private let emptyFont: NSFont
    private let alignment: NSTextAlignment

    init(_ text: NSAttributedString, width: CGFloat, font: NSFont, alignment: NSTextAlignment) {
        self.text = text
        self.width = width
        emptyFont = font
        self.alignment = alignment
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: max(width, 1), height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    /// The caret at display position `index`: x, the top of the text's line, and the text's height.
    func caret(at index: Int) -> CGRect {
        let length = text.length
        let fontAt = length == 0 ? emptyFont
            : (text.attribute(.font, at: min(max(index, 0), length - 1), effectiveRange: nil) as? NSFont ?? emptyFont)
        let height = ceil(fontAt.ascender - fontAt.descender)
        if length == 0 {
            let x: CGFloat = alignment == .center ? width / 2 : alignment == .right ? width : 0
            return CGRect(x: x, y: 0, width: 0, height: height)
        }
        let at = min(max(index, 0), length)
        let glyph: Int
        let x: CGFloat
        if at < length {
            glyph = manager.glyphIndexForCharacter(at: at)
            x = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
        } else {
            glyph = max(manager.numberOfGlyphs - 1, 0)
            x = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + manager.location(forGlyphAt: glyph).y
        return CGRect(x: x, y: baseline - fontAt.ascender, width: 0, height: height)
    }

    /// The display position nearest `point`.
    func index(at point: CGPoint) -> Int {
        guard text.length > 0 else { return 0 }
        var fraction: CGFloat = 0
        let at = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        if at >= text.length { return text.length }
        return at + (fraction > 0.5 ? 1 : 0)
    }

    var usedHeight: CGFloat { ceil(manager.usedRect(for: container).height) }

    /// Each line's character range and the box of its text.
    var lines: [(range: NSRange, box: CGRect)] {
        var out: [(NSRange, CGRect)] = []
        guard manager.numberOfGlyphs > 0 else { return [] }
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, used, _, glyphs, _ in
            out.append((self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), used))
        }
        return out
    }

    /// The boxes of the text in `range`, one per line, at the text's own height.
    func rects(for range: NSRange) -> [CGRect] {
        guard range.length > 0, manager.numberOfGlyphs > 0 else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let lines = self.lines
        var out: [CGRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
            let line = lines.first { rect.midY >= $0.box.minY && rect.midY <= $0.box.maxY + 0.5 }?.box ?? rect
            out.append(CGRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height))
        }
        return out
    }
}

/// Where things are on a laid-out grid, for the editor: a place in a cell's shown text to a box,
/// a point to a place. Coordinates are the table's own: x from its left edge, y from the top of
/// the row's band. The mapping between the source and a cell's shown text is
/// `PlanTableEditing`'s; this is only geometry.
extension PlanTableLayout {
    private static var textsKey = 0

    private final class Texts { var byCell: [Int: PlanCellText] = [:] }

    private var texts: Texts {
        if let hit = objc_getAssociatedObject(self, &Self.textsKey) as? Texts { return hit }
        let made = Texts()
        objc_setAssociatedObject(self, &Self.textsKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    func gridText(row: Int, column: Int) -> PlanCellText {
        let key = row * 4096 + column
        if let hit = texts.byCell[key] { return hit }
        let alignment: NSTextAlignment = alignments[column] == .center ? .center : alignments[column] == .right ? .right : .left
        let theme = PlanTheme.standard
        let font = row == 0 ? PlanTheme.serif(theme.body.pointSize, weight: .semibold) : theme.body
        let made = PlanCellText(rows[row].cells[column].text, width: columns[column] - 2 * padding.width, font: font, alignment: alignment)
        texts.byCell[key] = made
        return made
    }

    /// The cell's box, in its row's band: below any removed rows above it.
    func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(x: columnX[column], y: rows[row].bodyTop, width: columns[column], height: rows[row].bodyHeight)
    }

    func textOrigin(row: Int, column: Int) -> CGPoint {
        CGPoint(x: columnX[column] + padding.width, y: rows[row].bodyTop + padding.height)
    }

    // The model counts a cell's shown characters; the cell's display text also holds the words
    // the edit layer shows as removed. A caret is never among those.

    /// The display position of the caret `shown` real characters in: ahead of any removed words
    /// there.
    func displayCaret(row: Int, column: Int, shown: Int) -> Int {
        let cell = rows[row].cells[column]
        var real = 0
        for i in 0..<cell.text.length {
            if !cell.ghost[i] { if real == shown { return i }; real += 1 }
        }
        return cell.text.length
    }

    /// The display position of the real character `shown`, past any removed words before it.
    func displayStart(row: Int, column: Int, shown: Int) -> Int {
        let cell = rows[row].cells[column]
        var real = 0
        for i in 0..<cell.text.length where !cell.ghost[i] {
            if real == shown { return i }
            real += 1
        }
        return cell.text.length
    }

    /// The real characters before display position `at`.
    func shown(row: Int, column: Int, display at: Int) -> Int {
        let cell = rows[row].cells[column]
        return (0..<min(at, cell.text.length)).filter { !cell.ghost[$0] }.count
    }

    /// The caret at `shown` characters into a cell's shown text. A caret past the words (spaces
    /// typed after them) is `extraSpaces` spaces on.
    func caretRect(row: Int, column: Int, shown: Int, extraSpaces: Int = 0) -> CGRect {
        let text = gridText(row: row, column: column)
        var box = text.caret(at: displayCaret(row: row, column: column, shown: shown))
        if extraSpaces > 0, text.text.length > 0 {
            let font = (text.text.attribute(.font, at: text.text.length - 1, effectiveRange: nil) as? NSFont) ?? PlanTheme.standard.body
            let space = (" " as NSString).size(withAttributes: [.font: font]).width
            box.origin.x = min(box.origin.x + CGFloat(extraSpaces) * space, text.width)
        }
        let origin = textOrigin(row: row, column: column)
        return box.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The boxes of the shown text in `range` of a cell.
    func textRects(row: Int, column: Int, shown range: NSRange) -> [CGRect] {
        let origin = textOrigin(row: row, column: column)
        let from = displayStart(row: row, column: column, shown: range.location)
        let to = displayCaret(row: row, column: column, shown: NSMaxRange(range))
        return gridText(row: row, column: column).rects(for: NSRange(location: from, length: max(to - from, 0)))
            .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// The column at `x` and the shown offset nearest `point`; nil outside the table. A point in a
    /// removed row above or below the row counts as on the row itself.
    func hit(row: Int, at point: CGPoint) -> (column: Int, shown: Int)? {
        guard rows.indices.contains(row), !rows[row].isHidden, point.x >= 0, point.x <= width,
              let column = columnX.lastIndex(where: { $0 <= point.x }) else { return nil }
        let text = gridText(row: row, column: column)
        let origin = textOrigin(row: row, column: column)
        let body = rows[row]
        let y = min(max(point.y, body.bodyTop + padding.height), body.bodyTop + body.bodyHeight - padding.height)
        let local = CGPoint(x: point.x - origin.x, y: y - origin.y)
        guard text.text.length > 0 else { return (column, 0) }
        // Past the last line: the end of the words.
        guard local.y <= text.usedHeight else { return (column, shown(row: row, column: column, display: text.text.length)) }
        return (column, shown(row: row, column: column, display: text.index(at: local)))
    }

    func column(atX x: CGFloat) -> Int? {
        guard x >= 0, x <= width else { return nil }
        return columnX.lastIndex { $0 <= x }
    }

    /// The shown offset one wrapped line up or down in the cell at the caret's x; nil on the
    /// first or last line (the move leaves the cell).
    func verticalStep(row: Int, column: Int, shown: Int, down: Bool) -> Int? {
        let text = gridText(row: row, column: column)
        let caret = text.caret(at: displayCaret(row: row, column: column, shown: shown))
        let lines = text.lines
        guard let current = lines.firstIndex(where: { caret.midY >= $0.box.minY && caret.midY <= $0.box.maxY + 0.5 }) else { return nil }
        let target = current + (down ? 1 : -1)
        guard lines.indices.contains(target) else { return nil }
        return self.shown(row: row, column: column, display: text.index(at: CGPoint(x: caret.minX, y: lines[target].box.midY)))
    }

    /// The shown offset in a cell at `x` (the table's), on its first or last line.
    func shownOffset(row: Int, column: Int, nearX x: CGFloat, lastLine: Bool) -> Int {
        let text = gridText(row: row, column: column)
        guard let line = lastLine ? text.lines.last : text.lines.first else { return 0 }
        return shown(row: row, column: column, display: text.index(at: CGPoint(x: x - textOrigin(row: row, column: column).x, y: line.box.midY)))
    }
}
