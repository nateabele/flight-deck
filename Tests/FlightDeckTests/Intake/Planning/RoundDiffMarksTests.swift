import AppKit
import XCTest
@testable import FlightDeck

/// Diff vs Previous is the plan editor with the PREVIOUS round's plan as the edit layer's base:
/// the same marks as the human's edits, drawn over the round's changes. These pin what the
/// marks say for a round-to-round change, and where a heatmap cell's section jump goes.
final class RoundDiffMarksTests: XCTestCase {
    private let previous = """
    # Plan

    ## 1. Goals

    Ship the editor this week.

    ## 2. Staffing

    | Role | Owner |
    | --- | --- |
    | Lead | Ana |
    | QA | Bo |
    | Docs | Cy |

    ## 3. Risks

    The schedule is tight.
    """

    private var current: String {
        previous
            .replacingOccurrences(of: "Ship the editor this week.", with: "Ship the editor next week.")
            .replacingOccurrences(of: "| Lead | Ana |", with: "| Lead | Dee |")
            .replacingOccurrences(of: "| QA | Bo |\n", with: "")
            .replacingOccurrences(of: "\n## 3. Risks\n\nThe schedule is tight.", with: "")
    }

    func testAChangedWordIsAnInlineInsertionAndAGhost() {
        let marks = EditLayer.marks(generated: previous, edited: current).marks
        let ns = current as NSString
        let word = marks.first { $0.kind == .inserted && ns.substring(with: $0.range).contains("next") }
        XCTAssertNotNil(word, "the new word is tinted")
        XCTAssertTrue(marks.contains { $0.kind == .deleted && $0.inline && $0.ghost.contains("this") }, "the old word is a struck ghost in place")
    }

    func testATableCellChangeAndARemovedRowAreMarked() {
        let marks = EditLayer.marks(generated: previous, edited: current).marks
        let ns = current as NSString
        XCTAssertTrue(marks.contains { $0.kind == .inserted && ns.substring(with: $0.range).contains("Dee") }, "the new cell text is tinted")
        XCTAssertTrue(marks.contains { $0.kind == .deleted && $0.ghost.contains("Ana") }, "the old cell text is a ghost")
        XCTAssertTrue(marks.contains { $0.kind == .deleted && !$0.inline && $0.ghost.contains("QA") }, "the removed row is a ghost row")
    }

    func testARemovedSectionIsAWholeLineGhostWithItsHeading() {
        let marks = EditLayer.marks(generated: previous, edited: current).marks
        XCTAssertTrue(marks.contains { $0.kind == .deleted && $0.ghost.contains("## 3. Risks") && $0.ghost.contains("The schedule is tight.") })
    }

    func testNoPreviousPlanMeansNoMarks() {
        // Nothing to compare with: the view passes no base at all, so no layer is drawn.
        let marks: [EditMark] = []
        XCTAssertNil(EditLayer.firstChange(in: marks, text: current, section: nil))
    }

    // MARK: - The jump

    private func change(section: String?) -> (offset: Int?, marks: [EditMark]) {
        let marks = EditLayer.marks(generated: previous, edited: current).marks
        return (EditLayer.firstChange(in: marks, text: current, section: section), marks)
    }

    func testTheJumpWithoutASectionIsTheFirstChange() throws {
        let (offset, marks) = change(section: nil)
        XCTAssertEqual(offset, marks.map(\.range.location).min())
        let at = try XCTUnwrap(offset)
        XCTAssertLessThan(at, (current as NSString).range(of: "## 2. Staffing").location, "the first change is in §1")
    }

    func testTheJumpLandsInTheClickedSection() throws {
        let staffing = (current as NSString).range(of: "## 2. Staffing").location
        let (offset, _) = change(section: "## 2. Staffing")
        let at = try XCTUnwrap(offset)
        XCTAssertGreaterThanOrEqual(at, staffing)
        XCTAssertLessThan(at, (current as NSString).length)
        let goals = change(section: "## 1. Goals").offset
        XCTAssertLessThan(try XCTUnwrap(goals), staffing)
    }

    func testTheJumpToARemovedSectionIsItsGhost() throws {
        let (offset, marks) = change(section: "## 3. Risks")
        let ghost = try XCTUnwrap(marks.first { $0.ghost.contains("## 3. Risks") })
        XCTAssertEqual(offset, ghost.range.location)
    }

    func testTheJumpToAnUntouchedSectionIsItsHeading() {
        let steady = "# Plan\n\n## A\n\nsame\n\n## B\n\nold\n"
        let now = "# Plan\n\n## A\n\nsame\n\n## B\n\nnew\n"
        let marks = EditLayer.marks(generated: steady, edited: now).marks
        XCTAssertEqual(EditLayer.firstChange(in: marks, text: now, section: "## A"), (now as NSString).range(of: "## A").location)
        XCTAssertGreaterThan(EditLayer.firstChange(in: marks, text: now, section: "## B") ?? 0, (now as NSString).range(of: "## B").location)
    }

    func testAnUnknownSectionFallsBackToTheFirstChange() {
        let (offset, marks) = change(section: "## 9. Nowhere")
        XCTAssertEqual(offset, marks.map(\.range.location).min())
    }

    // MARK: - Caption

    func testTheCaptionNamesWhatTheMarksAreAgainst() {
        XCTAssertEqual(PlanSection.diffCaption(round: "Refine 2", previous: "Refine 1", unchanged: false), "Changes in Refine 2 since Refine 1")
        XCTAssertEqual(PlanSection.diffCaption(round: "Refine 2", previous: "Refine 1", unchanged: true), "No changes in Refine 2 since Refine 1")
        XCTAssertEqual(PlanSection.diffCaption(round: "Drafts", previous: nil, unchanged: true), "First version: nothing to compare")
    }
}
