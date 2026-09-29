import FleetKit
import XCTest
@testable import FlightDeckMobile

final class OutlineStyleTests: XCTestCase {
    func testSublines() {
        XCTAssertEqual(OutlineStyle.subline(WireSection(heading: "A", level: 2, blockIndex: 1, churn: [4, 0], diverging: false, settledSince: "Round 1")),
                       "still since Round 1")
        XCTAssertEqual(OutlineStyle.subline(WireSection(heading: "B", level: 2, blockIndex: 3, churn: [9, 8], diverging: true, settledSince: nil)),
                       "still moving")
        XCTAssertNil(OutlineStyle.subline(WireSection(heading: "C", level: 2, blockIndex: 5, churn: [9, 8], diverging: false, settledSince: nil)))
    }

    func testPendingNotesCountTowardTheSectionTheyFallIn() {
        let outline = [WireSection(heading: "A", level: 2, blockIndex: 1, churn: [], diverging: false, settledSince: nil),
                       WireSection(heading: "B", level: 2, blockIndex: 4, churn: [], diverging: false, settledSince: nil)]
        func note(_ block: Int?, consumed: Bool = false) -> WireNote {
            WireNote(id: UUID(), kind: "comment", text: "", consumed: consumed, blockIndex: block)
        }
        XCTAssertEqual(OutlineStyle.noteCounts([note(2), note(5), note(6), note(6, consumed: true), note(nil)], outline: outline),
                       [1: 1, 4: 2])
    }

    func testKindNamesCoverEveryKind() {
        XCTAssertEqual(OutlineStyle.kindName("comment", text: "why?"), "Comment")
        XCTAssertEqual(OutlineStyle.kindName("comment", text: ""), "Highlight")
        XCTAssertEqual(OutlineStyle.kindName("question", text: ""), "Question")
        XCTAssertEqual(OutlineStyle.kindName("mustChange", text: "x"), "Must change")
        XCTAssertEqual(OutlineStyle.kindName("replace", text: "x"), "Replace")
        XCTAssertEqual(OutlineStyle.kindName("delete", text: ""), "Delete")
        XCTAssertEqual(OutlineStyle.kindName("somethingNew", text: "x"), "Note")
    }
}
