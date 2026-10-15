import Foundation

/// A GitHub-style pipe table, split into rows and cells, and the rule for how wide each column
/// is. The part of drawing a plan's table that the Mac's editor and the phone's reader share.
///
/// **In `FleetKit` for `PlanBlocks`' reason.** Two readings of where a cell begins and ends — an
/// escaped pipe, a missing trailing pipe, a ragged row — are two tables that disagree about the
/// same plan, and two answers to "how wide is the Area column" are two layouts that look like
/// different documents. Each side draws its own cells (AppKit text in a hidden source line on the
/// Mac, SwiftUI text on the phone); only the splitting and the widths are here.
///
/// Offsets are UTF-16 units from the start of the text given to `parse`.
public struct PipeTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }

    public struct Row: Equatable, Sendable {
        /// The row's line, without its newline.
        public let line: NSRange
        /// Each cell's content, trimmed of the spaces around it. An escaped pipe (`\|`) is still
        /// in the content as typed: it belongs to the cell, and showing it as a bare `|` is the
        /// drawing side's.
        public let cells: [NSRange]
    }

    public let rows: [Row]
    /// One per column, left unless the delimiter row says otherwise (`:--`, `--:`, `:-:`).
    public let alignments: [Alignment]
    public var columnCount: Int { alignments.count }
    /// The delimiter row (`|---|---|`): never drawn.
    public static let delimiterRow = 1

    /// The table in `u`, or nil when it is not one: a table needs a delimiter row on its second
    /// line (GFM says so too), and a block of pipe-led lines without one is just text.
    public static func parse(_ u: [UInt16]) -> PipeTable? {
        var lines: [NSRange] = []
        var start = 0
        for i in 0...u.count where i == u.count || u[i] == 10 {
            lines.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        guard lines.count >= 2, let alignments = delimiter(u, lines[1]) else { return nil }
        let rows = lines.map { Row(line: $0, cells: split(u, $0)) }
        let columns = max(rows.map(\.cells.count).max() ?? 0, alignments.count)
        return PipeTable(rows: rows, alignments: alignments + Array(repeating: .left, count: columns - alignments.count))
    }

    public static func parse(_ text: String) -> PipeTable? { parse(Array(text.utf16)) }

    /// The cells of the one line `line` of `u`, as `parse` makes them for a row. For the editor,
    /// which reads the row a keystroke is in rather than the whole table.
    public static func cells(in u: [UInt16], line: NSRange) -> [NSRange] { split(u, line) }

    /// The alignments the line `line` of `u` declares as a delimiter row; nil when it is not one.
    public static func alignments(ofDelimiter u: [UInt16], line: NSRange) -> [Alignment]? { delimiter(u, line) }

    /// A cell's text as shown: an escaped pipe is a pipe.
    public static func display(_ cell: String) -> String { cell.replacingOccurrences(of: "\\|", with: "|") }

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

    // MARK: - Column widths

    /// The columns of a table in `available` points, from what each one's cells measure.
    public struct Fit: Equatable, Sendable {
        public let widths: [Double]
        /// The cell padding the widths were made for: the asked-for one, less if the table
        /// could not otherwise keep its words whole.
        public let padding: Double
        /// The columns together are wider than `available`: only possible when words may not
        /// break, and the drawing side scrolls (the phone) rather than clipping.
        public let overflows: Bool
    }

    /// Column widths for `available` points. `natural[c]` is column `c`'s widest cell on one
    /// line and `longestWord[c]` its widest word, both without padding.
    ///
    /// A column keeps its natural width unless the table is too wide for the room; then the long
    /// columns are capped at one shared width — the "water level" at which the table fits — and
    /// the short ones stay as they are, so an Area column of one word stays narrow beside two
    /// columns of sentences. A table with room to spare is as wide as its content, not stretched.
    /// No column goes below its longest word. When even those don't fit, the padding gives some
    /// room back (down to 40%), and then, if `breakWords`, the widest words are the ones that
    /// break; if not, the table is wider than `available` and `overflows`.
    public static func fit(natural: [Double], longestWord: [Double], available: Double, padding: Double,
                           minimumContent: Double, breakWords: Bool) -> Fit {
        guard !natural.isEmpty else { return Fit(widths: [], padding: padding, overflows: false) }
        func columns(_ pad: Double) -> (natural: [Double], floors: [Double]) {
            let floor = 2 * pad + minimumContent
            let n = natural.map { max($0.rounded(.up) + 2 * pad, floor) }
            return (n, zip(longestWord, n).map { min(max($0.rounded(.up) + 2 * pad, floor), $1) })
        }
        var pad = padding
        var (n, floors) = columns(pad)
        for squeeze in [0.6, 0.4] where floors.reduce(0, +) > available {
            pad = padding * squeeze
            (n, floors) = columns(pad)
        }
        let floorTotal = floors.reduce(0, +)
        if n.reduce(0, +) <= available { return Fit(widths: n, padding: pad, overflows: false) }
        if floorTotal >= available, !breakWords { return Fit(widths: floors, padding: pad, overflows: floorTotal > available + 0.5) }
        return Fit(widths: columnWidths(natural: n, minimum: floors, available: available), padding: pad, overflows: false)
    }

    /// Widths for `available` points between each column's `minimum` and `natural`: the shared
    /// cap that makes them fill it; when even the minimums are too wide, the widest of those
    /// are cut down instead.
    public static func columnWidths(natural: [Double], minimum: [Double], available: Double) -> [Double] {
        guard !natural.isEmpty else { return [] }
        if natural.reduce(0, +) <= available { return natural }
        let floors = zip(natural, minimum).map { min($0, $1) }
        func level(_ total: (Double) -> Double, upTo top: Double) -> Double {
            var lo = 0.0, hi = top
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if total(mid) > available { hi = mid } else { lo = mid }
            }
            return lo
        }
        if floors.reduce(0, +) >= available {
            let cap = level({ cap in floors.reduce(0) { $0 + min($1, cap) } }, upTo: floors.max() ?? 0)
            return floors.map { min($0, cap) }
        }
        let cap = level({ cap in zip(natural, floors).reduce(0) { $0 + min($1.0, max($1.1, cap)) } }, upTo: natural.max() ?? 0)
        return zip(natural, floors).map { min($0, max($1, cap)) }
    }
}
