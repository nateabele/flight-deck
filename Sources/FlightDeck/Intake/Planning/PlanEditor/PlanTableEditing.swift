import FleetKit
import Foundation

/// The pure model of editing a pipe table in place: where a source offset sits in the grid,
/// every edit as a function from the table's source to its new source and caret, where the
/// arrow keys, Tab and Return go, what a selection copies as, and which cell an edit-layer mark
/// falls in. No views, no TextKit: strings in, strings out. The editor (`PlanNSTextView`) routes
/// keys and text input through it; the grid drawing (`PlanTable`, `EditLayerFragment`) places
/// marks with it.
///
/// **Conventions.**
/// - `source` is ONE table's text, as `PlanTable.parse` takes it (rows are lines joined by
///   `\n`, row 0 the header, row 1 the delimiter row, no trailing newline), and every offset is
///   a UTF-16 offset from its start. The caller maps to and from the document.
/// - A "cell text offset" counts UTF-16 units of the text the grid SHOWS for the cell: the
///   source less hidden inline syntax (`**`, backticks, link brackets and URL) and less the
///   backslash of an escaped pipe. Hidden syntax is outside the caret's reach: the caret at the
///   cell's start or end is just inside it, so typing stays inside a bold run, and an offset
///   inside hidden syntax maps to the nearest shown position.
/// - The delimiter row is never a place: nothing maps into it, nothing navigates into it, and
///   no edit changes it except the column edits, which keep it in step.
/// - Nothing here changes the table's structure (rows, cells, pipes) except the operations that
///   say so (`insertRow`, `insertColumn`, `deleteRow`, `deleteColumn`, `appendRow`). Every other
///   edit changes cell content only, and returns nil when it could not without breaking the
///   structure (a deletion that would remove a pipe or a newline).
///
/// **Cost.** Let n be the source's length in UTF-16 units. Every call copies the source to an
/// array and scans it once for newlines (O(n), a few microseconds per 10K units), finds its row
/// by binary search (O(log rows)), and splits (`PipeTable.cells`) and styles (`MarkdownStyler.inline`)
/// only the rows and cells it touches: a place, a keystroke, an arrow key or a mark lookup is
/// O(n + the length of the rows it reads), and an edit then copies the string once (O(n)).
/// A selection across cells or rows reads just the cells it spans; copying a range, and every
/// structure edit and `shape`, read every row they change or count (O(n)). Nothing is cached
/// between calls. Measured: 30 us per keystroke on a 50x8 table of 10.8K units (optimized).
///
/// **Choices the contract leaves open.**
/// - The caret sits left of a boundary: between two shown characters it goes right after the
///   previous one, so typing at the end of a bold run stays in it; at offset 0 it goes just
///   inside the cell's opening syntax.
/// - A selection across cells clears the selected part of its first cell, all of every cell
///   between, and the selected part of its last: whole cells are not cleared when the selection
///   only grazes them. An end that sits at a cell's start (or a start at a cell's end) does not
///   reach that cell.
/// - Deleting all the words of a Markdown run takes its hidden syntax with it (`x **b** y`
///   less `b` is `x  y`), and a deleted shown pipe takes its backslash.
/// - A backslash that would end up directly before a cell's closing pipe (and so escape it)
///   gets a space after it.
/// - `shownText` is nil for the delimiter row.
/// - A new row (and a new empty cell) always has both outer pipes: a first or last empty cell
///   could not be written without them.
enum PlanTableEditing {
    // MARK: Mapping

    /// A place in the grid: row (0 header, 1 delimiter, 2... body), column, and the offset in
    /// the cell's shown text.
    struct CellPlace: Equatable {
        var row: Int
        var column: Int
        var offset: Int
    }

    /// Where source offset `offset` is. Offsets in a cell's padding, on its pipes, or past a
    /// row's last pipe map to the nearest cell's start or end; an offset in the delimiter row
    /// maps to the header's last cell end. Nil only for an empty `source`.
    static func place(in source: String, at offset: Int) -> CellPlace? {
        Grid(source)?.place(at: offset)
    }

    /// The source offset of `place`, the caret as typing would insert there. Nil when the row or
    /// column does not exist or the row is the delimiter row. A column the row has no cell for
    /// (a short row) maps to the row's end of line.
    static func sourceOffset(in source: String, of place: CellPlace) -> Int? {
        Grid(source)?.sourceOffset(of: place)
    }

    /// The text the grid shows for a cell, and for each of its characters (UTF-16 units) the
    /// source offset it came from. Nil for a row or column that does not exist.
    static func shownText(in source: String, row: Int, column: Int) -> (text: String, sources: [Int])? {
        guard let g = Grid(source), row >= 0, row < g.rows, row != PipeTable.delimiterRow, column >= 0 else { return nil }
        let spans = g.info(row).spans
        guard column < spans.count else { return nil }
        let shown = g.shown(spans[column].content)
        return (shown.string, shown.sources)
    }

    /// The rows (with the delimiter row among them) and the most cells any row has.
    static func shape(of source: String) -> (rows: Int, columns: Int)? {
        Grid(source).map { ($0.rows, $0.columns) }
    }

    // MARK: Text edits

    /// The result of an edit: the table's new source and where the caret goes (an offset in it),
    /// or a selection when the edit leaves one.
    struct Result: Equatable {
        var source: String
        var selection: NSRange
        var caret: Int { selection.location + selection.length }
    }

    /// Typing `text` over `selection` (an offset range in `source`; empty for a caret).
    /// Newlines become spaces, `|` becomes `\|`, a selection across cells clears those cells
    /// (the text going into the first), a selection that is the whole table is not this
    /// function's business. Typing into an empty cell pads it (`| x |`). Nil: nothing to do.
    static func type(_ text: String, over selection: NSRange, in source: String) -> Result? {
        Grid(source)?.replace(selection, with: text)
    }

    enum DeleteDirection { case backward, forward }

    /// Backspace or forward delete at a caret, or delete of a selection. At the edge of a cell's
    /// words it does nothing (nil); it never removes a pipe, a newline or padding the human
    /// can't see; a selection across cells clears the content of every cell it reaches.
    static func delete(_ direction: DeleteDirection, over selection: NSRange, in source: String) -> Result? {
        guard let g = Grid(source) else { return nil }
        guard selection.length == 0 else { return g.replace(selection, with: "") }
        let at = g.place(at: selection.location)
        guard let sp = g.cellSpan(at.row, at.column) else { return nil }
        let shown = g.shown(sp.content)
        let k = min(max(at.offset, 0), shown.count)
        let range: Range<Int>
        switch direction {
        case .backward:
            guard k > 0 else { return nil }
            range = shown.composedStart(before: k)..<k
        case .forward:
            guard k < shown.count else { return nil }
            range = k..<shown.composedEnd(after: k)
        }
        return g.finish(g.edit(at.row, at.column, range, ""))
    }

    /// Pasting `text`: as `type`, which flattens newlines to spaces and escapes pipes.
    static func paste(_ text: String, over selection: NSRange, in source: String) -> Result? {
        type(text, over: selection, in: source)
    }

    /// `text` as one cell's source: newlines to spaces, unescaped `|` to `\|`.
    /// `after` is the source character before it goes in (a `|` straight after a backslash is
    /// already escaped).
    static func cellSource(_ text: String, after: Character? = nil) -> String {
        makeString(flatten(text, previous: after?.utf16.last ?? 0))
    }

    /// `cellSource` in UTF-16 units, `previous` the unit before it (0 for none).
    fileprivate static func flatten(_ text: String, previous: UInt16) -> [UInt16] {
        let u = Array(text.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        var previous = previous
        var i = 0
        while i < u.count {
            let c = u[i]
            switch c {
            case 13, 10, 0x2028, 0x2029:
                if c == 13, i + 1 < u.count, u[i + 1] == 10 { i += 1 }
                out.append(32)
                previous = 32
            case 124:
                if previous != 92 { out.append(92) }
                out.append(124)
                previous = 124
            default:
                out.append(c)
                previous = c
            }
            i += 1
        }
        return out
    }

    // MARK: Structure edits (only when asked for)

    enum Structure: Equatable {
        case insertRow(above: Bool)
        case insertColumn(left: Bool)
        case deleteRow
        case deleteColumn
    }

    /// `operation` at the cell (`row`, `column`): inserts an empty row or column (the delimiter
    /// row gets `---`), or deletes one. The result's caret is in the cell the human expects: the
    /// first cell of an inserted row (same column for a column insert, in the same row), the
    /// same position after a delete. Nil when it is not allowed: any row edit on the header or
    /// delimiter row except Insert Row Below on the header (which inserts the first body row),
    /// deleting the last column.
    ///
    /// The caret of a column insert is in the NEW cell, in the row the operation was applied at.
    /// After a delete it is at the start of the same row and column (the previous one when the
    /// last was deleted; the header when the only body row was).
    static func apply(_ operation: Structure, row: Int, column: Int, in source: String) -> Result? {
        guard let g = Grid(source), g.allows(operation, row: row, column: column) else { return nil }
        return g.apply(operation, row: row, column: column)
    }

    /// Whether `apply` would do it — what the context menu enables.
    static func allows(_ operation: Structure, row: Int, column: Int, in source: String) -> Bool {
        Grid(source)?.allows(operation, row: row, column: column) ?? false
    }

    /// A new empty row at the end of the table, the caret in its cell in `column`: Tab in the
    /// last cell (`column` 0) or Return in the last row.
    static func appendRow(in source: String, caretColumn column: Int) -> Result {
        guard let g = Grid(source) else {
            return Result(source: source, selection: NSRange(location: source.utf16.count, length: 0))
        }
        let line = g.emptyRow(like: g.rows > 2 ? g.rows - 1 : 0)
        let new = source + "\n" + makeString(line)
        return Grid(new)?.result(new, row: g.rows, column: column)
            ?? Result(source: new, selection: NSRange(location: new.utf16.count, length: 0))
    }

    // MARK: Navigation

    enum Key: Equatable {
        case left, right, up, down, tab, backtab, `return`
    }

    enum Direction: Equatable { case before, after }

    enum Move: Equatable {
        /// The caret goes to this offset of the source.
        case caret(Int)
        /// The caret leaves the table, `before` it (the line above) or `after` it.
        case leave(Direction)
        /// Tab in the last cell, Return in the last row: add a row, then the caret goes to
        /// `column` of it. Apply with `appendRow`.
        case appendRow(column: Int)
    }

    /// Where `key` takes a caret at `caret` (a source offset). Left and right step through the
    /// cell's shown text and at its ends enter the previous or next cell (the end or start of
    /// it); up and down go to the same column in the row above or below, at `textOffset` in the
    /// cell's text (the editor passes the offset of the caret's x when it knows it; the model
    /// clamps it); Tab and Shift-Tab to the next or previous cell's end; Return to the same
    /// column of the next row. The delimiter row is skipped; the first and last places leave the
    /// table.
    ///
    /// A row with fewer cells than the column asked for takes the caret in its last cell; Tab
    /// and the arrows only visit cells a row really has. Return goes to the end of the cell, as
    /// Tab does.
    static func move(_ key: Key, from caret: Int, in source: String, textOffset: Int? = nil) -> Move {
        guard let g = Grid(source) else { return .caret(caret) }
        return g.move(key, from: g.place(at: caret), textOffset: textOffset)
    }

    // MARK: Copy

    /// What a selection copies as, Markdown: inside one cell, that cell's text as source;
    /// across cells, the whole rows it reaches as pipe-table lines, with the header and delimiter
    /// rows put in front when it does not start at the header, so the copy is a table. Nil for
    /// an empty selection.
    ///
    /// Inside one cell it is the selected part of the cell's source (hidden syntax inside the
    /// selection comes with it; all of the cell's words give the cell's whole source).
    static func copyText(of selection: NSRange, in source: String) -> String? {
        guard selection.length > 0, let g = Grid(source) else { return nil }
        let lo = g.clamp(selection.location), hi = g.clamp(NSMaxRange(selection))
        var (s, e) = (g.place(at: lo), g.place(at: hi))
        (s, e) = g.trimmed(s, e)
        if (s.row, s.column) == (e.row, e.column) {
            guard s.offset < e.offset, let sp = g.cellSpan(s.row, s.column) else { return nil }
            return g.slice(g.shown(sp.content), s.offset, e.offset)
        }
        guard (s.row, s.column) < (e.row, e.column) else { return nil }
        let lines = g.lines
        var out = [lines[0], lines[1]]
        if e.row >= 2 { out += lines[max(s.row, 2)...e.row] }
        return out.map { makeString(g.u[$0.location..<NSMaxRange($0)]) }.joined(separator: "\n")
    }

    // MARK: Diff placement

    /// A changed range of the edit layer, in the table's source: `inserted` characters, or
    /// words `deleted` there (zero length at `range.location`, the removed words in `ghost`).
    struct Change: Equatable {
        enum Kind { case inserted, deleted }
        var kind: Kind
        var range: NSRange
        var ghost = ""
    }

    /// A change as it falls in the grid.
    struct CellMark: Equatable {
        var kind: Change.Kind
        var row: Int
        /// Nil when the change is the whole row's (an inserted or removed row), not a cell's.
        var column: Int?
        /// For an inserted change, the shown characters it covers in the cell's text; for a
        /// deleted one, a zero-length range at the shown offset the ghost words go.
        var textRange: NSRange
        var ghost = ""
        /// An inserted change that covers all of a cell's words: the cell as a whole is changed.
        var wholeCell = false
    }

    /// `changes` split by the cells they touch: an inserted range spanning two cells is two marks,
    /// one covering a whole row is a single row mark, a deleted range's ghost goes at its
    /// position in the cell it falls in. Hidden syntax and the delimiter row take no marks.
    ///
    /// A row mark has `textRange` (0, 0). A deleted change whose ghost holds a newline is a
    /// removed row: a row mark in the row it falls in (the first body row when it falls in the
    /// delimiter row, which is where a removed first body row is reported).
    static func marks(for changes: [Change], in source: String) -> [CellMark] {
        guard !changes.isEmpty, let g = Grid(source) else { return [] }
        var out: [CellMark] = []
        for change in changes {
            switch change.kind {
            case .inserted: g.insertedMarks(change.range, into: &out)
            case .deleted: g.deletedMark(change, into: &out)
            }
        }
        return out
    }
}

// MARK: - The parsed table

private let pipe: UInt16 = 124
private let backslash: UInt16 = 92

/// `units` as a String. `String(decoding:as:)` transcodes UTF-16 a unit at a time (40x slower
/// on a 10K-unit table); Foundation's initializer copies.
private func makeString(_ units: ArraySlice<UInt16>) -> String {
    units.withUnsafeBufferPointer { $0.isEmpty ? "" : String(utf16CodeUnits: $0.baseAddress!, count: $0.count) }
}

private func makeString(_ units: [UInt16]) -> String { makeString(units[...]) }

/// A cell's extent in its row: `open` is just after its opening pipe (or the start of the line),
/// `close` the offset of its closing pipe (or the end of the line); `content` is the trimmed
/// words (empty and at `close` for an empty cell).
private struct Span {
    var open: Int
    var close: Int
    var content: NSRange
}

private struct RowInfo {
    var line: NSRange
    var spans: [Span]
    /// The first non-space character, when it is a pipe.
    var leadingPipe: Int?
    /// The last non-space character, when it is an unescaped pipe.
    var endPipe: Int?
    /// The places a row has: a row with no cells still has one, at its end.
    var places: Int { max(1, spans.count) }
}

/// A cell's shown text and where each of its characters came from.
private struct Shown {
    var chars: [UInt16]
    var sources: [Int]
    /// Per source character of the cell: 0 shown, 1 hidden syntax, 2 the backslash of `\|`.
    var kinds: [UInt8]
    /// `before[i]`: shown characters ahead of source offset `start + i`.
    var before: [Int]
    var start: Int
    var count: Int { chars.count }
    var end: Int { start + kinds.count }
    var string: String { makeString(chars) }

    /// Source offset of the left edge of shown character `i`, with its escaping backslash.
    func begin(of i: Int) -> Int {
        let o = sources[i]
        return chars[i] == pipe && o > start && kinds[o - 1 - start] == 2 ? o - 1 : o
    }

    /// The source offset of the caret at shown offset `k`: right after the character before it
    /// (so it stays inside a run it ends), and at 0 just inside the opening syntax.
    func caret(at k: Int) -> Int {
        if count == 0 { return start }
        return k <= 0 ? begin(of: 0) : sources[min(k, count) - 1] + 1
    }

    /// The shown offset a source offset falls at.
    func shownOffset(of o: Int) -> Int {
        o <= start ? 0 : o >= end ? count : before[o - start]
    }

    func composedStart(before k: Int) -> Int {
        (string as NSString).rangeOfComposedCharacterSequence(at: k - 1).location
    }

    func composedEnd(after k: Int) -> Int {
        NSMaxRange((string as NSString).rangeOfComposedCharacterSequence(at: k))
    }
}

/// One change to the source. `caret` is where the caret lands within its replacement, for the
/// edit that is the human's (the others only keep the structure).
private struct Edit {
    var range: NSRange
    var insertion: [UInt16]
    var caret: Int? = nil
}

private struct Grid {
    typealias Place = PlanTableEditing.CellPlace

    let u: [UInt16]
    /// Each row's line, without its newline. Only these and the delimiter row are read up front;
    /// a row's cells are split when something needs them, so a keystroke costs a scan for the
    /// newlines and one row, not the whole table.
    let lines: [NSRange]
    var rows: Int { lines.count }
    /// The most cells any row has, or the delimiter row declares (as `PipeTable.columnCount`).
    /// Splits every row: only the operations that change the shape ask.
    var columns: Int {
        let alignments = PipeTable.alignments(ofDelimiter: u, line: lines[PipeTable.delimiterRow])?.count ?? 0
        return lines.reduce(alignments) { max($0, PipeTable.cells(in: u, line: $1).count) }
    }
    var length: Int { u.count }

    /// Nil when `source` is not a table: it needs a delimiter row on its second line.
    init?(_ source: String) {
        let u = Array(source.utf16)
        var lines: [NSRange] = []
        var start = 0
        for i in 0...u.count where i == u.count || u[i] == 10 {
            lines.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        guard lines.count >= 2, PipeTable.alignments(ofDelimiter: u, line: lines[PipeTable.delimiterRow]) != nil else { return nil }
        self.u = u
        self.lines = lines
    }

    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }

    func clamp(_ offset: Int) -> Int { min(max(offset, 0), length) }

    // MARK: Rows and cells

    func lineIndex(containing offset: Int) -> Int {
        var lo = 0, hi = rows - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].location <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func info(_ r: Int) -> RowInfo {
        let line = lines[r], lineEnd = NSMaxRange(line)
        let cells = PipeTable.cells(in: u, line: line)
        var spans: [Span] = []
        spans.reserveCapacity(cells.count)
        for content in cells {
            var open = content.location
            while open > line.location, Grid.isSpace(u[open - 1]) { open -= 1 }
            var close = NSMaxRange(content)
            while close < lineEnd, Grid.isSpace(u[close]) { close += 1 }
            spans.append(Span(open: open, close: close, content: content))
        }
        var first = line.location
        while first < lineEnd, Grid.isSpace(u[first]) { first += 1 }
        var last = lineEnd - 1
        while last >= first, Grid.isSpace(u[last]) { last -= 1 }
        let leading = first < lineEnd && u[first] == pipe ? first : nil
        let end = last >= first && u[last] == pipe && (last == first || u[last - 1] != backslash) ? last : nil
        return RowInfo(line: line, spans: spans, leadingPipe: leading, endPipe: end)
    }

    func cellSpan(_ r: Int, _ c: Int) -> Span? {
        guard r >= 0, r < rows, r != PipeTable.delimiterRow, c >= 0 else { return nil }
        let spans = info(r).spans
        return c < spans.count ? spans[c] : nil
    }

    func shown(_ content: NSRange) -> Shown {
        let a = content.location, b = NSMaxRange(content)
        var kinds = [UInt8](repeating: 0, count: b - a)
        var spans: [MarkdownSpan] = []
        var syntax: [NSRange] = []
        MarkdownStyler.inline(u, a, b, spans: &spans, syntax: &syntax)
        for r in syntax { for i in max(r.location, a)..<min(NSMaxRange(r), b) { kinds[i - a] = 1 } }
        if b - a >= 2 { for i in a..<b - 1 where u[i] == backslash && u[i + 1] == pipe && kinds[i - a] == 0 { kinds[i - a] = 2 } }
        var chars: [UInt16] = [], sources: [Int] = []
        chars.reserveCapacity(b - a)
        sources.reserveCapacity(b - a)
        var before = [Int](repeating: 0, count: b - a + 1)
        for i in a..<b {
            before[i - a] = chars.count
            if kinds[i - a] == 0 { chars.append(u[i]); sources.append(i) }
        }
        before[b - a] = chars.count
        return Shown(chars: chars, sources: sources, kinds: kinds, before: before, start: a)
    }

    func length(ofCell r: Int, _ c: Int) -> Int {
        cellSpan(r, c).map { shown($0.content).count } ?? 0
    }

    // MARK: Mapping

    func place(at offset: Int) -> Place {
        let o = clamp(offset)
        let r = lineIndex(containing: o)
        if r == PipeTable.delimiterRow { return endPlace(0) }
        let spans = info(r).spans
        guard !spans.isEmpty else { return Place(row: r, column: 0, offset: 0) }
        let c = spans.firstIndex { o <= $0.close } ?? spans.count - 1
        let content = spans[c].content
        if o <= content.location { return Place(row: r, column: c, offset: 0) }
        return Place(row: r, column: c, offset: shown(content).shownOffset(of: o))
    }

    func endPlace(_ r: Int) -> Place {
        let spans = info(r).spans
        guard let last = spans.last else { return Place(row: r, column: 0, offset: 0) }
        return Place(row: r, column: spans.count - 1, offset: shown(last.content).count)
    }

    /// `sourceOffset(of:)` for a column the table is known to have.
    func offset(of p: Place) -> Int? {
        guard p.row >= 0, p.row < rows, p.row != PipeTable.delimiterRow, p.column >= 0 else { return nil }
        let info = info(p.row)
        guard p.column < info.spans.count else { return NSMaxRange(info.line) }
        let span = info.spans[p.column]
        if span.content.length == 0 { return span.open + min(span.close - span.open, 1) }
        return shown(span.content).caret(at: p.offset)
    }

    func sourceOffset(of p: Place) -> Int? {
        p.column < columns ? offset(of: p) : nil
    }

    // MARK: Selections

    /// A selection's ends as places, less what the selection only touches: an end at a cell's
    /// start does not reach that cell, nor a start at a cell's end.
    func trimmed(_ start: Place, _ end: Place) -> (Place, Place) {
        var s = start, e = end
        while (s.row, s.column) < (e.row, e.column), e.offset == 0, let p = previousCell(e.row, e.column) {
            e = Place(row: p.row, column: p.column, offset: length(ofCell: p.row, p.column))
        }
        while (s.row, s.column) < (e.row, e.column), s.offset >= length(ofCell: s.row, s.column), let n = nextCell(s.row, s.column) {
            s = Place(row: n.row, column: n.column, offset: 0)
        }
        return (s, e)
    }

    /// The source of shown characters `i..<j` of a cell: all its words give the whole content.
    func slice(_ shown: Shown, _ i: Int, _ j: Int) -> String {
        let a = shown.start, b = shown.end
        let whole = i <= 0 && j >= shown.count
        let from = whole ? a : shown.begin(of: i), to = whole ? b : shown.sources[j - 1] + 1
        return makeString(u[from..<to])
    }

    // MARK: Text edits

    /// The edits that replace shown characters `range` of a cell with `raw` (cell source made of
    /// it). None when it changes nothing, or there is no cell.
    func edit(_ r: Int, _ c: Int, _ range: Range<Int>, _ raw: String) -> [Edit] {
        guard let span = cellSpan(r, c) else { return [] }
        if span.content.length == 0 {
            guard !raw.isEmpty else { return [] }
            // An empty cell is padding: pad the text to `| x |`.
            let t = PlanTableEditing.flatten(raw, previous: 0)
            switch span.close - span.open {
            case 0: return [Edit(range: NSRange(location: span.open, length: 0), insertion: [32] + t + [32], caret: 1 + t.count)]
            case 1: return [Edit(range: NSRange(location: span.open + 1, length: 0), insertion: t + [32], caret: t.count)]
            default: return [Edit(range: NSRange(location: span.open + 1, length: 0), insertion: t, caret: t.count)]
            }
        }
        let shown = shown(span.content)
        var rs: Int, re: Int
        if range.lowerBound <= 0 && range.upperBound >= shown.count {
            rs = shown.start
            re = shown.end
        } else if range.isEmpty {
            rs = shown.caret(at: range.lowerBound)
            re = rs
        } else {
            rs = shown.begin(of: range.lowerBound)
            re = shown.sources[range.upperBound - 1] + 1
            // Both neighbours hidden syntax: the run is empty now, take its syntax with it.
            if rs > shown.start, re < shown.end, shown.kinds[rs - 1 - shown.start] == 1, shown.kinds[re - shown.start] == 1 {
                while rs > shown.start, shown.kinds[rs - 1 - shown.start] == 1 { rs -= 1 }
                while re < shown.end, shown.kinds[re - shown.start] == 1 { re += 1 }
            }
        }
        var t = PlanTableEditing.flatten(raw, previous: rs > 0 ? u[rs - 1] : 0)
        if t.isEmpty && re == rs { return [] }
        let caret = t.count
        // A backslash must not end up straight before the closing pipe, which it would escape.
        if (t.last ?? (rs > 0 ? u[rs - 1] : 0)) == backslash, re < length, u[re] == pipe { t.append(32) }
        var edits = [Edit(range: NSRange(location: rs, length: re - rs), insertion: t, caret: caret)]
        // An emptied first cell with no leading pipe, or last with no trailing one, would no
        // longer be a cell at all: the pipe that was only implied is written.
        if rs == shown.start, re == shown.end, t.allSatisfy(Grid.isSpace) {
            let info = info(r)
            if c == 0, info.leadingPipe == nil { edits.append(Edit(range: NSRange(location: info.line.location, length: 0), insertion: [pipe])) }
            if c == info.spans.count - 1, info.endPipe == nil { edits.append(Edit(range: NSRange(location: NSMaxRange(info.line), length: 0), insertion: [pipe])) }
        }
        return edits
    }

    /// Typing `text` over `selection` (deleting when `text` is empty).
    func replace(_ selection: NSRange, with text: String) -> PlanTableEditing.Result? {
        let lo = clamp(selection.location), hi = max(lo, clamp(NSMaxRange(selection)))
        if lo == 0 && hi >= length { return nil }
        let start = place(at: lo)
        var (s, e) = (start, place(at: hi))
        if hi > lo { (s, e) = trimmed(s, e) }
        var edits: [Edit] = []
        if (s.row, s.column) == (e.row, e.column) {
            edits = edit(s.row, s.column, s.offset..<max(s.offset, e.offset), text)
        } else if (s.row, s.column) > (e.row, e.column) {
            edits = edit(start.row, start.column, start.offset..<start.offset, text)
            s = start
        } else {
            edits += edit(s.row, s.column, s.offset..<length(ofCell: s.row, s.column), text)
            var cell = nextCell(s.row, s.column)
            while let c = cell, (c.row, c.column) < (e.row, e.column) {
                edits += edit(c.row, c.column, 0..<length(ofCell: c.row, c.column), "")
                cell = nextCell(c.row, c.column)
            }
            edits += edit(e.row, e.column, 0..<e.offset, "")
        }
        return finish(edits)
    }

    /// The result of `edits` made together. The caret is after the text of the first with a
    /// caret; with no edits there is nothing to do.
    func finish(_ edits: [Edit]) -> PlanTableEditing.Result? {
        var shift = 0
        for e in Grid.ordered(edits) {
            if let caret = e.caret {
                return PlanTableEditing.Result(source: applying(edits), selection: NSRange(location: e.range.location + shift + caret, length: 0))
            }
            shift += e.insertion.count - e.range.length
        }
        return nil
    }

    /// Insertions at a place come before what replaces the text there.
    static func ordered(_ edits: [Edit]) -> [Edit] {
        edits.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
    }

    func applying(_ edits: [Edit]) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(u.count + 16)
        var at = 0
        for e in Grid.ordered(edits) {
            out += u[at..<e.range.location]
            out += e.insertion
            at = NSMaxRange(e.range)
        }
        out += u[at...]
        return makeString(out)
    }

    /// `source` (made from this table) with the caret at the start of a cell of it.
    func result(_ source: String, row: Int, column: Int) -> PlanTableEditing.Result {
        let c = min(max(column, 0), info(row).places - 1)
        let caret = offset(of: Place(row: row, column: c, offset: 0)) ?? length
        return PlanTableEditing.Result(source: source, selection: NSRange(location: caret, length: 0))
    }

    // MARK: Structure

    func allows(_ operation: PlanTableEditing.Structure, row: Int, column: Int) -> Bool {
        guard row >= 0, row < rows, column >= 0, column < columns else { return false }
        switch operation {
        case .insertRow(let above): return row == 0 ? !above : row != PipeTable.delimiterRow
        case .deleteRow: return row >= 2
        case .insertColumn: return true
        case .deleteColumn: return columns > 1
        }
    }

    func apply(_ operation: PlanTableEditing.Structure, row: Int, column: Int) -> PlanTableEditing.Result? {
        switch operation {
        case .insertRow(let above):
            let ref = row == 0 ? (rows > 2 ? 2 : 0) : row
            let line = emptyRow(like: ref)
            let target = row == 0 ? 1 : row
            let edit = above
                ? Edit(range: NSRange(location: lines[row].location, length: 0), insertion: line + [10])
                : Edit(range: NSRange(location: NSMaxRange(lines[target]), length: 0), insertion: [10] + line)
            let new = applying([edit])
            return Grid(new)?.result(new, row: above ? row : target + 1, column: 0)
        case .deleteRow:
            let line = lines[row]
            let range = row == rows - 1
                ? NSRange(location: line.location - 1, length: line.length + 1)
                : NSRange(location: line.location, length: line.length + 1)
            let new = applying([Edit(range: range, insertion: [])])
            guard let g = Grid(new) else { return nil }
            let next = min(row, g.rows - 1)
            return g.result(new, row: next == PipeTable.delimiterRow ? 0 : next, column: column)
        case .insertColumn(let left):
            let k = left ? column : column + 1
            let delimiter = delimiterCell(near: column)
            let empty = emptyCell(width: isAligned() ? delimiter.count : 2)
            var edits: [Edit] = []
            for r in 0..<rows {
                let info = info(r)
                if r == PipeTable.delimiterRow {
                    let filler = [[UInt16]](repeating: delimiter, count: max(0, k - info.spans.count))
                    edits.append(insertCells(filler + [delimiter], into: info, at: min(k, info.spans.count)))
                } else if info.spans.count >= k {
                    edits.append(insertCells([empty], into: info, at: k))
                } else if r == row {
                    let filler = [[UInt16]](repeating: empty, count: k - info.spans.count)
                    edits.append(insertCells(filler + [empty], into: info, at: info.spans.count))
                }
            }
            let new = applying(edits)
            return Grid(new)?.result(new, row: row, column: k)
        case .deleteColumn:
            var edits: [Edit] = []
            for r in 0..<rows {
                let info = info(r)
                guard column < info.spans.count else { continue }
                if r == PipeTable.delimiterRow, info.spans.count == 1 {
                    // A delimiter row keeps a cell; it takes the default, as the column left of it is gone.
                    let span = info.spans[0]
                    edits.append(Edit(range: NSRange(location: span.open, length: span.close - span.open), insertion: delimiterCell(near: 0)))
                } else {
                    edits.append(Edit(range: removal(of: column, in: info), insertion: []))
                }
            }
            let new = applying(edits)
            guard let g = Grid(new) else { return nil }
            return g.result(new, row: row, column: min(column, max(0, g.info(row).places - 1)))
        }
    }

    /// The source to cut to take cell `c` out of a row, with a pipe.
    func removal(of c: Int, in info: RowInfo) -> NSRange {
        let span = info.spans[c]
        let lineEnd = NSMaxRange(info.line)
        // The first cell of a row with no leading pipe leaves its pipe as the leading one.
        if c == 0, info.leadingPipe == nil, info.spans.count > 1 { return NSRange(location: span.open, length: span.close - span.open) }
        if span.close < lineEnd { return NSRange(location: span.open, length: span.close + 1 - span.open) }
        // The last cell of a row with no trailing pipe: the pipe before it goes.
        let from = c == 0 ? span.open : span.open - 1
        return NSRange(location: from, length: span.close - from)
    }

    /// The edit that puts `cells` (each with its padding) into a row from cell `k` on.
    func insertCells(_ cells: [[UInt16]], into info: RowInfo, at k: Int) -> Edit {
        var text: [UInt16] = []
        for cell in cells { text += cell; text.append(pipe) }
        if k < info.spans.count {
            let open = info.spans[k].open
            let lead: [UInt16] = k == 0 && info.leadingPipe == nil ? [pipe] : []
            return Edit(range: NSRange(location: open, length: 0), insertion: lead + text)
        }
        if let end = info.endPipe { return Edit(range: NSRange(location: end + 1, length: 0), insertion: text) }
        let lineEnd = NSMaxRange(info.line)
        // No trailing pipe: the last cell needs one now, and then the new ones.
        let needsSpace = info.spans.isEmpty ? false : !(lineEnd > info.line.location && Grid.isSpace(u[lineEnd - 1]))
        return Edit(range: NSRange(location: lineEnd, length: 0), insertion: (needsSpace ? [32] : []) + [pipe] + text)
    }

    /// Whether every column is as wide in every row (a table written aligned).
    func isAligned() -> Bool {
        var widths = [Int?](repeating: nil, count: columns)
        for r in 0..<rows where r != PipeTable.delimiterRow {
            for (c, span) in info(r).spans.enumerated() {
                let w = span.close - span.open
                if let known = widths[c], known != w { return false }
                widths[c] = w
            }
        }
        return true
    }

    func emptyCell(width: Int) -> [UInt16] { [UInt16](repeating: 32, count: max(width, 2)) }

    /// A delimiter cell like the one at `column` (or the last the row has), left aligned.
    func delimiterCell(near column: Int) -> [UInt16] {
        let span = info(PipeTable.delimiterRow).spans
        guard !span.isEmpty else { return Array("---".utf16) }
        let s = span[min(column, span.count - 1)]
        let c = s.content
        let colons = (u[c.location] == 58 ? 1 : 0) + (c.length > 1 && u[NSMaxRange(c) - 1] == 58 ? 1 : 0)
        let dashes = max(3, c.length - colons)
        let lead = c.location - s.open, trail = s.close - NSMaxRange(c)
        return [UInt16](repeating: 32, count: lead) + [UInt16](repeating: 45, count: dashes) + [UInt16](repeating: 32, count: trail)
    }

    /// A new row's line, empty cells in the style of row `ref`: its indent, and its widths when
    /// the table is aligned.
    func emptyRow(like ref: Int) -> [UInt16] {
        let info = info(ref)
        let aligned = isAligned()
        var line: [UInt16] = info.leadingPipe.map { Array(u[info.line.location..<$0]) } ?? []
        line.append(pipe)
        for c in 0..<columns {
            let width = aligned && c < info.spans.count ? info.spans[c].close - info.spans[c].open : 2
            line += emptyCell(width: width)
            line.append(pipe)
        }
        return line
    }

    // MARK: Navigation

    func previousRow(_ r: Int) -> Int? { r == 0 ? nil : r == 2 ? 0 : r - 1 }

    func nextRow(_ r: Int) -> Int? {
        let n = r == 0 ? 2 : r + 1
        return n < rows ? n : nil
    }

    func nextCell(_ r: Int, _ c: Int) -> (row: Int, column: Int)? {
        if c + 1 < info(r).places { return (r, c + 1) }
        return nextRow(r).map { ($0, 0) }
    }

    func previousCell(_ r: Int, _ c: Int) -> (row: Int, column: Int)? {
        if c > 0 { return (r, c - 1) }
        return previousRow(r).map { ($0, info($0).places - 1) }
    }

    func move(_ key: PlanTableEditing.Key, from p: Place, textOffset: Int?) -> PlanTableEditing.Move {
        func caret(_ r: Int, _ c: Int, _ k: Int) -> PlanTableEditing.Move {
            .caret(offset(of: Place(row: r, column: c, offset: k)) ?? length)
        }
        func vertical(_ r: Int?, edge: PlanTableEditing.Move) -> PlanTableEditing.Move {
            guard let r else { return edge }
            return caret(r, min(p.column, info(r).places - 1), textOffset ?? p.offset)
        }
        switch key {
        case .left:
            if p.offset > 0, let sp = cellSpan(p.row, p.column) {
                let shown = shown(sp.content)
                return caret(p.row, p.column, shown.composedStart(before: min(p.offset, shown.count)))
            }
            guard let prev = previousCell(p.row, p.column) else { return .leave(.before) }
            return caret(prev.row, prev.column, .max)
        case .right:
            if let sp = cellSpan(p.row, p.column) {
                let shown = shown(sp.content)
                if p.offset < shown.count { return caret(p.row, p.column, shown.composedEnd(after: max(p.offset, 0))) }
            }
            guard let next = nextCell(p.row, p.column) else { return .leave(.after) }
            return caret(next.row, next.column, 0)
        case .up:
            return vertical(previousRow(p.row), edge: .leave(.before))
        case .down:
            return vertical(nextRow(p.row), edge: .leave(.after))
        case .tab:
            guard let next = nextCell(p.row, p.column) else { return .appendRow(column: 0) }
            return caret(next.row, next.column, .max)
        case .backtab:
            guard let prev = previousCell(p.row, p.column) else { return .leave(.before) }
            return caret(prev.row, prev.column, .max)
        case .return:
            guard let next = nextRow(p.row) else { return .appendRow(column: p.column) }
            return caret(next, min(p.column, info(next).places - 1), .max)
        }
    }

    // MARK: Diff placement

    func insertedMarks(_ range: NSRange, into out: inout [PlanTableEditing.CellMark]) {
        let lo = clamp(range.location), hi = clamp(NSMaxRange(range))
        guard hi > lo else { return }
        var r = lineIndex(containing: lo)
        while r < rows, lines[r].location < hi {
            defer { r += 1 }
            guard r != PipeTable.delimiterRow else { continue }
            let line = lines[r]
            if lo <= line.location, hi >= NSMaxRange(line), line.length > 0 {
                out.append(PlanTableEditing.CellMark(kind: .inserted, row: r, column: nil, textRange: NSRange(location: 0, length: 0)))
                continue
            }
            for (c, span) in info(r).spans.enumerated() {
                let a = span.content.location, b = NSMaxRange(span.content)
                let from = max(lo, a), to = min(hi, b)
                guard from < to else { continue }
                let shown = shown(span.content)
                let i = shown.before[from - a], j = shown.before[to - a]
                guard j > i else { continue }
                out.append(PlanTableEditing.CellMark(kind: .inserted, row: r, column: c, textRange: NSRange(location: i, length: j - i),
                                                    wholeCell: i == 0 && j == shown.count))
            }
        }
    }

    func deletedMark(_ change: PlanTableEditing.Change, into out: inout [PlanTableEditing.CellMark]) {
        let o = clamp(change.range.location)
        var r = lineIndex(containing: o)
        if change.ghost.contains("\n") {
            if r == PipeTable.delimiterRow { r = 2 }
            guard r < rows else { return }
            out.append(PlanTableEditing.CellMark(kind: .deleted, row: r, column: nil, textRange: NSRange(location: 0, length: 0), ghost: change.ghost))
            return
        }
        guard r != PipeTable.delimiterRow else { return }
        let p = place(at: o)
        out.append(PlanTableEditing.CellMark(kind: .deleted, row: p.row, column: p.column, textRange: NSRange(location: p.offset, length: 0), ghost: change.ghost))
    }
}
