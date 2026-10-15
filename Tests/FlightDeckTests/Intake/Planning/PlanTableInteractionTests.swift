import AppKit
import XCTest
@testable import FlightDeck

/// Editing a table in the editor: the caret and selection in the cells, text input, the keys, the
/// mouse, the menu, copy and VoiceOver — the editor's side of `PlanTableEditing`.
@MainActor
final class PlanTableInteractionTests: XCTestCase {
    private typealias Fixture = PlanTableEditorTests.Fixture

    private func editor(_ text: String = PlanTableEditorTests.plan, width: CGFloat = 800) -> Fixture {
        PlanTableEditorTests.editor(text, width: width)
    }

    private func offset(_ f: Fixture, _ needle: String, after: Bool = false) -> Int {
        let r = (f.view.string as NSString).range(of: needle)
        precondition(r.location != NSNotFound, needle)
        return after ? NSMaxRange(r) : r.location
    }

    private func caret(_ f: Fixture, _ at: Int) { f.view.setSelectedRange(NSRange(location: at, length: 0)) }

    /// The line the caret is on, whole.
    private func line(_ f: Fixture) -> String {
        let ns = f.view.string as NSString
        return ns.substring(with: ns.lineRange(for: NSRange(location: f.view.selectedRange().location, length: 0))).trimmingCharacters(in: .newlines)
    }

    // MARK: Caret and selection in the cells

    func testTheCaretDrawsInsideItsCellAtTheRightPlace() throws {
        let f = editor()
        defer { f.window.close() }
        let word = offset(f, "Stored per tenant")
        caret(f, word + 3)
        let table = try XCTUnwrap(f.view.tables.place(at: word))
        let mid = try XCTUnwrap(f.view.caretRect(at: word + 3))
        let start = try XCTUnwrap(f.view.caretRect(at: word))
        let band = try XCTUnwrap(f.view.tables.bandOrigin(lineStart: table.lineStart))
        let layout = table.layout
        XCTAssertGreaterThan(mid.minX, start.minX + 5, "mid-word is right of the word's start")
        XCTAssertGreaterThanOrEqual(start.minX, band.x + layout.columnX[1] + layout.padding.width - 1)
        XCTAssertLessThan(mid.minX, band.x + layout.columnX[2], "inside the second column")
        XCTAssertEqual(mid.minY, start.minY, accuracy: 0.5)
        XCTAssertLessThan(mid.height, 30, "the text's height, not the row's")
        XCTAssertEqual(f.view.insertionPointColor, .clear, "AppKit's caret, at the hidden text, is not seen")
    }

    func testAClickPlacesTheCaretWhereTheCaretIsDrawn() throws {
        let f = editor()
        defer { f.window.close() }
        for needle in ["Stored per tenant", "Never shared", "Users"] {
            let word = offset(f, needle)
            for delta in [0, 4] {
                caret(f, word + delta)
                let rect = try XCTUnwrap(f.view.caretRect(at: word + delta))
                let hit = try XCTUnwrap(f.view.tableCaret(at: NSPoint(x: rect.minX + 0.5, y: rect.midY)))
                XCTAssertEqual(hit, word + delta, "\(needle) +\(delta)")
            }
        }
    }

    func testASelectionInsideOneCellIsTextAndAcrossCellsIsCells() throws {
        let f = editor()
        defer { f.window.close() }
        let word = offset(f, "Stored per tenant")
        f.view.setSelectedRange(NSRange(location: word, length: 6))
        var table = try XCTUnwrap(f.view.tables.place(at: word))
        let text = f.view.tables.selectionFills(f.view.selectedRange(), in: table)
        XCTAssertEqual(text.count, 1)
        XCTAssertLessThan(text[0].width, table.layout.columns[1], "the selected word, not the cell")

        f.view.setSelectedRange(NSRange(location: word + 3, length: offset(f, "Never shared") + 3 - word - 3))
        table = try XCTUnwrap(f.view.tables.place(at: word))
        let cells = f.view.tables.selectionFills(f.view.selectedRange(), in: table)
        XCTAssertEqual(cells.count, 2, "the second and third cells of the row, whole")
        XCTAssertEqual(cells[0].width, table.layout.columns[1], accuracy: 0.5)
    }

    func testASelectionFromOutsideThroughTheTableIsCellsToo() throws {
        let f = editor()
        defer { f.window.close() }
        f.view.setSelectedRange(NSRange(location: 3, length: offset(f, "Never shared") - 3))
        let table = try XCTUnwrap(f.view.tables.place(at: offset(f, "| Area")))
        XCTAssertNil(f.view.tables.place(at: f.view.selectedRange().location))
        // The selection starts above the table; its end is in a cell.
        let end = try XCTUnwrap(f.view.tables.place(at: NSMaxRange(f.view.selectedRange())))
        XCTAssertEqual(end.start, table.start)
        XCTAssertTrue(f.isGrid(at: table.start))
    }

    // MARK: Typing

    func testTypingInACellEditsThatCellsSourceAndKeepsTheGrid() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Stored per tenant", after: true))
        f.view.insertText(" now", replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.view.string.contains("| Data | Stored per tenant now | Never shared |"))
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
    }

    func testAPipeTypedInACellIsEscaped() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Never shared", after: true))
        f.view.insertText("|", replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.view.string.contains("| Never shared\\| |"), f.view.string)
        let row = (f.view.string as NSString).range(of: "| Data")
        XCTAssertEqual(PlanTable.parse(Array(((f.view.string as NSString).substring(with: NSRange(location: f.tableRange.location, length: NSMaxRange((f.view.string as NSString).lineRange(for: row)) - f.tableRange.location - 1))).utf16))?.rows.last?.cells.count, 3)
    }

    func testPasteIntoACellFlattensNewlinesAndEscapesPipes() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Never shared", after: true))
        f.view.insertText("a\nb | c", replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.view.string.contains("| Never shareda b \\| c |"), f.view.string)
    }

    func testDeleteAtTheEdgeOfACellDoesNothingAndNeverRemovesAPipe() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Never shared"))
        f.view.deleteBackward(nil)
        XCTAssertEqual(f.view.string, PlanTableEditorTests.plan)
        caret(f, offset(f, "Never shared", after: true))
        f.view.deleteForward(nil)
        XCTAssertEqual(f.view.string, PlanTableEditorTests.plan)
        f.view.deleteBackward(nil)
        XCTAssertTrue(f.view.string.contains("| Never share |"))
    }

    func testDeletingASelectionAcrossCellsClearsThemAndKeepsThePipes() throws {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        let from = offset(f, "Stored per tenant") + 2
        f.view.setSelectedRange(NSRange(location: from, length: offset(f, "Never shared") + 3 - from))
        f.view.deleteBackward(nil)
        let row = try XCTUnwrap(f.view.string.components(separatedBy: "\n").first { $0.hasPrefix("| Data") })
        XCTAssertEqual(row.filter { $0 == "|" }.count, 4, "still three cells: \(row)")
        XCTAssertFalse(row.contains("Stored"))
        XCTAssertFalse(row.contains("Never"))
    }

    func testUndoTakesBackACellEditInOneStep() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Stored per tenant", after: true))
        f.view.insertText("x", replacementRange: f.view.selectedRange())
        f.view.insertText("y", replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.view.string.contains("tenantxy |"))
        f.coordinator.undo.undo()
        XCTAssertEqual(f.view.string, PlanTableEditorTests.plan)
        f.coordinator.undo.redo()
        XCTAssertTrue(f.view.string.contains("tenantxy |"))
    }

    func testTypingInACellLaysOutOnlyThatTable() {
        let tables = (0..<6).map { "| k\($0) | v |\n|---|---|\n| row | value \($0) |" }.joined(separator: "\n\ntext\n\n")
        let f = editor(tables)
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "value 3", after: true))
        let built = PlanTableLayout.built
        f.view.insertText("a", replacementRange: f.view.selectedRange())
        XCTAssertEqual(PlanTableLayout.built, built + 1)
        f.view.insertText("b", replacementRange: f.view.selectedRange())
        XCTAssertEqual(PlanTableLayout.built, built + 2, "one table per keystroke, the other five untouched")
    }

    // MARK: Keys

    func testLeftAndRightStepThroughACellAndCrossIntoTheNeighbours() {
        let f = editor()
        defer { f.window.close() }
        let end = offset(f, "Stored per tenant", after: true)
        caret(f, end - 1)
        f.view.moveRight(nil)
        XCTAssertEqual(f.view.selectedRange().location, end)
        f.view.moveRight(nil)
        XCTAssertEqual(f.view.selectedRange().location, offset(f, "Never shared"), "the start of the next cell, over the pipe")
        f.view.moveLeft(nil)
        XCTAssertEqual(f.view.selectedRange().location, end, "back to the end of the previous one")
    }

    func testUpAndDownKeepTheColumn() {
        let f = editor()
        defer { f.window.close() }
        caret(f, offset(f, "Never shared") + 2)
        f.view.moveUp(nil)
        let ns = f.view.string as NSString
        XCTAssertTrue(line(f).hasPrefix("| Users"), line(f))
        let column = ns.range(of: "Acceptance boundary")
        XCTAssertGreaterThanOrEqual(f.view.selectedRange().location, ns.range(of: "Tenant membership").location - 2)
        XCTAssertLessThan(f.view.selectedRange().location, ns.range(of: "or agent.").location + 20)
        _ = column
        f.view.moveDown(nil)
        XCTAssertTrue(line(f).hasPrefix("| Data"))
    }

    func testUpFromTheHeaderAndDownFromTheLastRowLeaveTheTable() {
        let f = editor()
        defer { f.window.close() }
        caret(f, offset(f, "Area") + 1)
        f.view.moveUp(nil)
        XCTAssertNil(f.view.tables.place(at: f.view.selectedRange().location))
        XCTAssertLessThan(f.view.selectedRange().location, offset(f, "| Area"))
        caret(f, offset(f, "Never shared") + 1)
        f.view.moveDown(nil)
        XCTAssertNil(f.view.tables.place(at: f.view.selectedRange().location))
        XCTAssertGreaterThan(f.view.selectedRange().location, offset(f, "Never shared"))
    }

    func testTabGoesToTheNextCellAndShiftTabBack() {
        let f = editor()
        defer { f.window.close() }
        caret(f, offset(f, "Stored per tenant") + 1)
        f.view.insertTab(nil)
        XCTAssertTrue(line(f).hasPrefix("| Data"))
        XCTAssertEqual(f.view.selectedRange().location, offset(f, "Never shared", after: true))
        f.view.insertBacktab(nil)
        XCTAssertEqual(f.view.selectedRange().location, offset(f, "Stored per tenant", after: true))
    }

    func testTabInTheLastCellAddsARow() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Never shared", after: true))
        f.view.insertTab(nil)
        let rows = f.view.string.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
        XCTAssertEqual(rows.count, 5, "header, delimiter and two rows, plus the new one")
        XCTAssertTrue(rows.last?.hasPrefix("|") ?? false)
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
        f.coordinator.undo.undo()
        XCTAssertEqual(f.view.string, PlanTableEditorTests.plan, "undone in one step")
    }

    func testReturnMovesToTheNextRowAndAddsOneAtTheEnd() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Users") + 2)
        f.view.insertNewline(nil)
        XCTAssertTrue(line(f).hasPrefix("| Data"), line(f))
        f.view.insertNewline(nil)
        XCTAssertEqual(f.view.string.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count, 5)
    }

    func testTheKeysOutsideATableAreAppKitsOwn() {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        caret(f, offset(f, "Intro") + 3)
        f.view.moveRight(nil)
        XCTAssertEqual(f.view.selectedRange().location, offset(f, "Intro") + 4)
        f.view.insertTab(nil)
        XCTAssertTrue(f.view.string.contains("\t"))
    }

    // MARK: Structure

    func testTheMenuOpsEditTheSourceAndUndo() throws {
        let f = editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        let cell = offset(f, "Stored per tenant") + 1
        f.view.tables.perform(.insertRow(above: false), row: 3, column: 1, at: cell, actionName: "Insert Row Below")
        XCTAssertEqual(f.view.string.components(separatedBy: "\n").filter { $0.hasPrefix("|") }.count, 5)
        f.coordinator.undo.undo()
        XCTAssertEqual(f.view.string, PlanTableEditorTests.plan)
        f.view.tables.perform(.insertColumn(left: false), row: 3, column: 1, at: cell, actionName: "Insert Column Right")
        XCTAssertTrue(f.view.string.contains("|---|---|---|---|"), f.view.string)
        f.coordinator.undo.undo()
        f.view.tables.perform(.deleteColumn, row: 3, column: 1, at: cell, actionName: "Delete Column")
        XCTAssertTrue(f.view.string.contains("|---|---|"))
        f.coordinator.undo.undo()
        f.view.tables.perform(.deleteRow, row: 3, column: 1, at: cell, actionName: "Delete Row")
        XCTAssertFalse(f.view.string.contains("| Data"))
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
    }

    func testACellsMenuOffersTheSixOpsAndOnlyThose() throws {
        let f = editor()
        defer { f.window.close() }
        let word = offset(f, "Stored per tenant")
        let rect = try XCTUnwrap(f.view.caretRect(at: word + 2))
        let menu = NSMenu()
        f.view.tables.addStructureItems(to: menu, at: try XCTUnwrap(f.view.tables.hit(at: NSPoint(x: rect.minX, y: rect.midY))))
        XCTAssertEqual(menu.items.compactMap { $0.isSeparatorItem ? nil : $0.title },
                       ["Insert Row Above", "Insert Row Below", "Insert Column Left", "Insert Column Right", "Delete Row", "Delete Column"])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
        let header = NSMenu()
        let area = try XCTUnwrap(f.view.caretRect(at: offset(f, "Area") + 1))
        f.view.tables.addStructureItems(to: header, at: try XCTUnwrap(f.view.tables.hit(at: NSPoint(x: area.minX, y: area.midY))))
        let byTitle = Dictionary(uniqueKeysWithValues: header.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) })
        XCTAssertEqual(byTitle["Insert Row Above"], false, "nothing goes above the header")
        XCTAssertEqual(byTitle["Delete Row"], false, "the header stays")
        XCTAssertEqual(byTitle["Insert Row Below"], true)
    }

    // MARK: Copy, find, VoiceOver

    func testCopyGivesMarkdownRowsOrACellsText() {
        let f = editor()
        defer { f.window.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("plan-table-copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let word = offset(f, "Stored per tenant")
        f.view.setSelectedRange(NSRange(location: word, length: 6))
        XCTAssertTrue(f.view.writeSelection(to: pasteboard, types: f.view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "Stored")
        f.view.setSelectedRange(NSRange(location: word, length: offset(f, "Never shared") - word))
        XCTAssertTrue(f.view.writeSelection(to: pasteboard, types: f.view.writablePasteboardTypes))
        let rows = pasteboard.string(forType: .string)?.components(separatedBy: "\n") ?? []
        XCTAssertEqual(rows.first, "| Area | First-release decision | Acceptance boundary |", "a table starts at its header")
        XCTAssertEqual(rows.last, "| Data | Stored per tenant | Never shared |")
        XCTAssertEqual(rows.count, 3)
    }

    func testFindHighlightsTheMatchInItsCellAndScrollsToIt() throws {
        let f = editor()
        defer { f.window.close() }
        let match = (f.view.string as NSString).range(of: "Never shared")
        f.view.setSelectedRange(match)
        let table = try XCTUnwrap(f.view.tables.place(at: match.location))
        let fills = f.view.tables.selectionFills(match, in: table)
        XCTAssertEqual(fills.count, 1)
        let rect = try XCTUnwrap(f.view.caretRect(at: match.location))
        XCTAssertTrue(fills[0].insetBy(dx: -3, dy: -3).contains(rect.origin), "scrolled to the cell, not the row's hidden text")
        f.view.scrollRangeToVisible(match)
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
    }

    func testVoiceOverReadsTheTableAsRowsOfCells() throws {
        let f = editor()
        defer { f.window.close() }
        let table = try XCTUnwrap(f.view.tables.accessibilityTables().first)
        XCTAssertEqual(table.accessibilityRole(), .table)
        let rows = try XCTUnwrap(table.accessibilityRows()) as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(rows.count, 3, "header and two body rows; the delimiter row is not read")
        let cells = (rows[2].accessibilityChildren() as? [NSAccessibilityElement]) ?? []
        XCTAssertEqual(cells.map { $0.accessibilityLabel() }, ["Data", "Stored per tenant", "Never shared"])
        XCTAssertEqual(cells.map { $0.accessibilityRole() }, [NSAccessibility.Role.cell, .cell, .cell])
        XCTAssertEqual((table.accessibilityColumnHeaderUIElements() as? [NSAccessibilityElement])?.map { $0.accessibilityLabel() },
                       ["Area", "First-release decision", "Acceptance boundary"])
        XCTAssertTrue((f.view.accessibilityChildren() ?? []).contains { ($0 as? NSAccessibilityElement)?.accessibilityRole() == .table })
    }

    func testTheCaretNeverRestsInTheDelimiterRow() {
        let f = editor()
        defer { f.window.close() }
        caret(f, offset(f, "|---|---|---|") + 2)
        XCTAssertFalse(line(f).hasPrefix("|---"), "moved out of the hidden row")
    }
}
