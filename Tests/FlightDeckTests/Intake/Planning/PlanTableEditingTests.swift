import FleetKit
import XCTest
@testable import FlightDeck

/// The pure model of editing a plan's table in the grid (`PlanTableEditing`): where a source offset
/// sits, every edit, the structure operations, where keys go, what a selection copies as, and
/// which cell a diff mark falls in. Strings in, strings out: no views, no windows.
///
/// Fixtures mark places in the source: `‸` is a caret, `«…»` a selection. The marks are cut out
/// before the model sees the source, and a result's caret is checked the same way.
final class PlanTableEditingTests: XCTestCase {
    typealias E = PlanTableEditing
    typealias P = PlanTableEditing.CellPlace

    // MARK: Fixtures and helpers

    private func tbl(_ lines: String...) -> String { lines.joined(separator: "\n") }

    private let basic = "| Name | Area |\n|------|------|\n| alpha | beta |\n| gamma | delta |"

    /// A table with every kind of cell: inline syntax, an escaped pipe, an empty cell, unicode.
    private let inline = #"""
    | **Bold** x | `code` span | [link](http://x.y) | plain |
    |:--|:-:|--:|---|
    | a\|b |  | ü😀 é | **b** `c` |
    """#

    private let noOuterPipes = "a | b\n--|--\n1 | 2"
    private let leadingOnly = "| a | b\n|---|---\n| 1 | 2"
    private let trailingOnly = "a | b |\n---|---|\n1 | 2 |"
    private let ragged = "| a | b | c |\n|---|---|---|\n| 1 |\n| x | y |\n| p | q | r | s |"
    private let indented = "  | a  |  b  |\n  |---|---|\n  | 1  |  2  |"
    private let singleCell = "| a |\n|---|\n| b |"
    private let headerOnly = "| a | b |\n|---|---|"
    private let emptyCells = "|||\n|--|--|\n|  | x |\n|   |    |"
    private let unicode = "| ü | 😀🙂 |\n|---|---|\n| e\u{301} | 日本 |"
    private let aligned = "| Name  | Area  |\n| ----- | :---: |\n| alpha | beta  |"
    private let noPadding = "|a|b|\n|-|-|\n|c|d|"

    private var allTables: [String] {
        [basic, inline, noOuterPipes, leadingOnly, trailingOnly, ragged, indented, singleCell, headerOnly,
         emptyCells, unicode, aligned, noPadding]
    }

    private func utf16Count(_ s: String) -> Int { s.utf16.count }

    /// UTF-16 offset of the `n`th occurrence of `needle` (its end when `end`).
    private func off(_ s: String, _ needle: String, _ n: Int = 0, end: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) -> Int {
        var from = s.startIndex
        for i in 0...n {
            guard let r = s.range(of: needle, range: from..<s.endIndex) else {
                XCTFail("no occurrence \(i) of \(needle) in \(s)", file: file, line: line)
                return 0
            }
            if i == n { return s.utf16.distance(from: s.utf16.startIndex, to: end ? r.upperBound : r.lowerBound) }
            from = r.upperBound
        }
        return 0
    }

    /// The source and the selection (a caret, or `«…»`) marked in `marked`.
    private func unmark(_ marked: String) -> (source: String, selection: NSRange) {
        var s = marked
        if let open = s.range(of: "«"), let close = s.range(of: "»") {
            let a = s.utf16.distance(from: s.utf16.startIndex, to: open.lowerBound)
            let b = s.utf16.distance(from: s.utf16.startIndex, to: close.lowerBound) - 1
            s = s.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            return (s, NSRange(location: a, length: b - a))
        }
        guard let c = s.range(of: "‸") else { XCTFail("no mark in \(marked)"); return (s, NSRange(location: 0, length: 0)) }
        let at = s.utf16.distance(from: s.utf16.startIndex, to: c.lowerBound)
        s.removeSubrange(c)
        return (s, NSRange(location: at, length: 0))
    }

    private func assertResult(_ r: E.Result?, _ marked: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { XCTFail("nil, expected \(marked)", file: file, line: line); return }
        let expected = unmark(marked)
        XCTAssertEqual(r.source, expected.source, file: file, line: line)
        XCTAssertEqual(r.selection, expected.selection, "caret in \(r.source)", file: file, line: line)
    }

    private func typing(_ text: String, _ marked: String) -> E.Result? {
        let (s, sel) = unmark(marked)
        return E.type(text, over: sel, in: s)
    }

    private func deleting(_ d: E.DeleteDirection, _ marked: String) -> E.Result? {
        let (s, sel) = unmark(marked)
        return E.delete(d, over: sel, in: s)
    }

    /// The shown text of every cell of every row but the delimiter row.
    private func cells(_ source: String) -> [[String]] {
        guard let table = PipeTable.parse(source) else { XCTFail("not a table: \(source)"); return [] }
        return table.rows.indices.filter { $0 != 1 }.map { r in
            table.rows[r].cells.indices.map { E.shownText(in: source, row: r, column: $0)?.text ?? "?" }
        }
    }

    private func shape(_ source: String) -> (rows: Int, columns: Int) { E.shape(of: source) ?? (0, 0) }

    private func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    /// The delimiter row's alignments.
    private func alignments(_ source: String) -> [PipeTable.Alignment] { PipeTable.parse(source)?.alignments ?? [] }

    private func place(_ s: String, _ o: Int) -> P { E.place(in: s, at: o) ?? P(row: -1, column: -1, offset: -1) }

    // MARK: Mapping: places

    func testPlacesInTheBasicTable() {
        let s = basic  // line 0: "| Name | Area |"
        XCTAssertEqual(place(s, 0), P(row: 0, column: 0, offset: 0), "before the leading pipe")
        XCTAssertEqual(place(s, 1), P(row: 0, column: 0, offset: 0), "in the padding")
        XCTAssertEqual(place(s, 2), P(row: 0, column: 0, offset: 0))
        XCTAssertEqual(place(s, 4), P(row: 0, column: 0, offset: 2))
        XCTAssertEqual(place(s, 6), P(row: 0, column: 0, offset: 4), "end of the words")
        XCTAssertEqual(place(s, 7), P(row: 0, column: 0, offset: 4), "on the pipe: the cell it closes")
        XCTAssertEqual(place(s, 8), P(row: 0, column: 1, offset: 0), "past the pipe: the next cell")
        XCTAssertEqual(place(s, 14), P(row: 0, column: 1, offset: 4), "on the last pipe")
        XCTAssertEqual(place(s, 15), P(row: 0, column: 1, offset: 4), "on the newline")
        XCTAssertEqual(place(s, 32), P(row: 2, column: 0, offset: 0))
        XCTAssertEqual(place(s, utf16Count(s)), P(row: 3, column: 1, offset: 5), "the very end")
    }

    func testTheDelimiterRowMapsToTheHeadersLastCellEnd() {
        let s = basic
        for o in 16...31 { XCTAssertEqual(place(s, o), P(row: 0, column: 1, offset: 4), "offset \(o)") }
    }

    func testOffsetsOutOfRangeAreClamped() {
        XCTAssertEqual(place(basic, -5), P(row: 0, column: 0, offset: 0))
        XCTAssertEqual(place(basic, 10_000), P(row: 3, column: 1, offset: 5))
    }

    func testNoTableNoPlace() {
        XCTAssertNil(E.place(in: "", at: 0))
        XCTAssertNil(E.place(in: "| a |", at: 0), "one line is not a table")
        XCTAssertNil(E.place(in: "| a |\n| b |", at: 3), "no delimiter row")
        XCTAssertNil(E.shape(of: ""))
        XCTAssertNil(E.sourceOffset(in: "", of: P(row: 0, column: 0, offset: 0)))
        XCTAssertNil(E.shownText(in: "", row: 0, column: 0))
    }

    func testSourceOffsetsInTheBasicTable() {
        XCTAssertEqual(E.sourceOffset(in: basic, of: P(row: 0, column: 0, offset: 0)), 2)
        XCTAssertEqual(E.sourceOffset(in: basic, of: P(row: 0, column: 0, offset: 4)), 6)
        XCTAssertEqual(E.sourceOffset(in: basic, of: P(row: 0, column: 1, offset: 2)), 11)
        XCTAssertEqual(E.sourceOffset(in: basic, of: P(row: 3, column: 1, offset: 99)), off(basic, "delta", end: true), "clamped to the end")
        XCTAssertEqual(E.sourceOffset(in: basic, of: P(row: 2, column: 0, offset: -3)), off(basic, "alpha"), "clamped to the start")
    }

    func testNoSourceOffsetForAPlaceThatIsNotThere() {
        XCTAssertNil(E.sourceOffset(in: basic, of: P(row: 1, column: 0, offset: 0)), "the delimiter row")
        XCTAssertNil(E.sourceOffset(in: basic, of: P(row: 4, column: 0, offset: 0)))
        XCTAssertNil(E.sourceOffset(in: basic, of: P(row: -1, column: 0, offset: 0)))
        XCTAssertNil(E.sourceOffset(in: basic, of: P(row: 0, column: 2, offset: 0)))
        XCTAssertNil(E.sourceOffset(in: basic, of: P(row: 0, column: -1, offset: 0)))
    }

    func testAShortRowsMissingColumnIsItsEndOfLine() {
        let end2 = off(ragged, "| 1 |", end: true)
        XCTAssertEqual(E.sourceOffset(in: ragged, of: P(row: 2, column: 1, offset: 0)), end2)
        XCTAssertEqual(E.sourceOffset(in: ragged, of: P(row: 2, column: 2, offset: 0)), end2)
        XCTAssertNil(E.sourceOffset(in: ragged, of: P(row: 2, column: 4, offset: 0)), "no row has a fifth column")
        XCTAssertEqual(place(ragged, end2), P(row: 2, column: 0, offset: 1), "and the end of line is the last real cell")
    }

    func testPlacesWithNoOuterPipes() {
        let s = noOuterPipes  // "a | b": a 0, pipe 2, b 4
        XCTAssertEqual(place(s, 0), P(row: 0, column: 0, offset: 0))
        XCTAssertEqual(place(s, 1), P(row: 0, column: 0, offset: 1))
        XCTAssertEqual(place(s, 2), P(row: 0, column: 0, offset: 1), "on the pipe")
        XCTAssertEqual(place(s, 3), P(row: 0, column: 1, offset: 0), "in the padding after it")
        XCTAssertEqual(place(s, 4), P(row: 0, column: 1, offset: 0))
        XCTAssertEqual(place(s, 5), P(row: 0, column: 1, offset: 1))
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 2, column: 1, offset: 1)), utf16Count(s))
    }

    func testPlacesInAnIndentedTable() {
        XCTAssertEqual(place(indented, 0), P(row: 0, column: 0, offset: 0), "in the indent")
        XCTAssertEqual(place(indented, 4), P(row: 0, column: 0, offset: 0))
        XCTAssertEqual(place(indented, 5), P(row: 0, column: 0, offset: 1))
        XCTAssertEqual(E.sourceOffset(in: indented, of: P(row: 0, column: 0, offset: 0)), 4)
    }

    func testAnEmptyCellsOneCaretPosition() {
        // "|||": two empty cells with nothing between the pipes; "|  | x |": two spaces.
        XCTAssertEqual(E.sourceOffset(in: emptyCells, of: P(row: 0, column: 0, offset: 0)), 1, "no padding: the caret is on the pipe side")
        XCTAssertEqual(E.sourceOffset(in: emptyCells, of: P(row: 0, column: 1, offset: 0)), 2)
        let row2 = off(emptyCells, "|  | x |")
        XCTAssertEqual(E.sourceOffset(in: emptyCells, of: P(row: 2, column: 0, offset: 0)), row2 + 2, "after the first space")
        for o in row2...row2 + 3 { XCTAssertEqual(place(emptyCells, o).row, 2) }
        XCTAssertEqual(place(emptyCells, row2 + 1), P(row: 2, column: 0, offset: 0))
        XCTAssertEqual(place(emptyCells, row2 + 2), P(row: 2, column: 0, offset: 0))
    }

    func testHiddenSyntaxHasNoPlace() {
        let s = inline
        let bold = off(s, "**Bold**")  // shown "Bold x"
        XCTAssertEqual(place(s, bold), P(row: 0, column: 0, offset: 0), "before the opening **")
        XCTAssertEqual(place(s, bold + 1), P(row: 0, column: 0, offset: 0), "inside the opening **")
        XCTAssertEqual(place(s, bold + 2), P(row: 0, column: 0, offset: 0))
        XCTAssertEqual(place(s, bold + 3), P(row: 0, column: 0, offset: 1))
        XCTAssertEqual(place(s, bold + 6), P(row: 0, column: 0, offset: 4), "before the closing **")
        XCTAssertEqual(place(s, bold + 7), P(row: 0, column: 0, offset: 4), "inside the closing **")
        XCTAssertEqual(place(s, bold + 8), P(row: 0, column: 0, offset: 4), "after it")
        XCTAssertEqual(place(s, bold + 9), P(row: 0, column: 0, offset: 5), "past the space")
    }

    func testTheCaretIsInsideTheSyntaxAtACellsEnds() {
        let s = inline
        let bold = off(s, "**Bold**")
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 0)), bold + 2, "just inside the opening **")
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 4)), bold + 6, "left of a boundary, still inside the run")
        let link = off(s, "[link](http://x.y)")
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 0, column: 2, offset: 0)), link + 1)
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 0, column: 2, offset: 4)), link + 5, "before the ]")
        let code = off(s, "`code`")
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 0, column: 1, offset: 4)), code + 5)
        XCTAssertEqual(place(s, link + 12), P(row: 0, column: 2, offset: 4), "inside the hidden URL: the end of the link text")
    }

    func testAnEscapedPipeIsOneShownCharacter() {
        let s = inline
        let a = off(s, #"a\|b"#)
        let shown = E.shownText(in: s, row: 2, column: 0)
        XCTAssertEqual(shown?.text, "a|b")
        XCTAssertEqual(shown?.sources, [a, a + 2, a + 3], "the pipe came from after the backslash")
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 2, column: 0, offset: 1)), a + 1, "the caret is before the backslash")
        XCTAssertEqual(E.sourceOffset(in: s, of: P(row: 2, column: 0, offset: 2)), a + 3, "and after the pipe")
        XCTAssertEqual(place(s, a + 2), P(row: 2, column: 0, offset: 1), "between backslash and pipe: before the pipe")
        XCTAssertEqual(place(s, a + 3), P(row: 2, column: 0, offset: 2))
    }

    func testShownTextOfEveryCellOfTheInlineTable() {
        XCTAssertEqual(cells(inline), [
            ["Bold x", "code span", "link", "plain"],
            ["a|b", "", "ü😀 é", "b c"],
        ])
    }

    func testShownTextOfOtherTables() {
        XCTAssertEqual(cells(basic), [["Name", "Area"], ["alpha", "beta"], ["gamma", "delta"]])
        XCTAssertEqual(cells(noOuterPipes), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(cells(leadingOnly), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(cells(trailingOnly), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(cells(ragged), [["a", "b", "c"], ["1"], ["x", "y"], ["p", "q", "r", "s"]])
        XCTAssertEqual(cells(indented), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(cells(emptyCells), [["", ""], ["", "x"], ["", ""]])
        XCTAssertEqual(cells(unicode), [["ü", "😀🙂"], ["e\u{301}", "日本"]])
    }

    func testShownTextRefusesWhatIsNotACell() {
        XCTAssertNil(E.shownText(in: basic, row: 1, column: 0), "the delimiter row is never shown")
        XCTAssertNil(E.shownText(in: basic, row: 4, column: 0))
        XCTAssertNil(E.shownText(in: basic, row: -1, column: 0))
        XCTAssertNil(E.shownText(in: basic, row: 0, column: 2))
        XCTAssertNil(E.shownText(in: ragged, row: 2, column: 1), "a short row has no cell there")
    }

    func testShape() {
        XCTAssertEqual(shape(basic).rows, 4)
        XCTAssertEqual(shape(basic).columns, 2)
        XCTAssertEqual(shape(ragged).rows, 5)
        XCTAssertEqual(shape(ragged).columns, 4, "the most cells any row has")
        XCTAssertEqual(shape(headerOnly).rows, 2)
        XCTAssertEqual(shape(singleCell).columns, 1)
        XCTAssertEqual(shape("| a |\n|---|---|\n| 1 |").columns, 2, "the delimiter row can be the widest")
    }

    // MARK: Mapping: round trips

    func testShownSourcesPointAtTheirCharacters() {
        for s in allTables {
            let u = Array(s.utf16)
            guard let t = PipeTable.parse(s) else { XCTFail(s); continue }
            for r in t.rows.indices where r != 1 {
                for c in t.rows[r].cells.indices {
                    guard let shown = E.shownText(in: s, row: r, column: c) else { XCTFail("\(r),\(c) in \(s)"); continue }
                    let chars = Array(shown.text.utf16)
                    XCTAssertEqual(chars.count, shown.sources.count)
                    XCTAssertEqual(shown.sources, shown.sources.sorted(), "ascending")
                    for (i, o) in shown.sources.enumerated() { XCTAssertEqual(u[o], chars[i], "char \(i) of \(r),\(c) in \(s)") }
                }
            }
        }
    }

    func testEveryPlaceRoundTripsThroughItsSourceOffset() {
        for s in allTables {
            guard let t = PipeTable.parse(s) else { XCTFail(s); continue }
            for r in t.rows.indices where r != 1 {
                for c in 0..<max(1, t.rows[r].cells.count) {
                    let n = E.shownText(in: s, row: r, column: c)?.text.utf16.count ?? 0
                    for k in 0...n {
                        let p = P(row: r, column: c, offset: k)
                        guard let o = E.sourceOffset(in: s, of: p) else { XCTFail("no offset for \(p) in \(s)"); continue }
                        XCTAssertEqual(E.place(in: s, at: o), p, "\(p) via \(o) in \(s)")
                    }
                }
            }
        }
    }

    func testEverySourceOffsetLandsSomewhereAndSettles() {
        for s in allTables {
            for o in 0...utf16Count(s) {
                guard let p = E.place(in: s, at: o), let back = E.sourceOffset(in: s, of: p) else { XCTFail("offset \(o) in \(s)"); continue }
                XCTAssertNotEqual(p.row, 1, "never the delimiter row")
                XCTAssertEqual(E.place(in: s, at: back), p, "offset \(o) in \(s) settles at \(p)")
            }
        }
    }

    func testPlacesNeverGoBackwardsAlongTheSource() {
        for s in allTables {
            let u = Array(s.utf16)
            var last = P(row: 0, column: 0, offset: 0)
            for o in 0...u.count {
                // The delimiter row folds back onto the header, so only compare outside it.
                if u.prefix(o).filter({ $0 == 10 }).count == 1 { continue }
                let p = place(s, o)
                XCTAssertTrue((p.row, p.column, p.offset) >= (last.row, last.column, last.offset), "offset \(o) in \(s): \(p) after \(last)")
                last = p
            }
        }
    }

    // MARK: Text edits: type

    func testTypingInsertsAtTheCaret() {
        assertResult(typing("X", tbl("| Name | Area |", "|------|------|", "| alpha‸ | beta |", "| gamma | delta |")),
                     tbl("| Name | Area |", "|------|------|", "| alphaX‸ | beta |", "| gamma | delta |"))
        assertResult(typing("X", tbl("| Name | Area |", "|------|------|", "| al‸pha | beta |", "| gamma | delta |")),
                     tbl("| Name | Area |", "|------|------|", "| alX‸pha | beta |", "| gamma | delta |"))
        assertResult(typing("X", tbl("| Name | Area |", "|------|------|", "| ‸alpha | beta |", "| gamma | delta |")),
                     tbl("| Name | Area |", "|------|------|", "| X‸alpha | beta |", "| gamma | delta |"))
    }

    func testTypingInTheHeader() {
        assertResult(typing("!", tbl("| Name‸ | Area |", "|---|---|")), tbl("| Name!‸ | Area |", "|---|---|"))
    }

    func testTypingFromPaddingOrAPipeGoesInsideTheCell() {
        assertResult(typing("X", tbl("| a |‸ b |", "|---|---|")), tbl("| a | X‸b |", "|---|---|"))
        assertResult(typing("X", tbl("| a ‸| b |", "|---|---|")), tbl("| aX‸ | b |", "|---|---|"))
        assertResult(typing("X", tbl("‸| a | b |", "|---|---|")), tbl("| X‸a | b |", "|---|---|"))
        assertResult(typing("X", tbl("| a | b |‸", "|---|---|")), tbl("| a | bX‸ |", "|---|---|"))
    }

    func testTypingAPipeEscapesIt() {
        assertResult(typing("|", tbl("| a‸ | b |", "|---|---|")), tbl(#"| a\|‸ | b |"#, "|---|---|"))
        assertResult(typing("x|y|z", tbl("| ‸ | b |", "|---|---|")), tbl(#"| x\|y\|z‸ | b |"#, "|---|---|"))
    }

    func testTypingAPipeAfterABackslashIsAlreadyEscaped() {
        assertResult(typing("|", tbl(#"| a\‸ | b |"#, "|---|---|")), tbl(#"| a\|‸ | b |"#, "|---|---|"))
        XCTAssertEqual(cells(typing("|", tbl(#"| a\‸ | b |"#, "|---|---|"))?.source ?? "")[0], ["a|", "b"])
    }

    func testTypingNewlinesBecomesSpaces() {
        assertResult(typing("a\nb", tbl("| ‸x | y |", "|---|---|")), tbl("| a b‸x | y |", "|---|---|"))
        assertResult(typing("a\r\nb\rc", tbl("| ‸x | y |", "|---|---|")), tbl("| a b c‸x | y |", "|---|---|"))
        assertResult(typing("\n", tbl("| x‸ | y |", "|---|---|")), tbl("| x ‸ | y |", "|---|---|"))
    }

    func testTypingOverASelectionInACell() {
        assertResult(typing("-", tbl("| a«lph»a | b |", "|---|---|")), tbl("| a-‸a | b |", "|---|---|"))
        assertResult(typing("Z", tbl("| «alpha» | b |", "|---|---|")), tbl("| Z‸ | b |", "|---|---|"))
        assertResult(typing("Z", tbl("| al«pha» | b |", "|---|---|")), tbl("| alZ‸ | b |", "|---|---|"))
    }

    func testTypingOverAWholeCellsWordsDropsItsSyntax() {
        assertResult(typing("y", tbl("| «**bold**» | b |", "|---|---|")), tbl("| y‸ | b |", "|---|---|"))
    }

    func testTypingIntoAnEmptyCellPadsIt() {
        assertResult(typing("x", tbl("|‸||", "|--|--|")), tbl("| x‸ ||", "|--|--|"))
        assertResult(typing("x", tbl("|‸ |", "|--|")), tbl("| x‸ |", "|--|"))
        assertResult(typing("x", tbl("| ‸ |", "|--|")), tbl("| x‸ |", "|--|"))
        assertResult(typing("x", tbl("| ‸  |", "|--|")), tbl("| x‸  |", "|--|"))
        assertResult(typing("x", tbl("|  ‸|", "|--|")), tbl("| x‸ |", "|--|"))
        assertResult(typing("x", tbl("| a |‸|", "|---|---|")), tbl("| a | x‸ |", "|---|---|"))
    }

    func testTypingEmptyTextDoesNothing() {
        XCTAssertNil(typing("", tbl("| a‸ |", "|---|")))
        XCTAssertNil(typing("", tbl("||‸", "|---|")))
    }

    func testTypingAcrossCellsClearsThemAndTypesIntoTheFirst() {
        assertResult(typing("Q", tbl("| Name | Area |", "|------|------|", "| a«lpha | bet»a |")),
                     tbl("| Name | Area |", "|------|------|", "| aQ‸ | a |"))
    }

    func testTypingAcrossRowsClearsEverythingBetween() {
        assertResult(typing("X", tbl("| Name | Area |", "|------|------|", "| a«lpha | beta |", "| gam»ma | delta |")),
                     tbl("| Name | Area |", "|------|------|", "| aX‸ |  |", "| ma | delta |"))
        assertResult(typing("X", tbl("| h1 | h2 |", "|----|----|", "| a«1 | a2 |", "| b1 | b2 |", "| c1 | c»2 |")),
                     tbl("| h1 | h2 |", "|----|----|", "| aX‸ |  |", "|  |  |", "|  | 2 |"))
    }

    func testTypingOverAnEndThatOnlyTouchesACellDoesNotReachIt() {
        // Ends exactly at the start of beta: only alpha's words are selected.
        assertResult(typing("X", tbl("| h | i |", "|---|---|", "| a«lpha | »beta |")), tbl("| h | i |", "|---|---|", "| aX‸ | beta |"))
        // Starts exactly at the end of alpha: only beta's words are selected.
        assertResult(typing("X", tbl("| h | i |", "|---|---|", "| alpha«  | be»ta |")), tbl("| h | i |", "|---|---|", "| alpha  | X‸ta |"))
    }

    func testTypingOverNothingSelectedAcrossACellEdge() {
        // From the end of alpha to the start of beta, nothing is selected: it is a caret insert.
        assertResult(typing("X", tbl("| h | i |", "|---|---|", "| alpha« | »beta |")), tbl("| h | i |", "|---|---|", "| alphaX‸ | beta |"))
    }

    func testTypingOverTheWholeTableIsNotThisFunctionsBusiness() {
        let s = basic
        XCTAssertNil(E.type("x", over: NSRange(location: 0, length: utf16Count(s)), in: s))
        XCTAssertNil(E.delete(.backward, over: NSRange(location: 0, length: utf16Count(s)), in: s))
        XCTAssertNil(E.paste("x", over: NSRange(location: 0, length: utf16Count(s)), in: s))
        XCTAssertNotNil(E.type("x", over: NSRange(location: 1, length: utf16Count(s) - 1), in: s), "all but a character is a selection")
    }

    func testTypingFromTheDelimiterRowGoesToTheHeaderEnd() {
        let s = basic
        let r = E.type("!", over: NSRange(location: 20, length: 0), in: s)
        XCTAssertEqual(r?.source, basic.replacingOccurrences(of: "| Area |", with: "| Area! |"))
    }

    func testTypingAtTheStartOrEndOfAWholeBoldCellStaysInsideIt() {
        let s = tbl("| **Bold** | b |", "|---|---|")
        let start = E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 0)) ?? 0
        let end = E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 4)) ?? 0
        XCTAssertEqual(E.type("X", over: NSRange(location: start, length: 0), in: s)?.source, tbl("| **XBold** | b |", "|---|---|"))
        XCTAssertEqual(E.type("X", over: NSRange(location: end, length: 0), in: s)?.source, tbl("| **BoldX** | b |", "|---|---|"))
    }

    func testTypingInTheMiddleSticksToTheCharacterBefore() {
        let s = tbl("| **a** b | c |", "|---|---|")
        let o = E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 1)) ?? 0
        XCTAssertEqual(E.type("X", over: NSRange(location: o, length: 0), in: s)?.source, tbl("| **aX** b | c |", "|---|---|"))
    }

    func testTypingBeforeAnEscapedPipeKeepsItEscaped() {
        let s = tbl(#"| a\|b | c |"#, "|---|---|")
        let o = E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 1)) ?? 0
        let r = E.type("X", over: NSRange(location: o, length: 0), in: s)
        XCTAssertEqual(r?.source, tbl(#"| aX\|b | c |"#, "|---|---|"))
        XCTAssertEqual(cells(r?.source ?? "")[0], ["aX|b", "c"])
    }

    func testTypingABackslashBeforeTheClosingPipeDoesNotEscapeIt() {
        let r = typing(#"\"#, tbl("|a‸|b|", "|-|-|"))
        XCTAssertEqual(r?.source, tbl(#"|a\ |b|"#, "|-|-|"))
        XCTAssertEqual(r?.caret, 3, "the caret is after the backslash, before the space")
        XCTAssertEqual(cells(r?.source ?? ""), [["a\\", "b"]])
        let r2 = typing(#"x\"#, tbl("|‸|b|", "|-|-|"))
        XCTAssertEqual(cells(r2?.source ?? ""), [["x\\", "b"]])
    }

    func testTypingUnicode() {
        let r = typing("😀é", tbl("| ü‸ | b |", "|---|---|"))
        XCTAssertEqual(r?.source, tbl("| ü😀é | b |", "|---|---|"))
        XCTAssertEqual(r?.caret, 6, "UTF-16 units: the emoji is two")
    }

    func testTypingChangesOnlyTheCell() {
        for s in allTables {
            guard let t = PipeTable.parse(s) else { continue }
            for r in t.rows.indices where r != 1 {
                for c in t.rows[r].cells.indices {
                    guard let o = E.sourceOffset(in: s, of: P(row: r, column: c, offset: 0)),
                          let result = E.type("Z", over: NSRange(location: o, length: 0), in: s) else { XCTFail("\(r),\(c) in \(s)"); continue }
                    var expected = cells(s)
                    let row = r > 1 ? r - 1 : r
                    expected[row][c] = "Z" + expected[row][c]
                    XCTAssertEqual(cells(result.source), expected, "typing at \(r),\(c) in \(s)")
                    XCTAssertEqual(lines(result.source)[1], lines(s)[1], "the delimiter row is not touched")
                    XCTAssertEqual(shape(result.source).rows, shape(s).rows)
                    XCTAssertEqual(shape(result.source).columns, shape(s).columns)
                    XCTAssertEqual(E.place(in: result.source, at: result.caret), P(row: r, column: c, offset: 1), "the caret follows the text")
                }
            }
        }
    }

    func testTypingIntoAZeroCellRowDoesNothing() {
        let s = "| a |\n|---|\n\n| b |"
        XCTAssertNil(E.type("x", over: NSRange(location: off(s, "\n\n") + 1, length: 0), in: s))
    }

    // MARK: Text edits: delete

    func testBackspaceDeletesTheCharacterBefore() {
        assertResult(deleting(.backward, tbl("| alp‸ha | b |", "|---|---|")), tbl("| al‸ha | b |", "|---|---|"))
        assertResult(deleting(.backward, tbl("| alpha‸ | b |", "|---|---|")), tbl("| alph‸ | b |", "|---|---|"))
        assertResult(deleting(.backward, tbl("| a‸ | b |", "|---|---|")), tbl("| ‸ | b |", "|---|---|"))
    }

    func testBackspaceAtTheStartOfACellDoesNothing() {
        XCTAssertNil(deleting(.backward, tbl("| ‸alpha | b |", "|---|---|")))
        XCTAssertNil(deleting(.backward, tbl("|‸ alpha | b |", "|---|---|")))
        XCTAssertNil(deleting(.backward, tbl("| alpha | ‸b |", "|---|---|")), "never removes a pipe")
        XCTAssertNil(deleting(.backward, tbl("| h |", "|---|", "‸| b |")), "or a newline")
    }

    func testBackspaceInTheEmptyCellDoesNothing() {
        XCTAssertNil(deleting(.backward, tbl("| a |‸  |", "|---|---|")))
        XCTAssertNil(deleting(.backward, tbl("| a | ‸ |", "|---|---|")))
    }

    func testForwardDeleteDeletesTheCharacterAfter() {
        assertResult(deleting(.forward, tbl("| al‸pha | b |", "|---|---|")), tbl("| al‸ha | b |", "|---|---|"))
        assertResult(deleting(.forward, tbl("| ‸alpha | b |", "|---|---|")), tbl("| ‸lpha | b |", "|---|---|"))
    }

    func testForwardDeleteAtTheEndOfACellDoesNothing() {
        XCTAssertNil(deleting(.forward, tbl("| alpha‸ | b |", "|---|---|")))
        XCTAssertNil(deleting(.forward, tbl("| alpha ‸| b |", "|---|---|")))
    }

    func testDeletingAWholeCharacterOfUnicode() {
        assertResult(deleting(.backward, tbl("| a😀‸b | c |", "|---|---|")), tbl("| a‸b | c |", "|---|---|"))
        assertResult(deleting(.forward, tbl("| a‸😀b | c |", "|---|---|")), tbl("| a‸b | c |", "|---|---|"))
        assertResult(deleting(.backward, tbl("| xe\u{301}‸ | c |", "|---|---|")), tbl("| x‸ | c |", "|---|---|"))
    }

    func testDeletingAnEscapedPipeTakesItsBackslash() {
        assertResult(deleting(.backward, tbl(#"| a\|‸b | c |"#, "|---|---|")), tbl("| a‸b | c |", "|---|---|"))
        assertResult(deleting(.forward, tbl(#"| a‸\|b | c |"#, "|---|---|")), tbl("| a‸b | c |", "|---|---|"))
    }

    func testDeletingBeforeAnEscapedPipeLeavesItEscaped() {
        let r = deleting(.backward, tbl(#"| ab‸\|c | d |"#, "|---|---|"))
        XCTAssertEqual(r?.source, tbl(#"| a\|c | d |"#, "|---|---|"))
        XCTAssertEqual(cells(r?.source ?? "")[0], ["a|c", "d"])
    }

    func testDeletingAllOfARunsWordsTakesItsSyntax() {
        assertResult(deleting(.backward, tbl("| x **b‸** y | c |", "|---|---|")), tbl("| x ‸ y | c |", "|---|---|"))
        assertResult(deleting(.forward, tbl("| x **‸b** y | c |", "|---|---|")), tbl("| x ‸ y | c |", "|---|---|"))
        assertResult(deleting(.backward, tbl("| x `co‸de` y | c |", "|---|---|")), tbl("| x `c‸de` y | c |", "|---|---|"))
        assertResult(deleting(.backward, tbl("| **b‸** | c |", "|---|---|")), tbl("| ‸ | c |", "|---|---|"))
    }

    func testDeletingTheFirstCharacterOfARunKeepsItsSyntax() {
        assertResult(deleting(.forward, tbl("| **‸bold** | c |", "|---|---|")), tbl("| **‸old** | c |", "|---|---|"))
    }

    func testDeleteASelectionInACell() {
        assertResult(deleting(.backward, tbl("| a«lph»a | b |", "|---|---|")), tbl("| a‸a | b |", "|---|---|"))
        assertResult(deleting(.forward, tbl("| a«lph»a | b |", "|---|---|")), tbl("| a‸a | b |", "|---|---|"))
        assertResult(deleting(.backward, tbl("| «alpha» | b |", "|---|---|")), tbl("| ‸ | b |", "|---|---|"))
    }

    func testDeleteASelectionOfPaddingOrPipesDoesNothing() {
        XCTAssertNil(deleting(.backward, tbl("| alpha« | »beta |", "|---|---|")))
        XCTAssertNil(deleting(.backward, tbl("«| »alpha | beta |", "|---|---|")))
        XCTAssertNil(deleting(.backward, tbl("| alpha« »| beta |", "|---|---|")))
    }

    func testDeleteASelectionAcrossCells() {
        assertResult(deleting(.backward, tbl("| h | i |", "|---|---|", "| a«lpha | bet»a |")), tbl("| h | i |", "|---|---|", "| a‸ | a |"))
        assertResult(deleting(.forward, tbl("| h | i |", "|---|---|", "| a«lpha | beta |", "| gam»ma | d |")),
                     tbl("| h | i |", "|---|---|", "| a‸ |  |", "| ma | d |"))
    }

    func testDeleteAcrossTheDelimiterRow() {
        assertResult(deleting(.backward, tbl("| h«1 | h2 |", "|----|----|", "| a»1 | a2 |")), tbl("| h‸ |  |", "|----|----|", "| 1 | a2 |"))
    }

    func testDeletingNeverChangesTheStructure() {
        for s in allTables {
            let n = utf16Count(s)
            for a in stride(from: 0, to: n, by: 3) {
                for len in [0, 1, 2, 5, 9] where a + len <= n {
                    for d in [E.DeleteDirection.backward, .forward] {
                        guard let r = E.delete(d, over: NSRange(location: a, length: len), in: s) else { continue }
                        XCTAssertEqual(shape(r.source).rows, shape(s).rows, "rows: \(a),\(len) in \(s)")
                        XCTAssertEqual(cells(r.source).map(\.count), cells(s).map(\.count), "cells: \(a),\(len) in \(s)")
                        XCTAssertEqual(lines(r.source)[1], lines(s)[1])
                        XCTAssertLessThanOrEqual(utf16Count(r.source), n)
                    }
                }
            }
        }
    }

    func testBackslashLeftBeforeAPipeByADeleteGetsASpace() {
        let r = deleting(.backward, tbl(#"|c\x‸|d|"#, "|-|-|"))
        XCTAssertEqual(r?.source, tbl(#"|c\ |d|"#, "|-|-|"))
        XCTAssertEqual(r?.caret, 3)
        XCTAssertEqual(cells(r?.source ?? ""), [["c\\", "d"]])
    }

    func testEmptyingAFirstCellWithNoLeadingPipeWritesThePipe() {
        let r = E.delete(.forward, over: NSRange(location: 0, length: 0), in: noOuterPipes)
        XCTAssertEqual(r?.source, "| | b\n--|--\n1 | 2")
        XCTAssertEqual(r?.caret, 1)
        XCTAssertEqual(cells(r?.source ?? ""), [["", "b"], ["1", "2"]])
        let typed = E.type("", over: NSRange(location: 0, length: 0), in: noOuterPipes)
        XCTAssertNil(typed)
    }

    func testEmptyingALastCellWithNoTrailingPipeWritesThePipe() {
        let r = E.delete(.backward, over: NSRange(location: 5, length: 0), in: noOuterPipes)
        XCTAssertEqual(r?.source, "a | |\n--|--\n1 | 2")
        XCTAssertEqual(r?.caret, 4)
        XCTAssertEqual(cells(r?.source ?? ""), [["a", ""], ["1", "2"]])
        let leadingOnlyRow = E.delete(.backward, over: NSRange(location: off(leadingOnly, "b", end: true), length: 0), in: leadingOnly)
        XCTAssertEqual(cells(leadingOnlyRow?.source ?? "")[0], ["a", ""])
    }

    func testEmptyingTheOnlyCellOfARowWithNoPipesWritesBoth() {
        let s = "a\n-\n1"
        let r = E.delete(.backward, over: NSRange(location: 5, length: 0), in: s)
        XCTAssertEqual(r?.source, "a\n-\n||")
        XCTAssertEqual(cells(r?.source ?? ""), [["a"], [""]])
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0))
    }

    func testEmptyingCellsAcrossARowWithNoPipesKeepsEveryCell() {
        let r = E.delete(.backward, over: NSRange(location: off(noOuterPipes, "1"), length: 5), in: noOuterPipes)
        XCTAssertEqual(cells(r?.source ?? ""), [["a", "b"], ["", ""]])
    }

    func testTypingWhitespaceOverAFirstCellKeepsItACell() {
        let r = E.type(" ", over: NSRange(location: 0, length: 1), in: noOuterPipes)
        XCTAssertEqual(cells(r?.source ?? ""), [["", "b"], ["1", "2"]])
    }

    // MARK: Text edits: paste, cell source

    func testPasteIsTypeWithFlatteningAndEscaping() {
        assertResult(E.paste("a|b\nc", over: unmark(tbl("| ‸x | y |", "|---|---|")).selection, in: unmark(tbl("| ‸x | y |", "|---|---|")).source),
                     tbl(#"| a\|b c‸x | y |"#, "|---|---|"))
    }

    func testPasteOverASelection() {
        let (s, sel) = unmark(tbl("| «x» | y |", "|---|---|"))
        assertResult(E.paste("line1\nline2", over: sel, in: s), tbl("| line1 line2‸ | y |", "|---|---|"))
    }

    func testPasteAcrossCells() {
        let (s, sel) = unmark(tbl("| h | i |", "|---|---|", "| a«b | c»d |"))
        assertResult(E.paste("Z", over: sel, in: s), tbl("| h | i |", "|---|---|", "| aZ‸ | d |"))
    }

    func testCellSource() {
        XCTAssertEqual(E.cellSource("plain"), "plain")
        XCTAssertEqual(E.cellSource("a|b"), #"a\|b"#)
        XCTAssertEqual(E.cellSource(#"a\|b"#), #"a\|b"#, "already escaped")
        XCTAssertEqual(E.cellSource("a\nb\r\nc\rd"), "a b c d")
        XCTAssertEqual(E.cellSource("a\u{2028}b\u{2029}c"), "a b c")
        XCTAssertEqual(E.cellSource("|"), #"\|"#)
        XCTAssertEqual(E.cellSource("||"), #"\|\|"#)
        XCTAssertEqual(E.cellSource("|", after: "\\"), "|", "after a backslash it is escaped already")
        XCTAssertEqual(E.cellSource("|", after: "a"), #"\|"#)
        XCTAssertEqual(E.cellSource("|x|", after: "\\"), #"|x\|"#)
        XCTAssertEqual(E.cellSource(""), "")
        XCTAssertEqual(E.cellSource("😀|é"), #"😀\|é"#)
        XCTAssertEqual(E.cellSource("**bold** `x`"), "**bold** `x`", "Markdown is left alone")
    }

    // MARK: Structure: rows

    func testInsertRowAbove() {
        let r = E.apply(.insertRow(above: true), row: 2, column: 1, in: basic)
        XCTAssertEqual(r?.source, tbl("| Name | Area |", "|------|------|", "|  |  |", "| alpha | beta |", "| gamma | delta |"))
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0), "the first cell of the new row")
    }

    func testInsertRowBelow() {
        let r = E.apply(.insertRow(above: false), row: 2, column: 1, in: basic)
        XCTAssertEqual(cells(r?.source ?? ""), [["Name", "Area"], ["alpha", "beta"], ["", ""], ["gamma", "delta"]])
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 3, column: 0, offset: 0))
    }

    func testInsertRowBelowTheLastRowAppends() {
        let r = E.apply(.insertRow(above: false), row: 3, column: 0, in: basic)
        XCTAssertEqual(cells(r?.source ?? ""), [["Name", "Area"], ["alpha", "beta"], ["gamma", "delta"], ["", ""]])
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 4, column: 0, offset: 0))
    }

    func testInsertRowBelowTheHeaderMakesTheFirstBodyRow() {
        let r = E.apply(.insertRow(above: false), row: 0, column: 1, in: basic)
        XCTAssertEqual(cells(r?.source ?? ""), [["Name", "Area"], ["", ""], ["alpha", "beta"], ["gamma", "delta"]])
        XCTAssertEqual(lines(r?.source ?? "")[1], "|------|------|")
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0))
    }

    func testInsertRowBelowTheHeaderOfAHeaderOnlyTable() {
        let r = E.apply(.insertRow(above: false), row: 0, column: 0, in: headerOnly)
        XCTAssertEqual(r?.source, "| a | b |\n|---|---|\n|   |   |")
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0))
    }

    func testInsertRowRefusedOnTheHeaderAndDelimiterRows() {
        XCTAssertNil(E.apply(.insertRow(above: true), row: 0, column: 0, in: basic), "above the header")
        XCTAssertNil(E.apply(.insertRow(above: true), row: 1, column: 0, in: basic))
        XCTAssertNil(E.apply(.insertRow(above: false), row: 1, column: 0, in: basic))
        XCTAssertFalse(E.allows(.insertRow(above: true), row: 0, column: 0, in: basic))
        XCTAssertTrue(E.allows(.insertRow(above: false), row: 0, column: 0, in: basic))
        XCTAssertFalse(E.allows(.insertRow(above: true), row: 1, column: 0, in: basic))
        XCTAssertFalse(E.allows(.insertRow(above: false), row: 1, column: 0, in: basic))
    }

    func testDeleteRow() {
        let r = E.apply(.deleteRow, row: 2, column: 1, in: basic)
        XCTAssertEqual(r?.source, tbl("| Name | Area |", "|------|------|", "| gamma | delta |"))
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 1, offset: 0), "the same position: the next row moved up")
    }

    func testDeleteTheLastRow() {
        let r = E.apply(.deleteRow, row: 3, column: 0, in: basic)
        XCTAssertEqual(r?.source, tbl("| Name | Area |", "|------|------|", "| alpha | beta |"))
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0))
    }

    func testDeleteTheOnlyBodyRowLeavesAHeaderOnlyTable() {
        let r = E.apply(.deleteRow, row: 2, column: 1, in: singleCell.replacingOccurrences(of: "| a |", with: "| a | b |").replacingOccurrences(of: "|---|\n", with: "|---|---|\n"))
        XCTAssertEqual(r?.source, "| a | b |\n|---|---|")
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 0, column: 1, offset: 0), "the header")
        XCTAssertNotNil(PipeTable.parse(r?.source ?? ""))
    }

    func testDeleteRowRefusedOnTheHeaderAndDelimiterRows() {
        XCTAssertNil(E.apply(.deleteRow, row: 0, column: 0, in: basic))
        XCTAssertNil(E.apply(.deleteRow, row: 1, column: 0, in: basic))
        XCTAssertFalse(E.allows(.deleteRow, row: 0, column: 0, in: basic))
        XCTAssertFalse(E.allows(.deleteRow, row: 1, column: 0, in: basic))
        XCTAssertTrue(E.allows(.deleteRow, row: 2, column: 0, in: basic))
        XCTAssertNil(E.apply(.deleteRow, row: 0, column: 0, in: headerOnly))
    }

    func testRowOperationsOutOfRangeAreRefused() {
        for op in [E.Structure.insertRow(above: true), .insertRow(above: false), .deleteRow, .insertColumn(left: true), .deleteColumn] {
            XCTAssertNil(E.apply(op, row: 9, column: 0, in: basic))
            XCTAssertNil(E.apply(op, row: -1, column: 0, in: basic))
            XCTAssertNil(E.apply(op, row: 2, column: 9, in: basic))
            XCTAssertNil(E.apply(op, row: 2, column: -1, in: basic))
            XCTAssertFalse(E.allows(op, row: 9, column: 0, in: basic))
            XCTAssertFalse(E.allows(op, row: 2, column: 9, in: basic))
        }
        XCTAssertNil(E.apply(.deleteRow, row: 2, column: 0, in: "not a table"))
        XCTAssertFalse(E.allows(.deleteRow, row: 2, column: 0, in: "not a table"))
    }

    func testNewRowsFollowTheTablesStyle() {
        // Aligned: the new row is as wide.
        XCTAssertEqual(E.apply(.insertRow(above: false), row: 2, column: 0, in: aligned)?.source,
                       "| Name  | Area  |\n| ----- | :---: |\n| alpha | beta  |\n|       |       |")
        // Indented: so is the new row.
        XCTAssertEqual(E.apply(.insertRow(above: false), row: 2, column: 0, in: indented)?.source.components(separatedBy: "\n").last?.hasPrefix("  |"), true)
        // No outer pipes: the new row needs them to hold empty cells.
        let r = E.apply(.insertRow(above: false), row: 2, column: 0, in: noOuterPipes)
        XCTAssertEqual(cells(r?.source ?? ""), [["a", "b"], ["1", "2"], ["", ""]])
    }

    func testInsertedRowsKeepEveryOtherLineByteForByte() {
        for s in allTables where shape(s).rows > 2 {
            let before = lines(s)
            guard let r = E.apply(.insertRow(above: true), row: 2, column: 0, in: s) else { XCTFail(s); continue }
            let after = lines(r.source)
            XCTAssertEqual(Array(after.dropFirst(3)), Array(before.dropFirst(2)))
            XCTAssertEqual(Array(after.prefix(2)), Array(before.prefix(2)))
            XCTAssertEqual(shape(r.source).rows, shape(s).rows + 1)
            XCTAssertEqual(shape(r.source).columns, shape(s).columns)
        }
    }

    // MARK: Structure: columns

    func testInsertColumnLeft() {
        let r = E.apply(.insertColumn(left: true), row: 2, column: 0, in: basic)
        XCTAssertEqual(r?.source, tbl("|  | Name | Area |", "|------|------|------|", "|  | alpha | beta |", "|  | gamma | delta |"))
        XCTAssertEqual(cells(r?.source ?? "").map(\.count), [3, 3, 3])
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0), "the new cell, in the row it was asked at")
    }

    func testInsertColumnRight() {
        let r = E.apply(.insertColumn(left: false), row: 0, column: 0, in: basic)
        XCTAssertEqual(cells(r?.source ?? ""), [["Name", "", "Area"], ["alpha", "", "beta"], ["gamma", "", "delta"]])
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 0, column: 1, offset: 0))
        XCTAssertEqual(alignments(r?.source ?? ""), [.left, .left, .left])
    }

    func testInsertColumnAtTheEdges() {
        let last = E.apply(.insertColumn(left: false), row: 3, column: 1, in: basic)
        XCTAssertEqual(cells(last?.source ?? ""), [["Name", "Area", ""], ["alpha", "beta", ""], ["gamma", "delta", ""]])
        XCTAssertEqual(last.map { E.place(in: $0.source, at: $0.caret) }, P(row: 3, column: 2, offset: 0))
        XCTAssertEqual(lines(last?.source ?? "")[1].hasSuffix("|"), true)
        let first = E.apply(.insertColumn(left: true), row: 0, column: 0, in: basic)
        XCTAssertEqual(cells(first?.source ?? ""), [["", "Name", "Area"], ["", "alpha", "beta"], ["", "gamma", "delta"]])
    }

    func testInsertColumnKeepsTheAlignmentsInStep() {
        let s = "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"
        XCTAssertEqual(alignments(s), [.left, .center, .right])
        XCTAssertEqual(alignments(E.apply(.insertColumn(left: true), row: 2, column: 1, in: s)?.source ?? ""), [.left, .left, .center, .right])
        XCTAssertEqual(alignments(E.apply(.insertColumn(left: false), row: 2, column: 1, in: s)?.source ?? ""), [.left, .center, .left, .right])
        XCTAssertEqual(alignments(E.apply(.insertColumn(left: false), row: 2, column: 2, in: s)?.source ?? ""), [.left, .center, .right, .left])
        XCTAssertEqual(alignments(E.apply(.insertColumn(left: true), row: 2, column: 0, in: s)?.source ?? ""), [.left, .left, .center, .right])
    }

    func testDeleteColumnKeepsTheAlignmentsInStep() {
        let s = "| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |"
        XCTAssertEqual(alignments(E.apply(.deleteColumn, row: 2, column: 1, in: s)?.source ?? ""), [.left, .right])
        XCTAssertEqual(alignments(E.apply(.deleteColumn, row: 2, column: 0, in: s)?.source ?? ""), [.center, .right])
        XCTAssertEqual(alignments(E.apply(.deleteColumn, row: 2, column: 2, in: s)?.source ?? ""), [.left, .center])
    }

    func testInsertedColumnsDelimiterCellMatchesItsNeighbours() {
        let r = E.apply(.insertColumn(left: false), row: 2, column: 1, in: aligned)
        XCTAssertEqual(lines(r?.source ?? "")[1], "| ----- | :---: | --- |")
        XCTAssertEqual(lines(r?.source ?? "")[0], "| Name  | Area  |     |")
        let compact = E.apply(.insertColumn(left: false), row: 2, column: 0, in: noPadding)
        XCTAssertEqual(lines(compact?.source ?? "")[1], "|-|---|-|")
    }

    func testDeleteColumn() {
        let r = E.apply(.deleteColumn, row: 2, column: 0, in: basic)
        XCTAssertEqual(r?.source, tbl("| Area |", "|------|", "| beta |", "| delta |"))
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 0, offset: 0))
    }

    func testDeleteTheLastColumnMovesTheCaretLeft() {
        let r = E.apply(.deleteColumn, row: 3, column: 1, in: basic)
        XCTAssertEqual(r?.source, tbl("| Name |", "|------|", "| alpha |", "| gamma |"))
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 3, column: 0, offset: 0))
    }

    func testDeleteAMiddleColumn() {
        let s = "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |"
        let r = E.apply(.deleteColumn, row: 2, column: 1, in: s)
        XCTAssertEqual(r?.source, "| a | c |\n|---|---|\n| 1 | 3 |")
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 1, offset: 0))
    }

    func testTheLastColumnCannotBeDeleted() {
        XCTAssertNil(E.apply(.deleteColumn, row: 0, column: 0, in: singleCell))
        XCTAssertFalse(E.allows(.deleteColumn, row: 0, column: 0, in: singleCell))
        XCTAssertTrue(E.allows(.deleteColumn, row: 0, column: 0, in: basic))
        XCTAssertNotNil(E.apply(.insertColumn(left: true), row: 0, column: 0, in: singleCell), "but it can grow")
    }

    func testColumnOperationsOnAnyRowIncludingTheHeader() {
        XCTAssertNotNil(E.apply(.deleteColumn, row: 0, column: 1, in: basic))
        XCTAssertNotNil(E.apply(.insertColumn(left: true), row: 0, column: 1, in: basic))
        XCTAssertNotNil(E.apply(.insertColumn(left: true), row: 1, column: 1, in: basic), "the delimiter row's cell is a column too")
    }

    func testColumnOperationsWithNoOuterPipes() {
        let del0 = E.apply(.deleteColumn, row: 2, column: 0, in: noOuterPipes)
        XCTAssertEqual(cells(del0?.source ?? ""), [["b"], ["2"]])
        let del1 = E.apply(.deleteColumn, row: 2, column: 1, in: noOuterPipes)
        XCTAssertEqual(cells(del1?.source ?? ""), [["a"], ["1"]])
        let ins0 = E.apply(.insertColumn(left: true), row: 2, column: 0, in: noOuterPipes)
        XCTAssertEqual(cells(ins0?.source ?? ""), [["", "a", "b"], ["", "1", "2"]])
        let ins1 = E.apply(.insertColumn(left: false), row: 2, column: 1, in: noOuterPipes)
        XCTAssertEqual(cells(ins1?.source ?? ""), [["a", "b", ""], ["1", "2", ""]])
        XCTAssertEqual(shape(ins1?.source ?? "").columns, 3)
    }

    func testColumnOperationsWithOnlyALeadingPipe() {
        let ins = E.apply(.insertColumn(left: false), row: 2, column: 1, in: leadingOnly)
        XCTAssertEqual(cells(ins?.source ?? ""), [["a", "b", ""], ["1", "2", ""]])
        let del = E.apply(.deleteColumn, row: 2, column: 1, in: leadingOnly)
        XCTAssertEqual(cells(del?.source ?? ""), [["a"], ["1"]])
    }

    func testColumnOperationsWithOnlyATrailingPipe() {
        let ins = E.apply(.insertColumn(left: true), row: 2, column: 0, in: trailingOnly)
        XCTAssertEqual(cells(ins?.source ?? ""), [["", "a", "b"], ["", "1", "2"]])
        let del = E.apply(.deleteColumn, row: 2, column: 0, in: trailingOnly)
        XCTAssertEqual(cells(del?.source ?? ""), [["b"], ["2"]])
    }

    func testDeletingAFirstEmptyCellWithNoLeadingPipeKeepsTheNextEmptyOne() {
        let s = "a | | c\n--|--|--\n1 | | 3"
        let r = E.apply(.deleteColumn, row: 2, column: 0, in: s)
        XCTAssertEqual(cells(r?.source ?? ""), [["", "c"], ["", "3"]])
    }

    func testColumnOperationsOnARaggedTable() {
        let ins = E.apply(.insertColumn(left: false), row: 3, column: 0, in: ragged)
        XCTAssertEqual(shape(ins?.source ?? "").columns, 5)
        XCTAssertEqual(cells(ins?.source ?? "")[2], ["x", "", "y"])
        XCTAssertEqual(cells(ins?.source ?? "")[0], ["a", "", "b", "c"])
        let del = E.apply(.deleteColumn, row: 4, column: 3, in: ragged)
        XCTAssertEqual(shape(del?.source ?? "").columns, 3)
        XCTAssertEqual(cells(del?.source ?? "")[1], ["1"], "a short row without that cell is left alone")
        let delFirst = E.apply(.deleteColumn, row: 2, column: 0, in: ragged)
        XCTAssertEqual(cells(delFirst?.source ?? "")[1], [], "its only cell went with it")
        XCTAssertEqual(shape(delFirst?.source ?? "").rows, 5)
    }

    func testInsertingAColumnAtAShortRowsMissingColumnPadsThatRow() {
        let r = E.apply(.insertColumn(left: false), row: 2, column: 2, in: ragged)
        XCTAssertEqual(cells(r?.source ?? "")[1], ["1", "", "", ""], "it can hold the new cell")
        XCTAssertEqual(r.map { E.place(in: $0.source, at: $0.caret) }, P(row: 2, column: 3, offset: 0))
    }

    func testDeletingAColumnWhenTheDelimiterRowIsShort() {
        let s = "| a | b | c |\n|---|\n| 1 | 2 | 3 |"
        XCTAssertEqual(shape(s).columns, 3)
        let r = E.apply(.deleteColumn, row: 2, column: 0, in: s)
        XCTAssertEqual(cells(r?.source ?? ""), [["b", "c"], ["2", "3"]])
        XCTAssertNotNil(PipeTable.parse(r?.source ?? ""), "the delimiter row is still one")
        let ins = E.apply(.insertColumn(left: false), row: 2, column: 2, in: s)
        XCTAssertEqual(shape(ins?.source ?? "").columns, 4)
        XCTAssertEqual(alignments(ins?.source ?? "").count, 4)
    }

    func testColumnOperationsKeepInlineSyntaxAndEscapedPipes() {
        let r = E.apply(.deleteColumn, row: 2, column: 1, in: inline)
        XCTAssertEqual(cells(r?.source ?? ""), [["Bold x", "link", "plain"], ["a|b", "ü😀 é", "b c"]])
        XCTAssertEqual(alignments(r?.source ?? ""), [.left, .right, .left])
        let ins = E.apply(.insertColumn(left: true), row: 2, column: 0, in: inline)
        XCTAssertEqual(cells(ins?.source ?? ""), [["", "Bold x", "code span", "link", "plain"], ["", "a|b", "", "ü😀 é", "b c"]])
    }

    func testAllowsAgreesWithApplyEverywhere() {
        let ops: [E.Structure] = [.insertRow(above: true), .insertRow(above: false), .deleteRow, .insertColumn(left: true),
                                  .insertColumn(left: false), .deleteColumn]
        for s in allTables {
            let (rows, columns) = shape(s)
            for r in -1...rows {
                for c in -1...columns {
                    for op in ops {
                        let applied = E.apply(op, row: r, column: c, in: s)
                        XCTAssertEqual(E.allows(op, row: r, column: c, in: s), applied != nil, "\(op) at \(r),\(c) in \(s)")
                        if let applied { XCTAssertNotNil(PipeTable.parse(applied.source), "\(op) at \(r),\(c) broke \(s)") }
                    }
                }
            }
        }
    }

    func testEveryStructureEditHasTheShapeItPromises() {
        for s in allTables {
            let (rows, columns) = shape(s)
            for r in 0..<rows {
                for c in 0..<columns {
                    func check(_ op: E.Structure, rows dr: Int, columns dc: Int) {
                        guard let result = E.apply(op, row: r, column: c, in: s) else { return }
                        let after = shape(result.source)
                        XCTAssertEqual(after.rows, rows + dr, "\(op) at \(r),\(c) in \(s)")
                        if case .deleteRow = op {
                            XCTAssertLessThanOrEqual(after.columns, columns, "the widest row can go")
                        } else {
                            XCTAssertEqual(after.columns, columns + dc, "\(op) at \(r),\(c) in \(s)")
                        }
                        XCTAssertEqual(alignments(result.source).count, after.columns)
                        XCTAssertEqual(E.place(in: result.source, at: result.caret).map { $0.row != 1 }, true)
                    }
                    check(.insertRow(above: true), rows: 1, columns: 0)
                    check(.insertRow(above: false), rows: 1, columns: 0)
                    check(.deleteRow, rows: -1, columns: 0)
                    check(.insertColumn(left: true), rows: 0, columns: 1)
                    check(.insertColumn(left: false), rows: 0, columns: 1)
                    check(.deleteColumn, rows: 0, columns: -1)
                }
            }
        }
    }

    func testInsertingThenDeletingAColumnRestoresTheContent() {
        for s in allTables where cells(s).allSatisfy({ $0.count == shape(s).columns }) {
            let (rows, columns) = shape(s)
            for c in 0..<columns {
                guard let inserted = E.apply(.insertColumn(left: true), row: min(2, rows - 1), column: c, in: s),
                      let back = E.apply(.deleteColumn, row: min(2, rows - 1), column: c, in: inserted.source) else { XCTFail(s); continue }
                XCTAssertEqual(cells(back.source), cells(s), "column \(c) of \(s)")
                XCTAssertEqual(alignments(back.source).prefix(columns), alignments(s).prefix(columns))
            }
        }
    }

    func testInsertingThenDeletingARowRestoresTheSource() {
        for s in allTables where shape(s).rows > 2 {
            for r in 2..<shape(s).rows {
                guard let inserted = E.apply(.insertRow(above: true), row: r, column: 0, in: s),
                      let back = E.apply(.deleteRow, row: r, column: 0, in: inserted.source) else { XCTFail(s); continue }
                XCTAssertEqual(back.source, s)
            }
        }
    }

    // MARK: Structure: append

    func testAppendRow() {
        let r = E.appendRow(in: basic, caretColumn: 0)
        XCTAssertEqual(r.source, basic + "\n|  |  |")
        XCTAssertEqual(E.place(in: r.source, at: r.caret), P(row: 4, column: 0, offset: 0))
    }

    func testAppendRowPutsTheCaretInTheAskedColumn() {
        let r = E.appendRow(in: basic, caretColumn: 1)
        XCTAssertEqual(E.place(in: r.source, at: r.caret), P(row: 4, column: 1, offset: 0))
        XCTAssertGreaterThan(r.caret, off(r.source, "\n|  |"))
    }

    func testAppendRowClampsTheColumn() {
        let r = E.appendRow(in: basic, caretColumn: 9)
        XCTAssertEqual(E.place(in: r.source, at: r.caret), P(row: 4, column: 1, offset: 0))
        let r2 = E.appendRow(in: basic, caretColumn: -3)
        XCTAssertEqual(E.place(in: r2.source, at: r2.caret), P(row: 4, column: 0, offset: 0))
    }

    func testAppendRowToAHeaderOnlyTable() {
        let r = E.appendRow(in: headerOnly, caretColumn: 0)
        XCTAssertEqual(r.source, "| a | b |\n|---|---|\n|   |   |")
        XCTAssertEqual(E.place(in: r.source, at: r.caret), P(row: 2, column: 0, offset: 0))
    }

    func testAppendRowInEveryTableKeepsItATableOfOneMoreRow() {
        for s in allTables {
            let r = E.appendRow(in: s, caretColumn: 1)
            XCTAssertEqual(shape(r.source).rows, shape(s).rows + 1, s)
            XCTAssertEqual(shape(r.source).columns, shape(s).columns, s)
            XCTAssertTrue(r.source.hasPrefix(s))
            XCTAssertEqual(cells(r.source).last?.allSatisfy(\.isEmpty), true)
            XCTAssertEqual(cells(r.source).last?.count, shape(s).columns)
        }
    }

    func testTypingIntoANewRowsCellPutsTheTextInIt() {
        let r = E.appendRow(in: basic, caretColumn: 1)
        let typed = E.type("hi", over: NSRange(location: r.caret, length: 0), in: r.source)
        XCTAssertEqual(cells(typed?.source ?? "").last, ["", "hi"])
    }

    func testAppendRowToANonTable() {
        let r = E.appendRow(in: "nope", caretColumn: 0)
        XCTAssertEqual(r.source, "nope")
        XCTAssertEqual(r.caret, 4)
    }

    // MARK: Navigation

    private func move(_ key: E.Key, _ marked: String, textOffset: Int? = nil) -> E.Move {
        let (s, sel) = unmark(marked)
        return E.move(key, from: sel.location, in: s, textOffset: textOffset)
    }

    private func place(_ marked: String) -> P {
        let (s, sel) = unmark(marked)
        return place(s, sel.location)
    }

    /// Where a `.caret` move lands, as a place in `source`.
    private func landing(_ move: E.Move, in source: String) -> P? {
        guard case .caret(let o) = move else { return nil }
        return E.place(in: source, at: o)
    }

    private let nav = "| Name | Area |\n|------|------|\n| alpha | beta |\n| gamma | delta |"

    private func moveFrom(_ key: E.Key, _ p: P, in source: String? = nil, textOffset: Int? = nil) -> E.Move {
        let s = source ?? nav
        let o = E.sourceOffset(in: s, of: p) ?? -1
        return E.move(key, from: o, in: s, textOffset: textOffset)
    }

    func testRightStepsThroughTheTextThenIntoTheNextCell() {
        XCTAssertEqual(landing(moveFrom(.right, P(row: 2, column: 0, offset: 2)), in: nav), P(row: 2, column: 0, offset: 3))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 2, column: 0, offset: 4)), in: nav), P(row: 2, column: 0, offset: 5))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 2, column: 0, offset: 5)), in: nav), P(row: 2, column: 1, offset: 0), "the start of the next cell")
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 1, offset: 4)), in: nav), P(row: 2, column: 0, offset: 0), "past the end of a row, over the delimiter row")
    }

    func testLeftStepsThroughTheTextThenIntoThePreviousCell() {
        XCTAssertEqual(landing(moveFrom(.left, P(row: 2, column: 0, offset: 3)), in: nav), P(row: 2, column: 0, offset: 2))
        XCTAssertEqual(landing(moveFrom(.left, P(row: 2, column: 1, offset: 0)), in: nav), P(row: 2, column: 0, offset: 5), "the end of the previous cell")
        XCTAssertEqual(landing(moveFrom(.left, P(row: 2, column: 0, offset: 0)), in: nav), P(row: 0, column: 1, offset: 4), "back over the delimiter row")
    }

    func testLeftAndRightLeaveTheTable() {
        XCTAssertEqual(moveFrom(.left, P(row: 0, column: 0, offset: 0)), .leave(.before))
        XCTAssertEqual(moveFrom(.right, P(row: 3, column: 1, offset: 5)), .leave(.after))
        XCTAssertEqual(moveFrom(.right, P(row: 3, column: 1, offset: 4)).isCaret, true)
    }

    func testUpAndDownKeepTheColumn() {
        XCTAssertEqual(landing(moveFrom(.down, P(row: 2, column: 1, offset: 2)), in: nav), P(row: 3, column: 1, offset: 2))
        XCTAssertEqual(landing(moveFrom(.up, P(row: 3, column: 1, offset: 2)), in: nav), P(row: 2, column: 1, offset: 2))
        XCTAssertEqual(landing(moveFrom(.down, P(row: 0, column: 1, offset: 2)), in: nav), P(row: 2, column: 1, offset: 2), "down from the header skips the delimiter row")
        XCTAssertEqual(landing(moveFrom(.up, P(row: 2, column: 0, offset: 3)), in: nav), P(row: 0, column: 0, offset: 3), "and so does up")
    }

    func testUpAndDownClampTheOffsetToTheCellsText() {
        XCTAssertEqual(landing(moveFrom(.down, P(row: 2, column: 0, offset: 5)), in: nav), P(row: 3, column: 0, offset: 5))
        XCTAssertEqual(landing(moveFrom(.up, P(row: 3, column: 1, offset: 5)), in: nav), P(row: 2, column: 1, offset: 4), "beta is shorter than delta")
        XCTAssertEqual(landing(moveFrom(.down, P(row: 0, column: 0, offset: 2), textOffset: 3), in: nav), P(row: 2, column: 0, offset: 3), "the editor's x wins")
        XCTAssertEqual(landing(moveFrom(.down, P(row: 0, column: 0, offset: 2), textOffset: 99), in: nav), P(row: 2, column: 0, offset: 5))
        XCTAssertEqual(landing(moveFrom(.down, P(row: 0, column: 0, offset: 2), textOffset: -4), in: nav), P(row: 2, column: 0, offset: 0))
        XCTAssertEqual(landing(moveFrom(.up, P(row: 3, column: 0, offset: 2), textOffset: 0), in: nav), P(row: 2, column: 0, offset: 0))
    }

    func testUpAndDownLeaveTheTable() {
        XCTAssertEqual(moveFrom(.up, P(row: 0, column: 0, offset: 2)), .leave(.before))
        XCTAssertEqual(moveFrom(.up, P(row: 0, column: 1, offset: 0)), .leave(.before))
        XCTAssertEqual(moveFrom(.down, P(row: 3, column: 0, offset: 2)), .leave(.after))
        XCTAssertEqual(moveFrom(.down, P(row: 3, column: 1, offset: 0)), .leave(.after))
    }

    func testDownFromTheHeaderOfAHeaderOnlyTableLeaves() {
        XCTAssertEqual(moveFrom(.down, P(row: 0, column: 0, offset: 0), in: headerOnly), .leave(.after))
    }

    func testTabGoesToTheNextCellsEnd() {
        XCTAssertEqual(landing(moveFrom(.tab, P(row: 0, column: 0, offset: 1)), in: nav), P(row: 0, column: 1, offset: 4))
        XCTAssertEqual(landing(moveFrom(.tab, P(row: 0, column: 1, offset: 0)), in: nav), P(row: 2, column: 0, offset: 5), "to the next row over the delimiter row")
        XCTAssertEqual(landing(moveFrom(.tab, P(row: 2, column: 1, offset: 0)), in: nav), P(row: 3, column: 0, offset: 5))
    }

    func testTabInTheLastCellAppendsARow() {
        XCTAssertEqual(moveFrom(.tab, P(row: 3, column: 1, offset: 2)), .appendRow(column: 0))
        XCTAssertEqual(moveFrom(.tab, P(row: 0, column: 0, offset: 0), in: singleCell.replacingOccurrences(of: "\n| b |", with: "")), .appendRow(column: 0))
    }

    func testBacktabGoesToThePreviousCellsEnd() {
        XCTAssertEqual(landing(moveFrom(.backtab, P(row: 0, column: 1, offset: 2)), in: nav), P(row: 0, column: 0, offset: 4))
        XCTAssertEqual(landing(moveFrom(.backtab, P(row: 2, column: 0, offset: 2)), in: nav), P(row: 0, column: 1, offset: 4))
        XCTAssertEqual(landing(moveFrom(.backtab, P(row: 3, column: 0, offset: 0)), in: nav), P(row: 2, column: 1, offset: 4))
    }

    func testBacktabInTheFirstCellLeaves() {
        XCTAssertEqual(moveFrom(.backtab, P(row: 0, column: 0, offset: 3)), .leave(.before))
    }

    func testReturnGoesDownTheColumn() {
        XCTAssertEqual(landing(moveFrom(.return, P(row: 2, column: 1, offset: 1)), in: nav), P(row: 3, column: 1, offset: 5))
        XCTAssertEqual(landing(moveFrom(.return, P(row: 0, column: 0, offset: 1)), in: nav), P(row: 2, column: 0, offset: 5), "from the header to the first body row")
    }

    func testReturnInTheLastRowAppendsARowInTheSameColumn() {
        XCTAssertEqual(moveFrom(.return, P(row: 3, column: 1, offset: 2)), .appendRow(column: 1))
        XCTAssertEqual(moveFrom(.return, P(row: 3, column: 0, offset: 0)), .appendRow(column: 0))
        XCTAssertEqual(moveFrom(.return, P(row: 0, column: 1, offset: 0), in: headerOnly), .appendRow(column: 1))
    }

    func testMovesFromTheDelimiterRowActFromTheHeadersEnd() {
        let o = off(nav, "|------|") + 3
        XCTAssertEqual(landing(E.move(.right, from: o, in: nav), in: nav), P(row: 2, column: 0, offset: 0))
        XCTAssertEqual(landing(E.move(.left, from: o, in: nav), in: nav), P(row: 0, column: 1, offset: 3))
        XCTAssertEqual(landing(E.move(.down, from: o, in: nav), in: nav), P(row: 2, column: 1, offset: 4))
    }

    func testMovesFromPaddingAndPipes() {
        let pipe = off(nav, "| Area")
        XCTAssertEqual(landing(E.move(.left, from: pipe, in: nav), in: nav), P(row: 0, column: 0, offset: 3), "on the pipe: the end of the cell before")
        XCTAssertEqual(landing(E.move(.right, from: pipe, in: nav), in: nav), P(row: 0, column: 1, offset: 0), "end of Name, so into Area")
    }

    func testStepsOverAWholeEmojiAndCombiningMark() {
        let s = tbl("| a😀e\u{301}b | c |", "|---|---|")
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 0, offset: 1), in: s), in: s), P(row: 0, column: 0, offset: 3))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 0, offset: 3), in: s), in: s), P(row: 0, column: 0, offset: 5))
        XCTAssertEqual(landing(moveFrom(.left, P(row: 0, column: 0, offset: 3), in: s), in: s), P(row: 0, column: 0, offset: 1))
        XCTAssertEqual(landing(moveFrom(.left, P(row: 0, column: 0, offset: 5), in: s), in: s), P(row: 0, column: 0, offset: 3))
    }

    func testStepsOverHiddenSyntaxAndEscapedPipes() {
        let s = inline
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 0, offset: 3), in: s), in: s), P(row: 0, column: 0, offset: 4))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 0, offset: 4), in: s), in: s), P(row: 0, column: 0, offset: 5))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 0, offset: 6), in: s), in: s), P(row: 0, column: 1, offset: 0), "from the end of a cell ending in a run")
        XCTAssertEqual(landing(moveFrom(.right, P(row: 2, column: 0, offset: 1), in: s), in: s), P(row: 2, column: 0, offset: 2), "over \\|")
        XCTAssertEqual(landing(moveFrom(.left, P(row: 2, column: 0, offset: 2), in: s), in: s), P(row: 2, column: 0, offset: 1))
    }

    func testEveryRightMoveAdvancesAndEveryLeftMoveRetreats() {
        for s in allTables {
            var o = 0
            var seen = Set<Int>()
            var steps = 0
            while steps < 400 {
                let p = place(s, o)
                guard case .caret(let next) = E.move(.right, from: o, in: s) else { break }
                let q = place(s, next)
                XCTAssertTrue((q.row, q.column, q.offset) > (p.row, p.column, p.offset), "\(p) -> \(q) in \(s)")
                XCTAssertTrue(seen.insert(next).inserted, "loop at \(next) in \(s)")
                o = next
                steps += 1
            }
            XCTAssertLessThan(steps, 400, "right walks the whole table of \(s)")
            // Then all the way back.
            var back = 0
            while case .caret(let prev) = E.move(.left, from: o, in: s) {
                let p = place(s, o), q = place(s, prev)
                XCTAssertTrue((q.row, q.column, q.offset) < (p.row, p.column, p.offset), "\(p) -> \(q) in \(s)")
                o = prev
                back += 1
                if back > 400 { XCTFail("left loops in \(s)"); break }
            }
            XCTAssertEqual(place(s, o), P(row: 0, column: 0, offset: 0))
        }
    }

    func testTabVisitsEveryCellOnce() {
        for s in allTables {
            guard let t = PipeTable.parse(s) else { continue }
            let expected = t.rows.indices.filter { $0 != 1 }.reduce(0) { $0 + max(1, t.rows[$1].cells.count) }
            var o = E.sourceOffset(in: s, of: P(row: 0, column: 0, offset: 0)) ?? 0
            var visited = 1
            while case .caret(let next) = E.move(.tab, from: o, in: s) {
                o = next
                visited += 1
                if visited > 1000 { XCTFail("tab loops in \(s)"); break }
            }
            XCTAssertEqual(visited, expected, "cells in \(s)")
            XCTAssertEqual(E.move(.tab, from: o, in: s), .appendRow(column: 0))
        }
    }

    func testVerticalMovesInARaggedTableClampToTheShortRow() {
        let s = ragged
        XCTAssertEqual(landing(moveFrom(.down, P(row: 0, column: 2, offset: 1), in: s), in: s), P(row: 2, column: 0, offset: 1), "the short row's last cell")
        XCTAssertEqual(landing(moveFrom(.down, P(row: 3, column: 1, offset: 1), in: s), in: s), P(row: 4, column: 1, offset: 1))
        XCTAssertEqual(landing(moveFrom(.up, P(row: 4, column: 3, offset: 1), in: s), in: s), P(row: 3, column: 1, offset: 1))
        XCTAssertEqual(moveFrom(.return, P(row: 4, column: 3, offset: 0), in: s), .appendRow(column: 3))
    }

    func testTabInARaggedTableOnlyVisitsRealCells() {
        let s = ragged
        XCTAssertEqual(landing(moveFrom(.tab, P(row: 2, column: 0, offset: 0), in: s), in: s), P(row: 3, column: 0, offset: 1), "from the short row to the next row")
        XCTAssertEqual(landing(moveFrom(.backtab, P(row: 3, column: 0, offset: 0), in: s), in: s), P(row: 2, column: 0, offset: 1))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 2, offset: 1), in: s), in: s), P(row: 2, column: 0, offset: 0))
    }

    func testNavigationInASingleCellTable() {
        let s = singleCell
        XCTAssertEqual(moveFrom(.left, P(row: 0, column: 0, offset: 0), in: s), .leave(.before))
        XCTAssertEqual(moveFrom(.up, P(row: 0, column: 0, offset: 1), in: s), .leave(.before))
        XCTAssertEqual(landing(moveFrom(.down, P(row: 0, column: 0, offset: 1), in: s), in: s), P(row: 2, column: 0, offset: 1))
        XCTAssertEqual(moveFrom(.down, P(row: 2, column: 0, offset: 1), in: s), .leave(.after))
        XCTAssertEqual(moveFrom(.right, P(row: 2, column: 0, offset: 1), in: s), .leave(.after))
        XCTAssertEqual(moveFrom(.tab, P(row: 2, column: 0, offset: 1), in: s), .appendRow(column: 0))
        XCTAssertEqual(moveFrom(.return, P(row: 2, column: 0, offset: 1), in: s), .appendRow(column: 0))
    }

    func testNavigationThroughEmptyCells() {
        let s = emptyCells
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 0, offset: 0), in: s), in: s), P(row: 0, column: 1, offset: 0))
        XCTAssertEqual(landing(moveFrom(.right, P(row: 0, column: 1, offset: 0), in: s), in: s), P(row: 2, column: 0, offset: 0))
        XCTAssertEqual(landing(moveFrom(.left, P(row: 2, column: 1, offset: 0), in: s), in: s), P(row: 2, column: 0, offset: 0))
    }

    func testMovesOnANonTableStayPut() {
        XCTAssertEqual(E.move(.right, from: 3, in: "nope"), .caret(3))
    }

    // MARK: Copy

    private func copying(_ marked: String) -> String? {
        let (s, sel) = unmark(marked)
        return E.copyText(of: sel, in: s)
    }

    func testCopyOfAnEmptySelectionIsNil() {
        XCTAssertNil(copying("| a‸lpha | b |\n|---|---|"))
        XCTAssertNil(E.copyText(of: NSRange(location: 3, length: 0), in: basic))
    }

    func testCopyInsideACellIsTheSelectedSource() {
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| a«lph»a | b |")), "lph")
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| «alpha» | b |")), "alpha")
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| «alpha   » | b |")), "alpha", "padding is not the cell's text")
        XCTAssertEqual(copying(tbl("| «h» | i |", "|---|---|", "| a | b |")), "h")
    }

    func testCopyOfAWholeCellKeepsItsMarkdown() {
        XCTAssertEqual(copying(tbl("| **Bold** x | b |", "|---|---|", "| «**b** `c`» | b |")), "**b** `c`")
        XCTAssertEqual(copying(tbl("| «**Bold**» | b |", "|---|---|")), "**Bold**")
        XCTAssertEqual(copying(tbl("| «[link](http://x.y)» | b |", "|---|---|")), "[link](http://x.y)")
        XCTAssertEqual(copying(tbl(#"| «a\|b» | c |"#, "|---|---|")), #"a\|b"#, "an escaped pipe stays escaped in source")
    }

    func testCopyOfPartOfARun() {
        XCTAssertEqual(copying(tbl("| **B«ol»d** | c |", "|---|---|")), "ol")
        XCTAssertEqual(copying(tbl("| x «**b** y» | c |", "|---|---|")), "b** y", "from the first shown character")
    }

    func testCopyAcrossCellsInARowIsATable() {
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| a«lpha | bet»a |", "| gamma | delta |")),
                       tbl("| h | i |", "|---|---|", "| alpha | beta |"))
    }

    func testCopyAcrossRows() {
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| a«lpha | beta |", "| gam»ma | delta |", "| x | y |")),
                       tbl("| h | i |", "|---|---|", "| alpha | beta |", "| gamma | delta |"))
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| a | b |", "| c«c | d |", "| e | f»f |")),
                       tbl("| h | i |", "|---|---|", "| cc | d |", "| e | ff |"))
    }

    func testCopyFromTheHeaderStartsAtTheHeader() {
        XCTAssertEqual(copying(tbl("| «h | i |", "|---|---|", "| a | b |", "| c | d» |")), tbl("| h | i |", "|---|---|", "| a | b |", "| c | d |"))
        XCTAssertEqual(copying(tbl("| h«1 | i1 |", "|----|----|", "| a | b»1 |", "| c | d |")), tbl("| h1 | i1 |", "|----|----|", "| a | b1 |"))
    }

    func testCopyAcrossTheHeaderCellsIsTheHeaderAndDelimiter() {
        XCTAssertEqual(copying(tbl("| h«1 | i»1 |", "|----|----|", "| a | b |")), tbl("| h1 | i1 |", "|----|----|"))
    }

    func testCopyOfTheWholeTableIsTheTable() {
        let (s, _) = unmark(basic + "‸")
        XCTAssertEqual(E.copyText(of: NSRange(location: 0, length: utf16Count(s)), in: s), s)
    }

    func testCopyStartingInTheDelimiterRow() {
        let (s, _) = unmark(basic + "‸")
        let o = off(s, "|------|") + 2
        XCTAssertEqual(E.copyText(of: NSRange(location: o, length: off(s, "gamma", end: true) - o), in: s),
                       tbl("| Name | Area |", "|------|------|", "| alpha | beta |", "| gamma | delta |"))
    }

    func testCopyThatOnlyTouchesCellEdges() {
        // Starts at the end of alpha and ends at the start of gamma: only beta is reached.
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| alpha« | beta |", "| »gamma | delta |")), "beta")
        // From the middle of alpha to the start of gamma: the row is.
        XCTAssertEqual(copying(tbl("| h | i |", "|---|---|", "| al«pha | beta |", "| »gamma | delta |")),
                       tbl("| h | i |", "|---|---|", "| alpha | beta |"))
        // Padding and pipes only.
        XCTAssertNil(copying(tbl("| h | i |", "|---|---|", "| alpha« | »beta |")))
        XCTAssertNil(copying(tbl("| h | i |", "|---|---|", "| alpha«  »| beta |")))
    }

    func testCopyOfAnEmptyCellsPaddingIsNil() {
        XCTAssertNil(copying(tbl("| h | i |", "|---|---|", "|« »| x |")))
    }

    func testCopyKeepsRaggedRowsAsTheyAre() {
        let s = ragged
        let from = off(s, "| 1 |"), to = off(s, "| x | y |", end: true)
        XCTAssertEqual(E.copyText(of: NSRange(location: from, length: to - from), in: s), "| a | b | c |\n|---|---|---|\n| 1 |\n| x | y |")
    }

    func testCopyRoundTripsThroughPaste() {
        // A cell's copy pasted into another cell is the same text there.
        let s = tbl("| **a** | b |", "|---|---|", "| `x` | c |")
        let copied = copying(tbl("| «**a**» | b |", "|---|---|", "| `x` | c |"))
        let pasted = E.paste(copied ?? "", over: NSRange(location: off(s, "c"), length: 1), in: s)
        XCTAssertEqual(cells(pasted?.source ?? ""), [["a", "b"], ["x", "a"]])
    }

    func testCopyClampsAnOverlongSelection() {
        XCTAssertNotNil(E.copyText(of: NSRange(location: 3, length: 10_000), in: basic))
        XCTAssertNil(E.copyText(of: NSRange(location: 10_000, length: 5), in: basic))
    }

    // MARK: Diff placement

    private func inserted(_ range: NSRange) -> E.Change { E.Change(kind: .inserted, range: range) }

    private func deleted(at offset: Int, _ ghost: String) -> E.Change {
        E.Change(kind: .deleted, range: NSRange(location: offset, length: 0), ghost: ghost)
    }

    private func range(_ s: String, from: String, to: String? = nil) -> NSRange {
        let a = off(s, from)
        let b = off(s, to ?? from, end: true)
        return NSRange(location: a, length: b - a)
    }

    private typealias M = PlanTableEditing.CellMark

    func testInsertedInsideACell() {
        let marks = E.marks(for: [inserted(range(basic, from: "lph"))], in: basic)
        XCTAssertEqual(marks, [M(kind: .inserted, row: 2, column: 0, textRange: NSRange(location: 1, length: 3))])
        XCTAssertEqual(marks.first?.wholeCell, false)
    }

    func testInsertedWholeCell() {
        let marks = E.marks(for: [inserted(range(basic, from: "alpha"))], in: basic)
        XCTAssertEqual(marks, [M(kind: .inserted, row: 2, column: 0, textRange: NSRange(location: 0, length: 5), wholeCell: true)])
        // The cell with its padding is the same.
        let padded = E.marks(for: [inserted(range(basic, from: " alpha "))], in: basic)
        XCTAssertEqual(padded, marks)
    }

    func testInsertedSpanningTwoCells() {
        let marks = E.marks(for: [inserted(range(basic, from: "pha | be"))], in: basic)
        XCTAssertEqual(marks, [
            M(kind: .inserted, row: 2, column: 0, textRange: NSRange(location: 2, length: 3)),
            M(kind: .inserted, row: 2, column: 1, textRange: NSRange(location: 0, length: 2)),
        ])
    }

    func testInsertedSpanningRows() {
        let marks = E.marks(for: [inserted(range(basic, from: "ha | beta |\n| gam"))], in: basic)
        XCTAssertEqual(marks, [
            M(kind: .inserted, row: 2, column: 0, textRange: NSRange(location: 3, length: 2)),
            M(kind: .inserted, row: 2, column: 1, textRange: NSRange(location: 0, length: 4), wholeCell: true),
            M(kind: .inserted, row: 3, column: 0, textRange: NSRange(location: 0, length: 3)),
        ])
    }

    func testInsertedWholeRowIsOneRowMark() {
        let line = range(basic, from: "| gamma | delta |")
        let row = M(kind: .inserted, row: 3, column: nil, textRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(E.marks(for: [inserted(line)], in: basic), [row])
        let withNewline = NSRange(location: line.location - 1, length: line.length + 1)
        XCTAssertEqual(E.marks(for: [inserted(withNewline)], in: basic), [row], "with the newline before it")
        let after = NSRange(location: range(basic, from: "| alpha | beta |").location, length: 17)
        XCTAssertEqual(E.marks(for: [inserted(after)], in: basic), [M(kind: .inserted, row: 2, column: nil, textRange: NSRange(location: 0, length: 0))],
                       "with the newline after it")
    }

    func testInsertedSeveralRows() {
        let from = off(basic, "| alpha")
        let marks = E.marks(for: [inserted(NSRange(location: from, length: utf16Count(basic) - from))], in: basic)
        XCTAssertEqual(marks.map(\.row), [2, 3])
        XCTAssertTrue(marks.allSatisfy { $0.column == nil && $0.kind == .inserted })
    }

    func testInsertedWholeTableMarksEveryRowButTheDelimiterRow() {
        let marks = E.marks(for: [inserted(NSRange(location: 0, length: utf16Count(basic)))], in: basic)
        XCTAssertEqual(marks.map(\.row), [0, 2, 3])
        XCTAssertTrue(marks.allSatisfy { $0.column == nil })
    }

    func testTheDelimiterRowTakesNoMarks() {
        XCTAssertEqual(E.marks(for: [inserted(range(basic, from: "|------|------|"))], in: basic), [])
        XCTAssertEqual(E.marks(for: [inserted(range(basic, from: "---"))], in: basic), [])
        XCTAssertEqual(E.marks(for: [deleted(at: off(basic, "|------|") + 3, "x")], in: basic), [])
        let across = E.marks(for: [inserted(range(basic, from: "Area |\n|------|------|\n| alp"))], in: basic)
        XCTAssertEqual(across.map(\.row), [0, 2], "the header, then the first body row; nothing between")
    }

    func testInsertedPipesAndPaddingTakeNoMarks() {
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: off(basic, "| Area"), length: 1))], in: basic), [], "a pipe")
        XCTAssertEqual(E.marks(for: [inserted(range(basic, from: " | "))], in: basic), [], "padding and a pipe")
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: 3, length: 0))], in: basic), [], "nothing")
    }

    func testInsertedHiddenSyntaxTakesNoMark() {
        let s = inline
        let bold = off(s, "**Bold**")
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: bold, length: 2))], in: s), [], "the opening **")
        let marks = E.marks(for: [inserted(NSRange(location: bold, length: 8))], in: s)
        XCTAssertEqual(marks, [M(kind: .inserted, row: 0, column: 0, textRange: NSRange(location: 0, length: 4))], "**Bold**: the word, not the whole cell")
        let part = E.marks(for: [inserted(NSRange(location: bold + 3, length: 2))], in: s)
        XCTAssertEqual(part, [M(kind: .inserted, row: 0, column: 0, textRange: NSRange(location: 1, length: 2))])
    }

    func testInsertedWholeBoldCellIsWholeCell() {
        let s = tbl("| **Bold** | b |", "|---|---|")
        let marks = E.marks(for: [inserted(NSRange(location: 2, length: 8))], in: s)
        XCTAssertEqual(marks, [M(kind: .inserted, row: 0, column: 0, textRange: NSRange(location: 0, length: 4), wholeCell: true)])
    }

    func testInsertedLinkMarksTheTextNotTheUrl() {
        let s = inline
        let link = off(s, "[link](http://x.y)")
        let marks = E.marks(for: [inserted(NSRange(location: link + 5, length: 13))], in: s)
        XCTAssertEqual(marks, [], "only the ](http://x.y) part")
        let all = E.marks(for: [inserted(NSRange(location: link, length: 18))], in: s)
        XCTAssertEqual(all, [M(kind: .inserted, row: 0, column: 2, textRange: NSRange(location: 0, length: 4), wholeCell: true)])
    }

    func testInsertedEscapedPipe() {
        let s = inline
        let a = off(s, #"a\|b"#)
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: a + 1, length: 1))], in: s), [], "the backslash")
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: a + 1, length: 2))], in: s),
                       [M(kind: .inserted, row: 2, column: 0, textRange: NSRange(location: 1, length: 1))], "the backslash and the pipe: one shown character")
    }

    func testInsertedUnicodeCountsUTF16Units() {
        let s = inline
        let u = off(s, "ü😀 é")
        let marks = E.marks(for: [inserted(NSRange(location: u + 1, length: 2))], in: s)
        XCTAssertEqual(marks, [M(kind: .inserted, row: 2, column: 2, textRange: NSRange(location: 1, length: 2))])
    }

    func testDeletedGhostGoesWhereItFell() {
        let at = off(basic, "alpha") + 2
        XCTAssertEqual(E.marks(for: [deleted(at: at, "zz")], in: basic),
                       [M(kind: .deleted, row: 2, column: 0, textRange: NSRange(location: 2, length: 0), ghost: "zz")])
        let end = off(basic, "alpha", end: true)
        XCTAssertEqual(E.marks(for: [deleted(at: end, "zz")], in: basic).first?.textRange, NSRange(location: 5, length: 0))
        XCTAssertEqual(E.marks(for: [deleted(at: off(basic, "alpha"), "zz")], in: basic).first?.textRange, NSRange(location: 0, length: 0))
    }

    func testDeletedInPaddingOrOnAPipeGoesToTheNearestCellEdge() {
        let pipe = off(basic, "| beta")
        XCTAssertEqual(E.marks(for: [deleted(at: pipe, "g")], in: basic).first, M(kind: .deleted, row: 2, column: 0, textRange: NSRange(location: 5, length: 0), ghost: "g"))
        XCTAssertEqual(E.marks(for: [deleted(at: pipe + 1, "g")], in: basic).first, M(kind: .deleted, row: 2, column: 1, textRange: NSRange(location: 0, length: 0), ghost: "g"))
        XCTAssertEqual(E.marks(for: [deleted(at: utf16Count(basic), "g")], in: basic).first, M(kind: .deleted, row: 3, column: 1, textRange: NSRange(location: 5, length: 0), ghost: "g"))
    }

    func testDeletedInsideHiddenSyntaxGoesToTheNearestShownPosition() {
        let s = inline
        let bold = off(s, "**Bold**")
        XCTAssertEqual(E.marks(for: [deleted(at: bold + 1, "x")], in: s).first?.textRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(E.marks(for: [deleted(at: bold + 7, "x")], in: s).first?.textRange, NSRange(location: 4, length: 0))
    }

    func testDeletedRowIsARowMark() {
        let at = off(basic, "| gamma")
        XCTAssertEqual(E.marks(for: [deleted(at: at, "| old | row |\n")], in: basic),
                       [M(kind: .deleted, row: 3, column: nil, textRange: NSRange(location: 0, length: 0), ghost: "| old | row |\n")])
        let afterAlpha = off(basic, "| alpha | beta |", end: true)
        XCTAssertEqual(E.marks(for: [deleted(at: afterAlpha, "\n| old | row |")], in: basic).first?.row, 2)
    }

    func testDeletedFirstBodyRowAtTheDelimiterRowsEndIsRowTwo() {
        let end = off(basic, "|------|------|", end: true)
        XCTAssertEqual(E.marks(for: [deleted(at: end, "\n| old | row |")], in: basic).map(\.row), [2])
    }

    func testDeletedInTheDelimiterRowWithNoNewlineTakesNoMark() {
        XCTAssertEqual(E.marks(for: [deleted(at: off(basic, "|------|") + 2, "-")], in: basic), [])
    }

    func testMarksKeepTheOrderOfTheChanges() {
        let marks = E.marks(for: [inserted(range(basic, from: "delta")), deleted(at: off(basic, "Name") + 1, "x"), inserted(range(basic, from: "Area"))], in: basic)
        XCTAssertEqual(marks.map(\.row), [3, 0, 0])
        XCTAssertEqual(marks.map(\.kind), [.inserted, .deleted, .inserted])
        XCTAssertEqual(marks.map(\.column), [1, 0, 1])
    }

    func testNoChangesNoMarksAndNoTableNoMarks() {
        XCTAssertEqual(E.marks(for: [], in: basic), [])
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: 0, length: 3))], in: "nope"), [])
    }

    func testMarksClampToTheSource() {
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: utf16Count(basic) - 3, length: 100))], in: basic).count, 1)
        XCTAssertEqual(E.marks(for: [inserted(NSRange(location: 5000, length: 4))], in: basic), [])
        XCTAssertEqual(E.marks(for: [deleted(at: 9000, "x")], in: basic).first?.row, 3)
    }

    func testMarksOnEveryCellAreInsideItsText() {
        for s in allTables {
            guard let t = PipeTable.parse(s) else { continue }
            for r in t.rows.indices where r != 1 {
                for (c, cell) in t.rows[r].cells.enumerated() where cell.length > 0 {
                    let n = E.shownText(in: s, row: r, column: c)?.text.utf16.count ?? 0
                    let marks = E.marks(for: [inserted(cell)], in: s)
                    XCTAssertEqual(marks.count, n > 0 ? 1 : 0, "\(r),\(c) in \(s)")
                    if let m = marks.first {
                        XCTAssertEqual(m.row, r)
                        XCTAssertEqual(m.column, c)
                        XCTAssertEqual(m.textRange, NSRange(location: 0, length: n))
                        XCTAssertTrue(m.wholeCell)
                    }
                }
            }
        }
    }

    // MARK: Invariants under random edits

    /// A small deterministic generator (SplitMix64): the same seed, the same run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomTable(_ g: inout Seeded) -> String {
        let words = ["a", "beta", "**bold**", "`code`", "[l](http://x.y)", #"p\|q"#, "ü", "😀", "x y z", "", "- -", "12"]
        let columns = Int.random(in: 1...5, using: &g)
        let rows = Int.random(in: 0...4, using: &g)
        let leading = Bool.random(using: &g) || columns == 1, trailing = Bool.random(using: &g) || columns == 1
        let padded = Bool.random(using: &g)
        func line(_ cells: [String]) -> String {
            let pad = padded ? " " : ""
            let body = cells.map { pad + $0 + pad }.joined(separator: "|")
            return (leading ? "|" : "") + body + (trailing ? "|" : "")
        }
        func row() -> String {
            // The odd short row. A row of one empty cell can't be written without pipes: use a word.
            let n = Int.random(in: 0..<8, using: &g) == 0 ? Int.random(in: 1...columns, using: &g) : columns
            return line((0..<n).map { _ in words.randomElement(using: &g)! })
        }
        let delimiter = line((0..<columns).map { _ in ["---", ":--", "--:", ":-:"].randomElement(using: &g)! })
        var out = [row(), delimiter]
        for _ in 0..<rows { out.append(row()) }
        return out.joined(separator: "\n")
    }

    private func randomSelection(_ s: String, _ g: inout Seeded) -> NSRange {
        let n = utf16Count(s)
        let a = Int.random(in: 0...n, using: &g)
        let len = Int.random(in: 0..<4, using: &g) == 0 ? Int.random(in: 0...min(30, n - a), using: &g) : 0
        return NSRange(location: a, length: len)
    }

    func testRandomEditsKeepTheTableATable() {
        var g = Seeded(state: 0xF11_6874_DEC)
        let safe = Array("ab c|\nüé😀")
        let nasty = Array(#"a\|*`[]()  _~:-#"#)
        var tablesTried = 0, editsApplied = 0
        for _ in 0..<150 {
            var s = randomTable(&g)
            guard PipeTable.parse(s) != nil else { continue }
            tablesTried += 1
            for step in 0..<40 {
                let before = s
                let sel = randomSelection(s, &g)
                let result: E.Result?
                var cellsChange = true
                switch Int.random(in: 0..<10, using: &g) {
                case 0, 1, 2:
                    let text = String((0..<Int.random(in: 1...4, using: &g)).map { _ in safe.randomElement(using: &g)! })
                    result = E.type(text, over: sel, in: s)
                case 3:
                    let text = String((0..<Int.random(in: 1...4, using: &g)).map { _ in nasty.randomElement(using: &g)! })
                    result = E.type(text, over: sel, in: s)
                case 4, 5:
                    result = E.delete(Bool.random(using: &g) ? .backward : .forward, over: sel, in: s)
                case 6:
                    result = E.paste("p|q\r\nr", over: sel, in: s)
                case 7:
                    cellsChange = false
                    let (rows, columns) = shape(s)
                    let ops: [E.Structure] = [.insertRow(above: true), .insertRow(above: false), .deleteRow, .insertColumn(left: true), .insertColumn(left: false), .deleteColumn]
                    let op = ops.randomElement(using: &g)!
                    let r = Int.random(in: 0..<rows, using: &g), c = Int.random(in: 0..<columns, using: &g)
                    result = E.apply(op, row: r, column: c, in: s)
                    if let result {
                        let after = shape(result.source)
                        var dr = 0, dc = 0
                        switch op {
                        case .insertRow: dr = 1
                        case .deleteRow: dr = -1
                        case .insertColumn: dc = 1
                        case .deleteColumn: dc = -1
                        }
                        XCTAssertEqual(after.rows, rows + dr, "\(op) at \(r),\(c) in \(before)")
                        XCTAssertEqual(after.columns, columns + dc, "\(op) at \(r),\(c) in \(before)")
                    } else {
                        XCTAssertFalse(E.allows(op, row: r, column: c, in: s))
                    }
                case 8:
                    cellsChange = false
                    let r = E.appendRow(in: s, caretColumn: Int.random(in: 0..<6, using: &g))
                    XCTAssertEqual(shape(r.source).rows, shape(s).rows + 1)
                    result = r
                default:
                    // Keys never change the source; the caret they report is a place.
                    let keys: [E.Key] = [.left, .right, .up, .down, .tab, .backtab, .return]
                    if case .caret(let o) = E.move(keys.randomElement(using: &g)!, from: sel.location, in: s) {
                        XCTAssertNotNil(E.place(in: s, at: o))
                        XCTAssertTrue((0...utf16Count(s)).contains(o))
                    }
                    continue
                }
                guard let result else { continue }
                editsApplied += 1
                guard let table = PipeTable.parse(result.source) else {
                    XCTFail("step \(step): no longer a table\nbefore: \(before)\nafter: \(result.source)\nselection: \(sel)")
                    break
                }
                XCTAssertEqual(table.alignments.count, table.columnCount)
                XCTAssertTrue((0...utf16Count(result.source)).contains(result.caret), "caret in range")
                if cellsChange {
                    // A text edit changes cell content only: same rows, same cells, same delimiter row.
                    XCTAssertEqual(table.rows.count, PipeTable.parse(before)?.rows.count, "rows\nbefore: \(before)\nafter: \(result.source)\nedit at \(sel)")
                    XCTAssertEqual(table.rows.map(\.cells.count), PipeTable.parse(before)?.rows.map(\.cells.count),
                                   "cell counts\nbefore: \(before)\nafter: \(result.source)\nedit at \(sel)")
                    XCTAssertEqual(lines(result.source)[1], lines(before)[1])
                    XCTAssertEqual(table.alignments, PipeTable.parse(before)?.alignments)
                }
                XCTAssertEqual(E.place(in: result.source, at: result.caret).map { $0.row != 1 }, true)
                s = result.source
            }
        }
        XCTAssertGreaterThan(tablesTried, 100)
        XCTAssertGreaterThan(editsApplied, 1500)
    }

    func testRandomTypingLandsExactlyWhereTheCaretWas() {
        var g = Seeded(state: 77)
        let letters = Array("abcdefgé😀")
        for _ in 0..<100 {
            var s = randomTable(&g)
            guard PipeTable.parse(s) != nil else { continue }
            for _ in 0..<20 {
                let (rows, columns) = shape(s)
                let r = [0, 2, 3, 4].filter { $0 < rows }.randomElement(using: &g)!
                let n = PipeTable.parse(s)!.rows[r].cells.count
                guard n > 0 else { continue }
                let c = Int.random(in: 0..<n, using: &g)
                _ = columns
                guard let shown = E.shownText(in: s, row: r, column: c) else { continue }
                let units = Array(shown.text.utf16)
                let k = Int.random(in: 0...units.count, using: &g)
                // Never between the halves of a surrogate pair.
                if k > 0, k < units.count, UTF16.isLeadSurrogate(units[k - 1]) { continue }
                guard let o = E.sourceOffset(in: s, of: P(row: r, column: c, offset: k)) else { XCTFail(); continue }
                let ch = String(letters.randomElement(using: &g)!)
                guard let out = E.type(ch, over: NSRange(location: o, length: 0), in: s) else { XCTFail("no result"); continue }
                var expected = cells(s)
                let row = r > 1 ? r - 1 : r
                var text = Array(expected[row][c].utf16)
                text.insert(contentsOf: Array(ch.utf16), at: k)
                expected[row][c] = String(decoding: text, as: UTF16.self)
                // Typing inside a run can end it only by typing syntax, and the alphabet has none.
                XCTAssertEqual(cells(out.source), expected, "typing \(ch) at \(r),\(c),\(k) in \(s)")
                s = out.source
            }
        }
    }

    // MARK: Cost

    private func bigTable(rows: Int = 50, columns: Int = 8) -> String {
        var lines = ["| " + (0..<columns).map { "Header \($0)" }.joined(separator: " | ") + " |",
                     "|" + String(repeating: "---|", count: columns)]
        for r in 0..<rows {
            lines.append("| " + (0..<columns).map { c in c % 3 == 0 ? "**row \(r)** cell \(c)" : c % 3 == 1 ? "some `code` and text \(r)\\|\(c)" : "plain words in the cell \(r) \(c) ü" }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    func testAKeystrokeInA50By8TableIsCheap() throws {
        let s = bigTable()
        XCTAssertEqual(shape(s).rows, 52)
        XCTAssertEqual(shape(s).columns, 8)
        XCTAssertGreaterThan(utf16Count(s), 10_000)
        let mid = E.sourceOffset(in: s, of: P(row: 30, column: 4, offset: 6)) ?? 0
        let iterations = 200
        var sink = 0
        func perCall(_ body: () -> Void) -> Double {
            body()  // warm up
            return threadCPUSeconds { for _ in 0..<iterations { body() } } / Double(iterations)
        }
        let type = perCall { sink &+= E.type("x", over: NSRange(location: mid, length: 0), in: s)?.caret ?? 0 }
        let delete = perCall { sink &+= E.delete(.backward, over: NSRange(location: mid, length: 0), in: s)?.caret ?? 0 }
        let key = perCall { if case .caret(let o) = E.move(.down, from: mid, in: s) { sink &+= o } }
        let tab = perCall { if case .caret(let o) = E.move(.tab, from: mid, in: s) { sink &+= o } }
        let place = perCall { sink &+= E.place(in: s, at: mid)?.offset ?? 0 }
        let marks = perCall { sink &+= E.marks(for: [E.Change(kind: .inserted, range: NSRange(location: mid, length: 40))], in: s).count }
        let row = perCall { sink &+= E.apply(.insertRow(above: true), row: 30, column: 2, in: s)?.caret ?? 0 }
        let column = perCall { sink &+= E.apply(.insertColumn(left: true), row: 30, column: 2, in: s)?.caret ?? 0 }
        let copy = perCall { sink &+= E.copyText(of: NSRange(location: 40, length: utf16Count(s) - 80), in: s)?.utf16.count ?? 0 }
        XCTAssertGreaterThan(sink, 0)
        let ms = { (x: Double) in String(format: "%.3f", x * 1000) }
        print("TABLE-EDIT-TIMING 50x8 (\(utf16Count(s)) units) per call, CPU ms: type=\(ms(type)) delete=\(ms(delete)) key=\(ms(key)) tab=\(ms(tab)) place=\(ms(place)) marks=\(ms(marks)) insertRow=\(ms(row)) insertColumn=\(ms(column)) copy=\(ms(copy))")
        // The suite is a Debug build, which runs this about 50x slower than the app does (a
        // keystroke is ~30us optimized). The bounds are for the unoptimized build: five times
        // what it measures, far from a frame (16ms), and still under what a per-keystroke
        // re-parse of every row would cost.
        for (name, t) in [("type", type), ("delete", delete), ("key", key), ("tab", tab), ("place", place), ("marks", marks)] {
            XCTAssertLessThan(t, 0.008, "\(name) used \(ms(t))ms of CPU")
        }
        for (name, t) in [("insertRow", row), ("insertColumn", column), ("copy", copy)] {
            XCTAssertLessThan(t, 0.02, "\(name) used \(ms(t))ms of CPU")
        }
    }

    func testCostGrowsLinearlyWithTheTable() {
        let small = bigTable(rows: 50), large = bigTable(rows: 400)
        func cost(_ s: String) -> Double {
            let mid = E.sourceOffset(in: s, of: P(row: 30, column: 4, offset: 6)) ?? 0
            _ = E.type("x", over: NSRange(location: mid, length: 0), in: s)
            return threadCPUSeconds { for _ in 0..<50 { _ = E.type("x", over: NSRange(location: mid, length: 0), in: s) } }
        }
        let a = cost(small), b = cost(large)
        // 8x the rows may cost about 8x; 40x would be quadratic.
        XCTAssertLessThan(b, max(a, 0.0005) * 24, "8x the rows cost \(b / max(a, 1e-9))x")
    }
}

private extension PlanTableEditing.Move {
    var isCaret: Bool { if case .caret = self { return true } else { return false } }
}
