import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// Pipe tables in the plan editor: parsing, the column widths, and the grid drawn over the
/// untouched source — which shows as source, byte for byte, while the caret is in it.
final class PlanTableParseTests: XCTestCase {
    private func parse(_ source: String) -> PlanTable? { PlanTable.parse(Array(source.utf16)) }

    private func text(_ source: String, _ range: NSRange) -> String { (source as NSString).substring(with: range) }

    func testAlignmentComesFromTheDelimiterRow() throws {
        let source = "| a | b | c | d |\n|:---|:---:|---:|---|\n| 1 | 2 | 3 | 4 |"
        let table = try XCTUnwrap(parse(source))
        XCTAssertEqual(table.alignments, [.left, .center, .right, .left])
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.rows[2].cells.map { text(source, $0.range) }, ["1", "2", "3", "4"])
    }

    func testEscapedPipesStayInTheirCell() throws {
        let source = "| a | b |\n|---|---|\n| x \\| y | `p\\|q` |"
        let table = try XCTUnwrap(parse(source))
        XCTAssertEqual(table.rows[2].cells.map { text(source, $0.range) }, ["x \\| y", "`p\\|q`"])
        let layout = PlanTableLayout.make(table, Array(source.utf16), theme: .standard, available: 600)
        XCTAssertEqual(layout.rows[2].cells[0].text.string, "x | y", "the backslash of an escaped pipe is not shown")
        XCTAssertEqual(layout.rows[2].cells[1].text.string, "p|q")
    }

    func testRaggedRowsAreFilledAndKept() throws {
        let source = "| a | b |\n|---|---|\n| only |\n| 1 | 2 | 3 |\n| no pipe at the end | x"
        let table = try XCTUnwrap(parse(source))
        XCTAssertEqual(table.columnCount, 3, "the widest row sets the columns, so no text is dropped from the grid")
        XCTAssertEqual(table.rows.map(\.cells.count), [2, 2, 1, 3, 2])
        let layout = PlanTableLayout.make(table, Array(source.utf16), theme: .standard, available: 600)
        XCTAssertEqual(layout.columns.count, 3)
        XCTAssertEqual(layout.rows[2].cells.count, 3, "a short row is padded with empty cells")
        XCTAssertEqual(layout.rows[4].cells[0].text.string, "no pipe at the end")
        XCTAssertEqual(layout.rows[4].cells[1].text.string, "x")
    }

    func testInlineMarkdownInCellsIsStyledAndItsDelimitersDropped() throws {
        let source = "| **Bold** | *it* and `code` | [site](https://x.y/z) |\n|---|---|---|\n| a | b | c |"
        let table = try XCTUnwrap(parse(source))
        let layout = PlanTableLayout.make(table, Array(source.utf16), theme: .standard, available: 800)
        let cells = layout.rows[0].cells.map(\.text)
        XCTAssertEqual(cells.map(\.string), ["Bold", "it and code", "site"])
        let bold = try XCTUnwrap(cells[0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), "the header is semibold, bold on top")
        let italic = try XCTUnwrap(cells[1].attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        let code = try XCTUnwrap(cells[1].attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertNotNil(cells[1].attribute(.backgroundColor, at: 8, effectiveRange: nil))
        XCTAssertEqual(cells[2].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, PlanTheme.standard.link)
        // Where a click lands: display characters map back into the source.
        XCTAssertEqual(layout.rows[0].cells[0].map, [4, 5, 6, 7], "'Bold' sits after '| **'")
    }

    func testTheHeaderIsSemiboldAndTheBodyIsTheBodyFont() throws {
        let source = "| H |\n|---|\n| b |"
        let layout = PlanTableLayout.make(try XCTUnwrap(parse(source)), Array(source.utf16), theme: .standard, available: 600)
        let header = try XCTUnwrap(layout.rows[0].cells[0].text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let body = try XCTUnwrap(layout.rows[2].cells[0].text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(header.pointSize, PlanTheme.standard.body.pointSize)
        XCTAssertFalse(header.isFixedPitch)
        XCTAssertEqual(body, PlanTheme.standard.body, "proportional, the theme's body font")
        XCTAssertLessThan(layout.rows[1].height, 0.1, "the delimiter row takes no room")
        XCTAssertTrue(layout.rows[1].isHidden)
        XCTAssertTrue(layout.rows[0].isHeader)
    }

    func testWithoutADelimiterRowItIsNotATable() {
        XCTAssertNil(parse("| a | b |\n| c | d |"))
        XCTAssertNil(parse("| just one line |"))
        XCTAssertNil(parse("| a | b |\n|--x|---|"))
    }

    func testATableAtTheEndOfTheDocumentAndAdjacentTables() throws {
        let one = "| a | b |\n|---|---|\n| 1 | 2 |"
        let two = "| c |\n|:-:|\n| 3 |"
        let end = "intro\n\n" + one
        let blocks = MarkdownStyler.blocks(end)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .blank, .table])
        XCTAssertEqual(text(end, blocks[2].range), one, "no newline after the last row")
        XCTAssertNotNil(parse(text(end, blocks[2].range)))

        let adjacent = one + "\n\n" + two + "\nafter"
        let kinds = MarkdownStyler.blocks(adjacent).map(\.kind)
        XCTAssertEqual(kinds, [.table, .blank, .table, .paragraph], "a blank line ends a table; the next is its own")
        let tables = MarkdownStyler.blocks(adjacent).filter { $0.kind == .table }.map { text(adjacent, $0.range) }
        XCTAssertEqual(tables, [one, two])
        XCTAssertEqual(try XCTUnwrap(parse(tables[1])).alignments, [.center])
    }

    // MARK: Column widths

    func testColumnsKeepTheirNaturalWidthWhenTheTableFits() {
        XCTAssertEqual(PlanTableLayout.columnWidths(natural: [60, 120, 80], minimum: [40, 50, 40], available: 600), [60, 120, 80],
                       "content width, not stretched to the pane")
    }

    func testLongColumnsShareTheRoomAndShortOnesStayNarrow() {
        // The maintainer's table: a short Area column and two sentence-length ones, in 680 pt.
        let widths = PlanTableLayout.columnWidths(natural: [58, 1500, 700], minimum: [58, 90, 100], available: 680)
        XCTAssertEqual(widths[0], 58, accuracy: 0.01, "the short column keeps its natural width")
        XCTAssertEqual(widths.reduce(0, +), 680, accuracy: 0.5, "the table fills the room")
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.5, "the long columns are capped at one shared level")
        XCTAssertGreaterThan(widths[1], 200)
        // A medium column under the cap keeps its natural width too.
        let mixed = PlanTableLayout.columnWidths(natural: [120, 1500, 1500], minimum: [60, 90, 90], available: 600)
        XCTAssertEqual(mixed[0], 120, accuracy: 0.01)
        XCTAssertEqual(mixed.reduce(0, +), 600, accuracy: 0.5)
    }

    func testNoColumnGoesBelowItsLongestWordUntilNothingFits() {
        let widths = PlanTableLayout.columnWidths(natural: [400, 400], minimum: [150, 50], available: 300)
        XCTAssertGreaterThanOrEqual(widths[0], 150)
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.5)
        let squeezed = PlanTableLayout.columnWidths(natural: [400, 400], minimum: [300, 300], available: 300)
        XCTAssertEqual(squeezed, [150, 150], "when even the words don't fit, all shrink together")
    }

    func testNatesTableWrapsInsideItsCells() throws {
        let source = """
        | Area | First-release decision | Acceptance boundary |
        |---|---|---|
        | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use and can publish their own drafts after automated checks. | Tenant membership alone never grants access to another employee’s app or agent. |
        """
        let table = try XCTUnwrap(parse(source))
        let layout = PlanTableLayout.make(table, Array(source.utf16), theme: .standard, available: 700)
        XCTAssertLessThan(layout.columns[0], 80, "Area stays narrow")
        XCTAssertEqual(layout.width, 700, accuracy: 1, "the table fits the text width")
        let line = PlanTheme.standard.body.pointSize * 1.2 + 2 * PlanTheme.standard.tablePadding.height
        XCTAssertGreaterThan(layout.rows[2].height, 2 * line, "the sentence cells wrap, and the row grows to the tallest")
        XCTAssertLessThan(layout.rows[2].height, 8 * line)
        XCTAssertEqual(layout.rows[2].top, layout.rows[0].height + layout.rows[1].height, accuracy: 0.001)
    }

    func testAClickMapsBackToTheCellsSource() throws {
        let source = "| ab | cd |\n|---|---|\n| hello world | **x** |"
        let table = try XCTUnwrap(parse(source))
        let layout = PlanTableLayout.make(table, Array(source.utf16), theme: .standard, available: 600)
        let row = layout.rows[2]
        let inFirst = CGPoint(x: layout.columnX[0] + layout.padding.width + 1, y: layout.padding.height + 2)
        XCTAssertEqual(layout.sourceOffset(row: 2, at: inFirst), 2, "the start of 'hello world', after '| '")
        let pastWords = CGPoint(x: layout.columnX[1] - 2, y: layout.padding.height + 2)
        XCTAssertEqual(layout.sourceOffset(row: 2, at: pastWords), 13, "the end of the first cell's text")
        let inSecond = CGPoint(x: layout.columnX[1] + 3, y: layout.padding.height + 2)
        XCTAssertEqual(layout.sourceOffset(row: 2, at: inSecond), 18, "'x' of '**x**', not the stars before it")
        XCTAssertNil(layout.sourceOffset(row: 2, at: CGPoint(x: layout.width + 5, y: 5)))
        XCTAssertNil(layout.sourceOffset(row: 1, at: CGPoint(x: 5, y: 0)), "the delimiter row has nothing to click")
        XCTAssertGreaterThan(row.height, 0)
    }
}

/// The styler's two states for a table: grid (source hidden, held to the grid's heights) and
/// source (the caret in it).
final class PlanTableStyleTests: XCTestCase {
    static let plan = "# T\n\n| a | bb |\n|---|---|\n| ccc | d |\n\nafter"

    private func styled(reveal: Int?, width: CGFloat = 600) -> (NSTextStorage, [MarkdownBlock]) {
        let storage = NSTextStorage(string: Self.plan)
        let blocks = MarkdownStyler.blocks(Self.plan)
        var theme = PlanTheme.standard
        theme.contentWidth = width
        MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: reveal, theme: theme)
        return (storage, blocks)
    }

    func testOffTheCaretEveryRowIsHiddenAndHeldToItsHeight() throws {
        let (storage, blocks) = styled(reveal: nil)
        XCTAssertEqual(storage.string, Self.plan, "the stored text is untouched")
        let table = try XCTUnwrap(blocks.first { $0.kind == .table })
        var rows: [PlanTableRowRef] = []
        for line in 0..<3 {
            let start = table.range.location + (["| a | bb |\n", "|---|---|\n", "| ccc | d |"].prefix(line).map(\.utf16.count).reduce(0, +))
            let ref = try XCTUnwrap(storage.attribute(.planTableRow, at: start, effectiveRange: nil) as? PlanTableRowRef)
            rows.append(ref)
            let font = try XCTUnwrap(storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)
            XCTAssertLessThan(font.pointSize, 1, "the source line is hidden")
            let para = try XCTUnwrap(storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(para.minimumLineHeight, ref.layout.rows[line].height, accuracy: 0.001)
            XCTAssertEqual(para.maximumLineHeight, para.minimumLineHeight, accuracy: 0.001)
        }
        XCTAssertTrue(rows.allSatisfy { $0.layout === rows[0].layout }, "one layout for the whole table")
        XCTAssertNil(storage.attribute(.planTableRow, at: 0, effectiveRange: nil), "other blocks are untouched")
    }

    func testWithTheCaretInItItShowsItsSourceInMonospaceWithAlignedColumns() throws {
        let (storage, blocks) = styled(reveal: 2)
        XCTAssertEqual(blocks[2].kind, .table)
        XCTAssertEqual(storage.string, Self.plan)
        let at = blocks[2].range.location
        XCTAssertNil(storage.attribute(.planTableRow, at: at, effectiveRange: nil))
        let font = try XCTUnwrap(storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch, "a table that fits is shown aligned, in monospace")
        XCTAssertNotNil(storage.attribute(.kern, at: at + 3, effectiveRange: nil))
    }

    func testASourceTooWideForTheEditorWrapsAsBodyText() throws {
        let wide = "| " + String(repeating: "word ", count: 40) + "| b |\n|---|---|\n| x | y |"
        let storage = NSTextStorage(string: wide)
        var theme = PlanTheme.standard
        theme.contentWidth = 400
        MarkdownStyler.apply(to: storage, blocks: MarkdownStyler.blocks(wide), revealBlock: 0, theme: theme)
        let font = try XCTUnwrap(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.isFixedPitch)
        XCTAssertNil(storage.attribute(.kern, at: 0, effectiveRange: nil), "no kern padding: that is what scattered a wrapped row")
    }

    func testNotATableIsPlainSource() {
        let text = "| a | b |\n| c | d |"
        let storage = NSTextStorage(string: text)
        MarkdownStyler.apply(to: storage, blocks: MarkdownStyler.blocks(text), revealBlock: nil, theme: .standard)
        XCTAssertNil(storage.attribute(.planTableRow, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, text)
    }

    func testTheLayoutIsBuiltOnceAndReusedUntilTheWidthMoves() {
        let before = PlanTableLayout.built
        _ = styled(reveal: nil, width: 640.25)
        XCTAssertEqual(PlanTableLayout.built, before + 1)
        _ = styled(reveal: nil, width: 640.25)
        _ = styled(reveal: 2, width: 640.25)
        _ = styled(reveal: nil, width: 640.25)
        XCTAssertEqual(PlanTableLayout.built, before + 1, "the same table at the same width is a cache hit")
        _ = styled(reveal: nil, width: 480)
        XCTAssertEqual(PlanTableLayout.built, before + 2)
    }
}

/// The table in the real editor: reveal as the caret enters and leaves, and everything that
/// reads the text or the layout going on working.
@MainActor
final class PlanTableEditorTests: XCTestCase {
    static let plan = """
    # Plan

    Intro paragraph before the table.

    | Area | First-release decision | Acceptance boundary |
    |---|---|---|
    | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use and can publish their own drafts after automated checks. | Tenant membership alone never grants access to another employee’s app or agent. |
    | Data | Stored per tenant | Never shared |

    ## Next section

    Closing paragraph.
    """

    struct Fixture {
        let coordinator: PlanTextView.Coordinator
        let container: PlanEditorContainer
        let window: NSWindow
        var view: PlanNSTextView { container.textView }
        var storage: NSTextStorage { view.textStorage! }

        func settle() {
            let until = Date().addingTimeInterval(3)
            repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while (view.layingOutWholePlan) && Date() < until
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }

        var tableRange: NSRange { (view.string as NSString).range(of: "| Area") }
        func isGrid(at offset: Int) -> Bool { storage.attribute(.planTableRow, at: offset, effectiveRange: nil) != nil }
    }

    static func editor(_ text: String = plan, generated: String? = nil, width: CGFloat = 800, focused: Bool = true,
                       appearance: NSAppearance.Name? = nil) -> Fixture {
        let view = PlanTextView(text: .constant(text), editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {})
            .editLayer(generated: generated)
        let coordinator = view.makeCoordinator()
        let container = PlanEditorContainer(onShow: {})
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance {
            // On the window's own colour, as in the app, for a picture.
            window.appearance = NSAppearance(named: appearance)
            let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
            backdrop.wantsLayer = true
            window.contentView = backdrop
            backdrop.addSubview(container)
            window.appearance?.performAsCurrentDrawingAppearance { backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        } else {
            window.contentView = container
        }
        container.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        container.textView.onContainerWidth = { [weak coordinator] in coordinator?.containerWidthChanged() }
        container.textView.onFocusChange = { [weak coordinator] in coordinator?.focusChanged() }
        container.textView.isFocused = focused
        coordinator.load(text)
        coordinator.layEditLayer(over: generated)
        container.layoutSubtreeIfNeeded()
        let f = Fixture(coordinator: coordinator, container: container, window: window)
        f.settle()
        return f
    }

    func testRevealsOnCaretEntryAndHidesOnExit() {
        let f = Self.editor()
        defer { f.window.close() }
        let table = f.tableRange
        XCTAssertTrue(f.isGrid(at: table.location), "caret at the top: the table is a grid")
        f.view.setSelectedRange(NSRange(location: table.location + 9, length: 0))
        XCTAssertFalse(f.isGrid(at: table.location), "the caret entered: the source shows")
        XCTAssertFalse(f.isGrid(at: (f.view.string as NSString).range(of: "| Data").location), "every row of the table, not just the caret's")
        f.view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(f.isGrid(at: table.location), "the caret left: the grid is back")
        XCTAssertEqual(f.view.string, Self.plan, "the plan is as typed throughout")
    }

    func testAnUnfocusedEditorShowsTheGridWhereverTheCaretWas() {
        let f = Self.editor(focused: false)
        defer { f.window.close() }
        f.view.setSelectedRange(NSRange(location: f.tableRange.location + 9, length: 0))
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
        f.view.isFocused = true
        f.coordinator.focusChanged()
        XCTAssertFalse(f.isGrid(at: f.tableRange.location), "focus reveals the caret's table")
    }

    func testTheGridRowsLayOutAtTheirHeightAndTheNextSectionFollows() throws {
        let f = Self.editor()
        defer { f.window.close() }
        let ns = f.view.string as NSString
        let table = f.tableRange
        let ref = try XCTUnwrap(f.storage.attribute(.planTableRow, at: table.location, effectiveRange: nil) as? PlanTableRowRef)
        let rects = f.view.segmentRects(NSRange(location: table.location, length: NSMaxRange(ns.range(of: "Never shared")) - table.location))
        let span = rects.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(span.height, ref.layout.height, accuracy: 1, "the source lines take the grid's height, whatever their hidden width")
        let heading = try XCTUnwrap(f.view.caretRect(at: ns.range(of: "## Next section").location))
        XCTAssertGreaterThanOrEqual(heading.minY, span.maxY, "the section after the table starts below it")
        XCTAssertLessThan(heading.minY - span.maxY, 60, "the table's own spacing plus the heading's, not a gap of hidden source")
        // Editing the source makes the plan taller: the grid is the shorter of the two.
        let before = f.view.frame.height
        f.view.setSelectedRange(NSRange(location: table.location + 9, length: 0))
        f.settle()
        XCTAssertNotEqual(f.view.frame.height, before)
    }

    func testEachSourceLineIsExactlyItsRowsHeight() throws {
        let f = Self.editor()
        defer { f.window.close() }
        let layoutManager = try XCTUnwrap(f.view.textLayoutManager)
        let content = try XCTUnwrap(layoutManager.textContentManager)
        let ns = f.view.string as NSString
        var at = f.tableRange.location
        let ref = try XCTUnwrap(f.storage.attribute(.planTableRow, at: at, effectiveRange: nil) as? PlanTableRowRef)
        var heights: [String] = []
        for row in 0..<4 {
            let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: at))
            let fragment = try XCTUnwrap(layoutManager.textLayoutFragment(for: location))
            heights.append("\(row): fragment \(fragment.layoutFragmentFrame.height) layout \(ref.layout.rows[row].height) lines \(fragment.textLineFragments.map { $0.typographicBounds.height })")
            XCTAssertEqual(fragment.textLineFragments[0].typographicBounds.height, ref.layout.rows[row].height, accuracy: 0.6, "row \(row)")
            at = NSMaxRange(ns.lineRange(for: NSRange(location: at, length: 0)))
        }
        print("TABLE ROW HEIGHTS", heights.joined(separator: " | "))
    }

    func testCopyGivesTheMarkdownSourceNotTheGrid() {
        let f = Self.editor()
        defer { f.window.close() }
        let table = f.tableRange
        let ns = f.view.string as NSString
        let last = ns.lineRange(for: ns.range(of: "Never shared"))
        let source = ns.substring(with: NSRange(location: table.location, length: last.location + last.length - 1 - table.location))
        // A selection that starts above the table keeps it a grid (the caret block is the selection's start).
        f.view.setSelectedRange(NSRange(location: 3, length: table.location + source.utf16.count - 3))
        XCTAssertTrue(f.isGrid(at: table.location))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("plan-table-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let types = f.view.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        XCTAssertTrue(f.view.writeSelection(to: pasteboard, types: types))
        let copied = types.compactMap { pasteboard.string(forType: $0) }.first ?? ""
        XCTAssertTrue(copied.hasSuffix(source), "the table copies as its pipes and dashes")
        XCTAssertTrue(copied.contains("|---|---|---|"))
    }

    func testASelectionAcrossTheGridIsPaintedByTheGrid() throws {
        let f = Self.editor()
        defer { f.window.close() }
        f.view.setSelectedRange(NSRange(location: 3, length: f.tableRange.location + 40))
        f.settle()
        let layout = try XCTUnwrap(f.view.textLayoutManager)
        XCTAssertTrue(layout.textSelections.contains { $0.textRanges.contains { !$0.isEmpty } })
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
    }

    func testAClickInACellPutsTheCaretInThatCellsText() throws {
        let f = Self.editor()
        defer { f.window.close() }
        let ns = f.view.string as NSString
        let decision = ns.range(of: "Any eligible employee")
        // The first body row: find its band from the hidden line's rect.
        let row = try XCTUnwrap(f.view.segmentRects(ns.lineRange(for: decision)).first)
        let origin = f.view.textContainerOrigin
        let layout = try XCTUnwrap(f.storage.attribute(.planTableRow, at: decision.location, effectiveRange: nil) as? PlanTableRowRef).layout
        let padding = f.view.textContainer?.lineFragmentPadding ?? 0
        let x = origin.x + padding + layout.columnX[1] + layout.padding.width + 2
        let caret = try XCTUnwrap(f.view.tableCaret(at: NSPoint(x: x, y: row.minY + layout.padding.height + 4)))
        XCTAssertEqual(caret, decision.location, "the start of the second column's words")
        let third = origin.x + padding + layout.columnX[2] + layout.padding.width + 2
        let inThird = try XCTUnwrap(f.view.tableCaret(at: NSPoint(x: third, y: row.minY + layout.padding.height + 4)))
        XCTAssertEqual(inThird, ns.range(of: "Tenant membership").location)
        XCTAssertNil(f.view.tableCaret(at: NSPoint(x: origin.x + 60, y: 2)), "not on the table")
        f.view.setSelectedRange(NSRange(location: caret, length: 0))
        XCTAssertFalse(f.isGrid(at: f.tableRange.location), "the caret in the cell shows the table's source")
    }

    func testTypingInTheSourceAndUndoRestoreTheText() {
        let f = Self.editor()
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        let at = (f.view.string as NSString).range(of: "Stored per tenant").location
        f.view.setSelectedRange(NSRange(location: at, length: 0))
        f.view.insertText("Now ", replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.view.string.contains("| Now Stored per tenant |"))
        XCTAssertFalse(f.isGrid(at: f.tableRange.location))
        f.coordinator.undo.undo()
        XCTAssertEqual(f.view.string, Self.plan)
        f.view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(f.isGrid(at: f.tableRange.location))
    }

    func testFindLandsOnTheMatchInTheSource() {
        let f = Self.editor()
        defer { f.window.close() }
        // A find selects the match: a match inside the table is the caret entering it.
        let match = (f.view.string as NSString).range(of: "Never shared")
        f.view.setSelectedRange(match)
        XCTAssertFalse(f.isGrid(at: f.tableRange.location))
        XCTAssertEqual((f.view.string as NSString).substring(with: f.view.selectedRange()), "Never shared")
    }

    func testANoteAnchoredOnTheTableStillResolvesAndHasARect() throws {
        let f = Self.editor()
        defer { f.window.close() }
        let quote = "Stored per tenant"
        let anchor = NoteAnchor(checkpoint: 1, selecting: Self.plan.range(of: quote)!, in: Self.plan)
        let found = try XCTUnwrap(anchor.locate(in: f.view.string))
        XCTAssertEqual((f.view.string as NSString).substring(with: NSRange(found, in: f.view.string)), quote)
        let rects = f.view.segmentRects(NSRange(found, in: f.view.string))
        XCTAssertFalse(rects.isEmpty)
        XCTAssertGreaterThan(rects[0].height, 20, "a note on the row is placed at the row's height")
    }

    func testFoldingTheSectionOverATableHidesItsRowsAndNeverTouchesTheText() {
        let text = "# Doc\n\n## Table section\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n## Other\n\nbody"
        let f = Self.editor(text)
        defer { f.window.close() }
        let key = f.coordinator.headings.first { $0.key.text == "## Table section" }!.key
        f.coordinator.toggleFold(key)
        f.settle()
        XCTAssertEqual(f.view.string, text)
        let hidden = (text as NSString).range(of: "| a | b |")
        XCTAssertTrue(f.coordinator.foldFilter.contains(hidden.location), "the table's rows are in the hidden body")
        f.coordinator.toggleFold(key)
        XCTAssertFalse(f.coordinator.foldFilter.contains(hidden.location))
    }

    func testNarrowingTheEditorLaysTheTablesOutAgainInTheNewWidth() throws {
        let f = Self.editor(width: 900)
        defer { f.window.close() }
        let wide = try XCTUnwrap(f.storage.attribute(.planTableRow, at: f.tableRange.location, effectiveRange: nil) as? PlanTableRowRef).layout
        f.container.frame = NSRect(x: 0, y: 0, width: 480, height: 900)
        f.container.layoutSubtreeIfNeeded()
        f.settle()
        let narrow = try XCTUnwrap(f.storage.attribute(.planTableRow, at: f.tableRange.location, effectiveRange: nil) as? PlanTableRowRef).layout
        XCTAssertLessThan(narrow.width, wide.width)
        let available = f.view.textContainer!.size.width - 2 * f.view.textContainer!.lineFragmentPadding
        XCTAssertLessThanOrEqual(narrow.width, available + 0.5)
        XCTAssertGreaterThan(narrow.height, wide.height, "narrower cells wrap more")
    }

    // MARK: Edit layer

    func testAnInsertedRowStaysAGridAndAChangedCellShowsItsSource() throws {
        let generated = Self.plan.replacingOccurrences(of: "| Data | Stored per tenant | Never shared |\n", with: "")
        let inserted = Self.editor(Self.plan, generated: generated)
        defer { inserted.window.close() }
        let row = (inserted.view.string as NSString).range(of: "| Data")
        XCTAssertTrue(inserted.isGrid(at: inserted.tableRange.location), "an added row is marked by the gutter bar, the grid stays")
        XCTAssertNotNil(inserted.storage.attribute(.planEditInserted, at: row.location, effectiveRange: nil))

        let changed = Self.plan.replacingOccurrences(of: "Never shared", with: "Shared with nobody")
        let f = Self.editor(changed, generated: Self.plan)
        defer { f.window.close() }
        XCTAssertFalse(f.isGrid(at: f.tableRange.location), "a deleted word has nowhere to be drawn in a grid, so the table shows its source")
        XCTAssertTrue(f.coordinator.hunks.count >= 1)
    }

    // MARK: Cost

    func testTypingElsewhereNeverLaysATableAgain() {
        var parts: [String] = []
        for i in 0..<40 {
            parts.append("## S\(i)\n\nProse \(i) here.\n\n| k | v |\n|---|---|\n| row \(i) | value with a long sentence in it to wrap, number \(i) |\n")
        }
        let f = Self.editor(parts.joined(separator: "\n"))
        defer { f.window.close(); f.coordinator.timer?.invalidate() }
        let at = (f.view.string as NSString).range(of: "Prose 20 here.").location
        f.view.setSelectedRange(NSRange(location: at, length: 0))
        let built = PlanTableLayout.built
        for key in ["a", "b", "c", "d", "e"] { f.view.insertText(key, replacementRange: f.view.selectedRange()) }
        XCTAssertEqual(PlanTableLayout.built, built, "a keystroke in prose lays out no table")
    }
}
