import XCTest
@testable import FleetKit

/// The fold that turns a flat item list into rows, moved out of the phone's view so the
/// macOS suite can hold its one hard invariant: a tool result is paired with its call across a
/// page boundary and never dropped when its call sits on an adjacent page.
final class TimelineRenderTests: XCTestCase {
    private func item(_ id: String, _ kind: TimelineItem.Kind, callID: String? = nil) -> TimelineItem {
        TimelineItem(id: id, kind: kind, status: .complete,
                     body: TimelineItem.Body(text: id, callID: callID))
    }

    func testAProseRowFoldsToOneEntryWithNoResult() {
        let entries = TimelineRender.entries(from: [item("0#0", .assistantText)])
        XCTAssertEqual(entries.map(\.id), ["0#0"])
        XCTAssertNil(entries[0].result)
    }

    func testAToolResultIsFoldedIntoItsCallByCallID() {
        let entries = TimelineRender.entries(from: [
            item("0#0", .toolCall, callID: "tA"),
            item("10#0", .toolResult, callID: "tA"),
        ])
        XCTAssertEqual(entries.map(\.id), ["0#0"], "the result folds away into its call's row")
        XCTAssertEqual(entries[0].result?.id, "10#0")
    }

    /// The invariant this whole move exists to protect: a result whose call is NOT in the
    /// window must survive as its own row rather than being dropped.
    func testAToolResultWhoseCallIsAbsentSurvivesAsItsOwnRow() {
        let entries = TimelineRender.entries(from: [item("10#0", .toolResult, callID: "tA")])
        XCTAssertEqual(entries.map(\.id), ["10#0"])
        XCTAssertNil(entries[0].result)
    }

    /// Two tools running at once interleave; each result must pair with ITS call, never "the
    /// next result".
    func testInterleavedCallsPairEachResultWithItsOwnCall() {
        let entries = TimelineRender.entries(from: [
            item("0#0", .toolCall, callID: "tA"),
            item("10#0", .toolCall, callID: "tB"),
            item("20#0", .toolResult, callID: "tB"),
            item("30#0", .toolResult, callID: "tA"),
        ])
        XCTAssertEqual(entries.map(\.id), ["0#0", "10#0"])
        XCTAssertEqual(entries[0].result?.id, "30#0", "tA's call paired with tA's result")
        XCTAssertEqual(entries[1].result?.id, "20#0", "tB's call paired with tB's result")
    }

    /// The first result for a call wins; a duplicate result does not fold and stays a row.
    func testASecondResultForOneCallIsNotFoldedTwice() {
        let entries = TimelineRender.entries(from: [
            item("0#0", .toolCall, callID: "tA"),
            item("10#0", .toolResult, callID: "tA"),
            item("20#0", .toolResult, callID: "tA"),
        ])
        XCTAssertEqual(entries[0].result?.id, "10#0")
        XCTAssertEqual(entries.map(\.id), ["0#0", "20#0"],
                       "the call folds its first result; the second stands alone")
    }
}
