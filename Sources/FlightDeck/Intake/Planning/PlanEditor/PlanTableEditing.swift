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
        fatalError("TODO")
    }

    /// The source offset of `place`, the caret as typing would insert there. Nil when the row or
    /// column does not exist or the row is the delimiter row. A column the row has no cell for
    /// (a short row) maps to the row's end of line.
    static func sourceOffset(in source: String, of place: CellPlace) -> Int? {
        fatalError("TODO")
    }

    /// The text the grid shows for a cell, and for each of its characters the source offset it
    /// came from. Nil for a row or column that does not exist.
    static func shownText(in source: String, row: Int, column: Int) -> (text: String, sources: [Int])? {
        fatalError("TODO")
    }

    /// The rows (with the delimiter row among them) and the most cells any row has.
    static func shape(of source: String) -> (rows: Int, columns: Int)? {
        fatalError("TODO")
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
        fatalError("TODO")
    }

    enum DeleteDirection { case backward, forward }

    /// Backspace or forward delete at a caret, or delete of a selection. At the edge of a cell's
    /// words it does nothing (nil); it never removes a pipe, a newline or padding the human
    /// can't see; a selection across cells clears the content of every cell it reaches.
    static func delete(_ direction: DeleteDirection, over selection: NSRange, in source: String) -> Result? {
        fatalError("TODO")
    }

    /// Pasting `text`: as `type`, which flattens newlines to spaces and escapes pipes.
    static func paste(_ text: String, over selection: NSRange, in source: String) -> Result? {
        fatalError("TODO")
    }

    /// `text` as one cell's source: newlines to spaces, unescaped `|` to `\|`.
    /// `after` is the source character before it goes in (a `|` straight after a backslash is
    /// already escaped).
    static func cellSource(_ text: String, after: Character? = nil) -> String {
        fatalError("TODO")
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
    static func apply(_ operation: Structure, row: Int, column: Int, in source: String) -> Result? {
        fatalError("TODO")
    }

    /// Whether `apply` would do it — what the context menu enables.
    static func allows(_ operation: Structure, row: Int, column: Int, in source: String) -> Bool {
        fatalError("TODO")
    }

    /// A new empty row at the end of the table, the caret in its cell in `column`: Tab in the
    /// last cell (`column` 0) or Return in the last row.
    static func appendRow(in source: String, caretColumn column: Int) -> Result {
        fatalError("TODO")
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
    static func move(_ key: Key, from caret: Int, in source: String, textOffset: Int? = nil) -> Move {
        fatalError("TODO")
    }

    // MARK: Copy

    /// What a selection copies as, Markdown: inside one cell, that cell's text as source;
    /// across cells, the whole rows it reaches as pipe-table lines, with the header and delimiter
    /// rows put in front when it does not start at the header, so the copy is a table. Nil for
    /// an empty selection.
    static func copyText(of selection: NSRange, in source: String) -> String? {
        fatalError("TODO")
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
    static func marks(for changes: [Change], in source: String) -> [CellMark] {
        fatalError("TODO")
    }
}
