import AppKit

/// What the edit layer removed from a table, which the grid has to draw itself since a grid
/// row's source text is hidden: the words a one-line change removed (struck through where they
/// were, inside their cell) and the whole rows it removed (a ghost row of their own, in place).
/// The layout takes room for them, so they are part of its cache key. What the human ADDED needs
/// no room and is no part of the layout: it is a fill over the row, drawn from the source ranges
/// the decoration layers tint (`PlanTableLayout.draw`).
struct PlanTableMarks: Hashable {
    /// Words removed from a cell, struck through at `offset` of the cell's shown text.
    struct Ghost: Hashable {
        let row: Int
        let column: Int
        let offset: Int
        let text: String
    }

    /// Rows removed from above row `before` (the table's row count: below its last row).
    struct RowGhost: Hashable {
        let before: Int
        let lines: [String]
    }

    var inline: [Ghost] = []
    var rows: [RowGhost] = []

    static let none = PlanTableMarks()
    var isEmpty: Bool { inline.isEmpty && rows.isEmpty }

    /// For the layout cache's key: equal marks, equal key.
    var key: String {
        isEmpty ? "" : inline.map { "\($0.row),\($0.column),\($0.offset),\($0.text)" }.joined(separator: ";")
            + "|" + rows.map { "\($0.before),\($0.lines.joined(separator: "\n"))" }.joined(separator: ";")
    }

    // MARK: Finding

    /// The marks of `edits` (offsets in the whole plan) that fall in the table at `block`, whose
    /// text is `u`. A ghost pipe-led line removed above, in or below the table is a removed row;
    /// words removed inside a row's line are placed in their cell.
    static func make(_ edits: [EditMark], block: NSRange, source u: [UInt16], table: PlanTable) -> PlanTableMarks {
        var marks = PlanTableMarks()
        var changes: [PlanTableEditing.Change] = []
        for mark in edits where mark.kind == .deleted {
            let at = mark.range.location
            if mark.inline {
                guard at >= block.location, at <= NSMaxRange(block) else { continue }
                changes += pieces(of: mark, among: edits, block: block, source: u)
            } else if isRows(mark.ghost), let before = slot(at, block: block, table: table) {
                marks.rows.append(RowGhost(before: before, lines: mark.ghost.components(separatedBy: "\n")))
            }
        }
        guard !changes.isEmpty else { return marks }
        let source = String(utf16CodeUnits: u, count: u.count)
        marks.inline = PlanTableEditing.marks(for: changes, in: source).compactMap { mark in
            guard mark.kind == .deleted, let column = mark.column, !mark.ghost.isEmpty else { return nil }
            return Ghost(row: mark.row, column: column, offset: mark.textRange.location, text: mark.ghost)
        }
        return marks
    }

    /// Whether `mark` (a removed row or removed words) is the grid's to draw: its paragraph is a
    /// grid row, or, for removed rows, the line above it is one (they go below the table).
    /// `EditLayer.apply` leaves such a mark's room and drawing to the layout.
    static func owns(_ mark: EditMark, in storage: NSTextStorage) -> Bool {
        guard mark.kind == .deleted, storage.length > 0 else { return false }
        func isRow(_ i: Int) -> Bool { i >= 0 && i < storage.length && storage.attribute(.planTableRow, at: i, effectiveRange: nil) != nil }
        let at = mark.range.location
        if mark.inline { return isRow(min(at, storage.length - 1)) }
        return isRows(mark.ghost) && (isRow(min(at, storage.length - 1)) || isRow(at - 1))
    }

    /// Removed lines that are table rows: every one starts with a pipe.
    private static func isRows(_ ghost: String) -> Bool {
        ghost.components(separatedBy: "\n").allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    }

    /// The row removed lines at `at` sit above: the row whose line starts there, or the row count
    /// when they follow the table. The delimiter row is no place for them.
    private static func slot(_ at: Int, block: NSRange, table: PlanTable) -> Int? {
        let count = table.rows.count
        if let row = table.rows.indices.first(where: { block.location + table.rows[$0].line.location == at }) {
            return row == PlanTable.delimiterRow ? (count > 2 ? 2 : count) : row
        }
        return at == NSMaxRange(block) || at == NSMaxRange(block) + 1 ? count : nil
    }

    /// A one-line change that removed words across pipes ("A | B" for "X | Y") put its words in
    /// the cells they came from, when the new text has as many pipes to say where; otherwise (a
    /// removed column) the words are one ghost at the change, less the pipes at its ends, which
    /// were the grid's lines and are no words.
    private static func pieces(of mark: EditMark, among edits: [EditMark], block: NSRange, source u: [UInt16]) -> [PlanTableEditing.Change] {
        let at = mark.range.location - block.location
        let ghost = Array(mark.ghost.utf16)
        let ghostPipes = pipes(in: ghost)
        let words = ghostPipes.isEmpty ? mark.ghost : mark.ghost.trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
        let whole = words.isEmpty ? [] : [PlanTableEditing.Change(kind: .deleted, range: NSRange(location: at, length: 0), ghost: words)]
        guard !ghostPipes.isEmpty,
              let added = edits.first(where: { $0.kind == .inserted && $0.range.location == mark.range.location && $0.hunk == mark.hunk }),
              added.range.location >= block.location, NSMaxRange(added.range) <= NSMaxRange(block)
        else { return whole }
        let new = Array(u[(added.range.location - block.location)..<(NSMaxRange(added.range) - block.location)])
        let newPipes = pipes(in: new)
        guard newPipes.count == ghostPipes.count else { return whole }
        let ghostCuts = [-1] + ghostPipes + [ghost.count]
        let newStarts = [0] + newPipes.map { $0 + 1 }
        return (0..<ghostCuts.count - 1).compactMap { j in
            let piece = String(utf16CodeUnits: Array(ghost[(ghostCuts[j] + 1)..<ghostCuts[j + 1]]), count: ghostCuts[j + 1] - ghostCuts[j] - 1)
                .trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return nil }
            return PlanTableEditing.Change(kind: .deleted, range: NSRange(location: at + newStarts[j], length: 0), ghost: piece)
        }
    }

    /// Offsets of the unescaped pipes in `u`.
    private static func pipes(in u: [UInt16]) -> [Int] {
        u.indices.filter { u[$0] == 124 && ($0 == 0 || u[$0 - 1] != 92) }
    }
}
