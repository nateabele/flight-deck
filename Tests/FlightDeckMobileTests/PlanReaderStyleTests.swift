import XCTest
@testable import FlightDeckMobile

/// Which plan blocks the reader can select. The phone bug this pins: every block was MarkdownUI
/// (not selectable) under a whole-block tap, so text could not be highlighted at all.
final class PlanReaderStyleTests: XCTestCase {

    func testParagraphAndHeadingAreSelectableProse() {
        for text in ["A plain paragraph with **bold** and a [link](https://example.com).", "## Goals"] {
            let segments = PlanReaderStyle.segments(of: text)
            XCTAssertEqual(segments.count, 1, text)
            XCTAssertTrue(segments.allSatisfy(\.isSelectable), text)
        }
    }

    func testListTableQuoteAndCodeStayMarkdownUI() {
        for text in ["- one\n- two", "> quoted", "| a | b |\n|---|---|\n| 1 | 2 |", "```swift\nlet x = 1\n```"] {
            let segments = PlanReaderStyle.segments(of: text)
            XCTAssertFalse(segments.isEmpty, text)
            XCTAssertFalse(segments.contains(where: \.isSelectable), text)
        }
    }

    func testNoteButtonLabelCountsNotes() {
        XCTAssertEqual(PlanReaderStyle.notesLabel(count: 1), "1 note")
        XCTAssertEqual(PlanReaderStyle.notesLabel(count: 3), "3 notes")
    }
}
