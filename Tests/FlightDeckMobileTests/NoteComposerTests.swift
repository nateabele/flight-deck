import XCTest
@testable import FlightDeckMobile

final class NoteComposerTests: XCTestCase {
    func testKindsOrderAndTitles() {
        XCTAssertEqual(NoteComposer.kinds.map(\.id),
                       ["comment", "question", "mustChange", "replace", "delete", "highlight"])
        XCTAssertEqual(NoteComposer.kinds.map(\.title),
                       ["Comment", "Question", "Must change", "Replace", "Delete", "Highlight"])
    }

    func testCanAdd() {
        XCTAssertTrue(NoteComposer.canAdd(kind: "highlight", text: ""))
        XCTAssertFalse(NoteComposer.canAdd(kind: "comment", text: "  \n "))
        XCTAssertTrue(NoteComposer.canAdd(kind: "comment", text: "x"))
        XCTAssertFalse(NoteComposer.canAdd(kind: "replace", text: ""))
    }

    func testWire() {
        XCTAssertTrue(NoteComposer.wire(kind: "highlight") == ("comment", true))
        XCTAssertTrue(NoteComposer.wire(kind: "question") == ("question", false))
    }

    func testNotesAllowed() {
        XCTAssertFalse(NoteComposer.notesAllowed(detail: nil))
        XCTAssertTrue(NoteComposer.notesAllowed(detail: TransportKeysTests.detail()))
        XCTAssertFalse(NoteComposer.notesAllowed(detail: TransportKeysTests.detail(state: "planning")))
    }
}
