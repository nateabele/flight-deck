import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The plan reader's visual blocks (P2a V3), and the gate in front of them: a Mac whose detail
/// does not say `visuals == true` gets plan text exactly as old plans looked.
final class VisualBlockGateTests: XCTestCase {
    private let block = "```fd-visual id=pairing-handshake\nPairing handshake: phone, Mac and hostd\n```"

    private func detail(visuals: Bool?) -> WireIntakeDetail {
        WireIntakeDetail(etag: "e", project: UUID(),
                         summary: WireIntakeSummary(id: UUID(), title: "T", state: "shaping", needsAttention: false,
                                                    createdAt: Date()),
                         intent: "i", servedAt: Date(), visuals: visuals)
    }

    func testTheGateIsTheDetailsFlagAndNothingElse() {
        XCTAssertTrue(PlanReaderStyle.visualsAllowed(detail: detail(visuals: true)))
        XCTAssertFalse(PlanReaderStyle.visualsAllowed(detail: detail(visuals: false)))
        XCTAssertFalse(PlanReaderStyle.visualsAllowed(detail: detail(visuals: nil)))
        XCTAssertFalse(PlanReaderStyle.visualsAllowed(detail: nil))
    }

    func testWithoutTheGateTheFenceIsPlainCodeAsBefore() {
        let segments = PlanReaderStyle.segments(of: block, visuals: false)
        XCTAssertEqual(segments, [.code(language: "fd-visual", "Pairing handshake: phone, Mac and hostd")])
        XCTAssertEqual(segments, PlanReaderStyle.segments(of: block), "the old entry point is the closed gate")
    }

    func testWithTheGateTheFenceIsAVisualSegmentWithItsCaption() {
        XCTAssertEqual(PlanReaderStyle.segments(of: block, visuals: true),
                       [.visual(id: "pairing-handshake", caption: "Pairing handshake: phone, Mac and hostd")])
    }

    func testProseAroundAVisualIsKept() {
        let text = "Before.\n\n\(block)\n\nAfter."
        let segments = PlanReaderStyle.segments(of: text, visuals: true)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .prose("Before."))
        XCTAssertEqual(segments[1], .visual(id: "pairing-handshake", caption: "Pairing handshake: phone, Mac and hostd"))
        XCTAssertEqual(segments[2], .prose("After."))
    }

    func testAPendingBlockAndAMissingCaption() {
        XCTAssertEqual(PlanReaderStyle.segments(of: "```fd-visual id=flow pending\n```", visuals: true),
                       [.visual(id: "flow", caption: "")])
    }

    /// The Mac's parser decides which info strings are visuals (`VisualFenceInfo.parse`); a bad
    /// id stays an ordinary code block even with the gate open.
    func testABadIdOrAnotherLanguageStaysCode() {
        for info in ["fd-visual", "fd-visual id=Bad_ID", "fd-visual id=../x", "swift"] {
            let segments = PlanReaderStyle.segments(of: "```\(info)\nbody\n```", visuals: true)
            XCTAssertEqual(segments, [.code(language: info.split(separator: " ").first.map(String.init), "body")], info)
        }
    }

    func testAVisualSegmentIsNotSelectableProse() {
        XCTAssertFalse(TimelineSegment.visual(id: "flow", caption: "c").isSelectable)
        XCTAssertEqual(TimelineSegment.visual(id: "flow", caption: "c").text, "c")
    }

    func testTheCardIsSizedFromAspectBeforeAnyBytes() {
        XCTAssertEqual(VisualBlockStyle.aspect(for: WireVisualRef(id: "f", revision: 1, aspect: 2.0)), 2.0)
        XCTAssertEqual(VisualBlockStyle.aspect(for: WireVisualRef(id: "f", revision: 1)), VisualBlockStyle.defaultAspect)
        XCTAssertEqual(VisualBlockStyle.aspect(for: nil), VisualBlockStyle.defaultAspect)
        XCTAssertEqual(VisualBlockStyle.aspect(for: WireVisualRef(id: "f", revision: 1, aspect: 0)), VisualBlockStyle.defaultAspect)
        XCTAssertEqual(VisualBlockStyle.aspect(for: WireVisualRef(id: "f", revision: 1, aspect: 100)), VisualBlockStyle.maxAspect)
    }

    func testTheCardPicksTheNarrowSnapshotOnAPhone() {
        let ref = WireVisualRef(id: "f", revision: 1, states: ["a", "b"], sizes: ["wide", "narrow"])
        XCTAssertEqual(VisualBlockStyle.size(for: ref), "narrow")
        XCTAssertEqual(VisualBlockStyle.size(for: WireVisualRef(id: "f", revision: 1, sizes: ["wide"])), "wide")
        XCTAssertNil(VisualBlockStyle.size(for: WireVisualRef(id: "f", revision: 1)))
        XCTAssertEqual(VisualBlockStyle.state(for: ref), "a")
    }
}
