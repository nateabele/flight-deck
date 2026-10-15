import AppKit
import XCTest
@testable import FlightDeck

/// The edit layer's changes inside a pipe table's grid: words removed from a cell (struck through
/// where they were, the cell and its row growing to fit them), rows removed (ghost rows in
/// place), and the table drawing as a grid in every state — never its source, so a ghost has
/// somewhere to go.
@MainActor
final class PlanTableMarksTests: XCTestCase {
    static let source = """
    | Area | Decision |
    |---|---|
    | Users | Any eligible employee can create an agent |
    | Data | Stored per tenant |
    """

    private func layout(_ marks: PlanTableMarks = .none, available: CGFloat = 520) throws -> PlanTableLayout {
        let u = Array(Self.source.utf16)
        return PlanTableLayout.make(try XCTUnwrap(PlanTable.parse(u)), u, theme: .standard, available: available, marks: marks)
    }

    // MARK: Words removed inside a cell

    func testRemovedWordsAreStruckThroughInTheirCellAtTheirPlace() throws {
        let plain = try layout()
        let marked = try layout(PlanTableMarks(inline: [.init(row: 2, column: 1, offset: 4, text: "really ")]))
        let cell = marked.rows[2].cells[1]
        XCTAssertEqual(cell.text.string, "Any really eligible employee can create an agent")
        XCTAssertEqual(cell.ghost.filter { $0 }.count, 7)
        XCTAssertEqual(cell.ghost.count, cell.text.length)
        XCTAssertEqual(cell.map.count, cell.text.length, "every display character maps back to a place in the source")
        // The real characters are untouched, and map where they did.
        let real = cell.ghost.indices.filter { !cell.ghost[$0] }
        XCTAssertEqual(real.map { cell.map[$0] }, plain.rows[2].cells[1].map)
        let struck = try XCTUnwrap(cell.text.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) as? Int)
        XCTAssertEqual(struck, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(cell.text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(cell.text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor,
                       EditLayer.deletedColor.withAlphaComponent(0.8), "the same red as a paragraph's removed words")
        XCTAssertEqual(marked.rows[2].cells[0].text.string, "Users", "other cells are as they were")
    }

    func testAGhostGrowsItsCellAndItsRow() throws {
        let words = "a whole sentence that used to be said here and is not any more, at some length"
        let plain = try layout(available: 300)
        let marked = try layout(PlanTableMarks(inline: [.init(row: 2, column: 1, offset: 0, text: words)]), available: 300)
        XCTAssertGreaterThan(marked.rows[2].height, plain.rows[2].height, "the row grows to fit the ghost")
        XCTAssertEqual(marked.rows[3].top, plain.rows[3].top + (marked.rows[2].height - plain.rows[2].height), accuracy: 0.001)
        XCTAssertEqual(marked.height - plain.height, marked.rows[2].height - plain.rows[2].height, accuracy: 0.001)
        XCTAssertEqual(marked.rows[0].height, plain.rows[0].height, "rows without a ghost are as tall as they were")
    }

    func testAGhostInAnEmptiedCellAndAtTheEndOfACell() throws {
        let u = Array("| a | b |\n|---|---|\n| x |  |".utf16)
        let table = try XCTUnwrap(PlanTable.parse(u))
        let marked = PlanTableLayout.make(table, u, theme: .standard, available: 400, marks: PlanTableMarks(inline: [
            .init(row: 2, column: 1, offset: 0, text: "gone"), .init(row: 2, column: 0, offset: 1, text: " too"),
        ]))
        XCTAssertEqual(marked.rows[2].cells[1].text.string, "gone")
        XCTAssertEqual(marked.rows[2].cells[0].text.string, "x too")
        XCTAssertEqual(marked.rows[2].cells[0].map.last, marked.rows[2].cells[0].sourceEnd, "a ghost at the end maps to the cell's end")
    }

    // MARK: Rows removed

    func testARemovedRowIsAGridRowInPlaceAndTakesHeight() throws {
        let plain = try layout()
        let line = "| Gone | Used to be a row |"
        let above = try layout(PlanTableMarks(rows: [.init(before: 3, lines: [line])]))
        XCTAssertEqual(above.rows[3].above.count, 1)
        XCTAssertEqual(above.rows[3].above[0].cells.map(\.text.string), ["Gone", "Used to be a row"])
        let ghost = above.rows[3].above[0].height
        XCTAssertGreaterThan(ghost, 0)
        XCTAssertEqual(above.rows[3].height, plain.rows[3].height + ghost, accuracy: 0.001)
        XCTAssertEqual(above.rows[3].bodyTop, ghost, accuracy: 0.001)
        XCTAssertEqual(above.rows[3].bodyHeight, plain.rows[3].height, accuracy: 0.001)
        XCTAssertEqual(above.height, plain.height + ghost, accuracy: 0.001)
        XCTAssertEqual(above.rows[1].height, PlanTableLayout.hiddenHeight, "the delimiter row still takes no room")
        XCTAssertEqual(above.columns, try layout(PlanTableMarks(rows: [.init(before: 3, lines: [line])])).columns)

        let below = try layout(PlanTableMarks(rows: [.init(before: 4, lines: [line, line])]))
        XCTAssertEqual(below.rows[3].below.count, 2, "after the table's last row: below it")
        XCTAssertEqual(below.rows[3].bodyTop, 0)
        XCTAssertEqual(below.height, plain.height + 2 * ghost, accuracy: 0.001)
    }

    func testARemovedRowWithMoreCellsThanTheTableKeepsTheTablesColumns() throws {
        let marked = try layout(PlanTableMarks(rows: [.init(before: 2, lines: ["| a | b | c | d |", "| only |"])]))
        XCTAssertEqual(marked.rows[2].above.map(\.cells.count), [2, 2])
        XCTAssertEqual(marked.rows[2].above[1].cells.map(\.text.string), ["only", ""])
    }

    // MARK: The cache

    func testTheLayoutIsCachedPerMarks() throws {
        let u = Array(Self.source.utf16)
        let table = try XCTUnwrap(PlanTable.parse(u))
        let marks = PlanTableMarks(inline: [.init(row: 3, column: 0, offset: 1, text: "ata")], rows: [.init(before: 2, lines: ["| r | s |"])])
        let before = PlanTableLayout.built
        let first = PlanTableLayout.cached(table, u, theme: .standard, available: 611.5, marks: marks)
        XCTAssertEqual(PlanTableLayout.built, before + 1)
        XCTAssertTrue(PlanTableLayout.cached(table, u, theme: .standard, available: 611.5, marks: marks) === first, "same source, width and marks: a hit")
        let other = PlanTableLayout.cached(table, u, theme: .standard, available: 611.5, marks: PlanTableMarks(rows: marks.rows))
        XCTAssertFalse(other === first)
        XCTAssertEqual(PlanTableLayout.built, before + 2)
        _ = PlanTableLayout.cached(table, u, theme: .standard, available: 611.5)
        XCTAssertEqual(PlanTableLayout.built, before + 3, "no marks is a layout of its own")
    }

    // MARK: Fills

    func testAFillReachesTheRealCharactersOfACellNeverItsGhosts() throws {
        let marked = try layout(PlanTableMarks(inline: [.init(row: 2, column: 1, offset: 4, text: "really ")]))
        let cell = marked.rows[2].cells[1]
        let whole = NSRange(location: 0, length: 1_000)
        let runs = PlanTableLayout.runs(of: cell, in: whole)
        XCTAssertEqual(runs.map(\.length).reduce(0, +), cell.text.length - 7)
        XCTAssertEqual(runs.count, 2, "the ghost splits the cell's words in two runs")
        // Source range of "eligible": one run, after the ghost.
        let eligible = NSRange(location: cell.map[11], length: 8)
        XCTAssertEqual(PlanTableLayout.runs(of: cell, in: eligible), [NSRange(location: 11, length: 8)])
    }

    // MARK: Finding the marks

    private func block(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    func testRemovedRowsAreSlottedByTheLineTheyAreAbove() throws {
        let text = Self.source
        let u = Array(text.utf16)
        let table = try XCTUnwrap(PlanTable.parse(u))
        let ns = text as NSString
        func marks(at: Int, _ ghost: String) -> PlanTableMarks {
            PlanTableMarks.make([EditMark(kind: .deleted, range: NSRange(location: at, length: 0), hunk: 0, ghost: ghost)],
                                block: block(text), source: u, table: table)
        }
        XCTAssertEqual(marks(at: ns.range(of: "| Data").location, "| x | y |").rows, [.init(before: 3, lines: ["| x | y |"])])
        XCTAssertEqual(marks(at: ns.length + 1, "| x | y |\n| z | w |").rows, [.init(before: 4, lines: ["| x | y |", "| z | w |"])], "after the table")
        XCTAssertEqual(marks(at: ns.length, "| x | y |").rows, [.init(before: 4, lines: ["| x | y |"])], "at the end of the plan")
        XCTAssertEqual(marks(at: ns.range(of: "|---").location, "| x | y |").rows, [.init(before: 2, lines: ["| x | y |"])],
                       "the delimiter row is no place: the first body row")
        XCTAssertTrue(marks(at: ns.range(of: "| Data").location, "Some prose").rows.isEmpty, "removed prose is not a row")
    }

    func testWordsRemovedAcrossCellsGoToTheCellsTheyCameFrom() throws {
        Self.withFakePlacement {
            let text = "| Area | Decision |\n|---|---|\n| Users | Anyone |"
            let u = Array(text.utf16)
            let table = PlanTable.parse(u)!
            let at = (text as NSString).range(of: "Users").location
            let edits = [EditMark(kind: .deleted, range: NSRange(location: at, length: 0), hunk: 0, ghost: "Staff | Nobody", inline: true),
                         EditMark(kind: .inserted, range: NSRange(location: at, length: 14), hunk: 0)]
            let marks = PlanTableMarks.make(edits, block: block(text), source: u, table: table)
            XCTAssertEqual(marks.inline.map(\.column), [0, 1])
            XCTAssertEqual(marks.inline.map(\.text), ["Staff", "Nobody"])
            XCTAssertEqual(marks.inline.map(\.row), [2, 2])

            // Fewer pipes in the new text than in the old: it stays one ghost, pipes and all.
            let merged = [EditMark(kind: .deleted, range: NSRange(location: at, length: 0), hunk: 0, ghost: "Staff | Nobody", inline: true),
                          EditMark(kind: .inserted, range: NSRange(location: at, length: 5), hunk: 0)]
            XCTAssertEqual(PlanTableMarks.make(merged, block: block(text), source: u, table: table).inline.map(\.text), ["Staff | Nobody"])
        }
    }

    // MARK: A grid in every state

    /// The edit layer's real marks over the table, through the styler: whatever it marks, every row
    /// is still a grid row of one layout, the stored text is as typed, and the removed words and
    /// rows are in the layout, not in the hidden text.
    func testATableWithMarksIsAlwaysAGrid() throws {
        Self.withFakePlacement {
            let generated = """
            # Plan

            | Area | Decision |
            |---|---|
            | Users | Any eligible employee can create an agent |
            | Old | Removed row |
            | Data | Stored per tenant |

            After.
            """
            let states: [(String, String)] = [
                ("a changed cell", generated.replacingOccurrences(of: "eligible employee", with: "employee")),
                ("a removed row", generated.replacingOccurrences(of: "| Old | Removed row |\n", with: "")),
                ("a removed last row", generated.replacingOccurrences(of: "| Data | Stored per tenant |\n", with: "")),
                ("an inserted row", generated.replacingOccurrences(of: "| Data |", with: "| New | Fresh row |\n| Data |")),
                ("a change across cells", generated.replacingOccurrences(of: "| Data | Stored per tenant |", with: "| Records | Kept per tenant |")),
                ("everything", generated.replacingOccurrences(of: "| Old | Removed row |\n", with: "")
                    .replacingOccurrences(of: "eligible employee", with: "employee")
                    .replacingOccurrences(of: "| Data |", with: "| New | Fresh row |\n| Data |")),
            ]
            for (name, edited) in states {
                let marks = EditLayer.marks(generated: generated, edited: edited).marks
                XCTAssertFalse(marks.isEmpty, name)
                let storage = NSTextStorage(string: edited)
                MarkdownStyler.apply(to: storage, blocks: MarkdownStyler.blocks(edited), revealBlock: nil, edits: marks, theme: .standard)
                EditLayer.apply(marks, to: storage, within: nil, theme: .standard)
                XCTAssertEqual(storage.string, edited, name)
                let ns = edited as NSString
                var layouts: [PlanTableLayout] = []
                var at = ns.range(of: "| Area").location
                for row in 0..<(ns.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count) {
                    let ref = storage.attribute(.planTableRow, at: at, effectiveRange: nil) as? PlanTableRowRef
                    XCTAssertNotNil(ref, "\(name): row \(row) is a grid row")
                    if let ref { layouts.append(ref.layout) }
                    XCTAssertNil(storage.attribute(.planEditGhosts, at: at, effectiveRange: nil), "\(name): no ghost left in the hidden text")
                    let para = storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                    XCTAssertEqual(para?.minimumLineHeight, ref?.layout.rows[row].height, "\(name): row \(row) is held to its band")
                    at = NSMaxRange(ns.lineRange(for: NSRange(location: at, length: 0)))
                }
                XCTAssertTrue(layouts.allSatisfy { $0 === layouts[0] }, name)
                let ghosts = layouts[0].rows.reduce(0) { $0 + $1.above.count + $1.below.count + $1.cells.filter(\.hasGhost).count }
                XCTAssertEqual(ghosts > 0, name != "an inserted row", "\(name): removed words and rows are in the grid")
                // The next paragraph's own spacing is untouched by a table's ghost below it.
                let after = storage.attribute(.paragraphStyle, at: ns.range(of: "After.").location, effectiveRange: nil) as? NSParagraphStyle
                XCTAssertEqual(after?.paragraphSpacingBefore, PlanTheme.standard.paragraphStyle(for: .paragraph).paragraphSpacingBefore, name)
            }
        }
    }

    /// The removed row sits at the start of the line after the table, which belongs to another block:
    /// the table is restyled to take it when the layer lands, and again when it goes.
    func testARemovedLastRowComesAndGoesWithTheLayer() throws {
        let plan = PlanTableEditorTests.plan
        let generated = plan.replacingOccurrences(of: "| Data | Stored per tenant | Never shared |\n", with: "| Data | Stored per tenant | Never shared |\n| Extra | x | y |\n")
        let f = PlanTableEditorTests.editor(plan)
        defer { f.window.close() }
        let data = (f.view.string as NSString).range(of: "| Data").location
        func ref() throws -> PlanTableRowRef { try XCTUnwrap(f.storage.attribute(.planTableRow, at: data, effectiveRange: nil) as? PlanTableRowRef) }
        XCTAssertEqual(try ref().layout.rows[3].below.count, 0)
        f.coordinator.layEditLayer(over: generated)
        f.settle()
        XCTAssertEqual(try ref().layout.rows[3].below.count, 1, "the table below which a row was removed shows it")
        XCTAssertEqual(try ref().layout.rows[3].below[0].cells.map(\.text.string), ["Extra", "x", "y"])
        let heading = (f.view.string as NSString).range(of: "## Next section").location
        XCTAssertNil(f.storage.attribute(.planEditGhosts, at: heading, effectiveRange: nil), "and the next line draws nothing of it")
        f.coordinator.layEditLayer(over: plan)
        f.settle()
        XCTAssertEqual(try ref().layout.rows[3].below.count, 0)
        XCTAssertEqual(f.view.string, plan)
    }

    func testRemovedWordsOutsideAGridKeepTheirOldPlace() {
        // A paragraph's ghost is still kern in the line: the grid takes only a grid row's.
        let generated = "A job stays Unassigned for 24 hours.\n", edited = "A job stays Unassigned.\n"
        let storage = NSTextStorage(string: edited)
        MarkdownStyler.apply(to: storage, blocks: MarkdownStyler.blocks(edited), revealBlock: nil, theme: .standard)
        EditLayer.apply(EditLayer.marks(generated: generated, edited: edited).marks, to: storage, within: nil, theme: .standard)
        var ghosts = 0
        storage.enumerateAttribute(.planEditGhosts, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { ghosts += 1 } }
        XCTAssertEqual(ghosts, 1)
    }

    // MARK: Placement until the model's own lands

    /// A minimal stand-in for `PlanTableEditing.marks`: the cell whose pipes the offset is between,
    /// the characters of that cell ahead of it (plain text only, so shown and source offsets agree).
    static func withFakePlacement(_ body: () throws -> Void) rethrows {
        let real = PlanTableMarks.place
        PlanTableMarks.place = { changes, source in
            let u = Array(source.utf16)
            guard let table = PlanTable.parse(u) else { return [] }
            return changes.compactMap { change in
                guard let row = table.rows.indices.first(where: { $0 != PlanTable.delimiterRow && NSLocationInRange(change.range.location, NSRange(location: table.rows[$0].line.location, length: table.rows[$0].line.length + 1)) })
                else { return nil }
                let cells = table.rows[row].cells
                let line = table.rows[row].line
                let pipes = (line.location..<min(change.range.location, NSMaxRange(line))).filter { u[$0] == 124 && ($0 == 0 || u[$0 - 1] != 92) }.count
                let column = min(max(pipes - 1, 0), cells.count - 1)
                let cell = cells[column]
                let shown = min(max(change.range.location - cell.range.location, 0), cell.range.length)
                return PlanTableEditing.CellMark(kind: change.kind, row: row, column: column, textRange: NSRange(location: shown, length: 0),
                                                 ghost: change.ghost)
            }
        }
        defer { PlanTableMarks.place = real }
        try body()
    }
}
