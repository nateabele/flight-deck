import FleetKit
import MarkdownUI
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// The reader's table: what a cell shows, and that the grid takes less room than MarkdownUI's did.
/// How it looks is `PlanTableRenderHarness`'s.
@MainActor
final class PlanTableViewTests: XCTestCase {
    private let sample = """
    | Area | First-release decision | Acceptance boundary |
    |---|---|---|
    | Users | Any eligible employee can create an agent or mini-app; each owner controls a specific invite list for use and can publish their own drafts after automated checks. | Tenant membership alone never grants access to another employee’s app or agent. |
    | Data | **Each** tenant's `records` stay in its own store. | A query that names no tenant fails closed. |
    """

    func testOnlyATableIsAGrid() {
        XCTAssertNotNil(PipeTable.parse(sample))
        XCTAssertNil(PipeTable.parse("- one\n- two"))
        XCTAssertNil(PipeTable.parse("> a quote"))
        XCTAssertNil(PipeTable.parse("| just | a line |"), "no delimiter row: not a table, left to MarkdownUI")
    }

    func testCellsDropTheDelimiterRowAndFillShortRows() throws {
        let source = "| a | b | c |\n|---|---|---|\n| 1 |\n| x \\| y | `z` | **w** |"
        let rows = PlanTableView.cells(source, try XCTUnwrap(PipeTable.parse(source)))
        XCTAssertEqual(rows.count, 3, "header and two rows, the dashes never shown")
        XCTAssertEqual(rows.map { $0.map { String($0.characters) } }, [["a", "b", "c"], ["1", "", ""], ["x | y", "z", "w"]])
    }

    func testInlineMarkdownInACellKeepsItsStyling() throws {
        let cell = PlanTableView.attributed("**bold** and `code` and *it*")
        XCTAssertEqual(String(cell.characters), "bold and code and it")
        let intents = cell.runs.map { $0.inlinePresentationIntent }
        XCTAssertTrue(intents.contains { $0?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(intents.contains { $0?.contains(.emphasized) == true })
        let code = try XCTUnwrap(cell.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertNotNil(code.font, "a code span is monospaced")
        XCTAssertNotNil(code.backgroundColor, "and washed, as in the reader's prose")
    }

    func testTheLongestWordKeepsItsStyling() {
        let word = PlanTableView.longestWord(PlanTableView.attributed("a few `fontSize` words"))
        XCTAssertEqual(String(word.characters), "fontSize")
        XCTAssertTrue(word.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertEqual(String(PlanTableView.longestWord(AttributedString("")).characters), "")
        XCTAssertEqual(String(PlanTableView.longestWord(AttributedString("one")).characters), "one")
    }

    /// The grid sizes itself from its rows (the scroll view's own height, not a fixed one):
    /// taller for a taller table, and never a sliver or a page.
    func testTheGridTakesTheHeightOfItsRows() {
        let line = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        let short = height(of: RichBlockView(text: "| a | b |\n|---|---|\n| 1 | 2 |").font(.body), width: 346)
        XCTAssertEqual(short, 24 + 2 * (line + 14), accuracy: 6, "two one-line rows, and the 12 pt around them")
        let tall = height(of: RichBlockView(text: sample).font(.body), width: 346)
        XCTAssertGreaterThan(tall, short + 5 * line, "sentence cells wrap inside their columns")
        XCTAssertLessThan(tall, 40 * line)
    }

    private func height(of view: some View, width: CGFloat) -> CGFloat {
        let controller = UIHostingController(rootView: view.padding(12))
        controller.safeAreaRegions = []
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 4000)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
