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

    /// The names the Mac draws sizes with are `phone`, `mac`, `wide`, a width: `narrow` is only
    /// one an agent may happen to write. A phone takes the narrowest of what is listed.
    func testThePhoneTakesThePhoneSizeOrTheNarrowestListed() {
        func size(_ sizes: [String]) -> String? { VisualBlockStyle.size(for: WireVisualRef(id: "f", revision: 1, sizes: sizes)) }
        XCTAssertEqual(size(["wide", "phone"]), "phone")
        XCTAssertEqual(size(["mac", "compact", "narrow"]), "compact")
        XCTAssertEqual(size(["wide", "tablet", "mac"]), "tablet")
        XCTAssertEqual(size(["default", "640"]), "640")
        XCTAssertEqual(size(["default"]), "default")
    }

    /// An alternate whose files the Mac listed opens like the primary does; one without is a chip.
    func testAnAlternateWithFilesIsARefTheViewerCanOpen() {
        let files = [WireVisualFile(path: "snapshot@idle-wide.png", size: 1, sha256: "a"),
                     WireVisualFile(path: "snapshot@idle-phone.png", size: 1, sha256: "b"),
                     WireVisualFile(path: "snapshot@failed-wide.png", size: 1, sha256: "c")]
        let alt = WireVisualAlternate(revision: 4, kind: "component", reason: "owns each step", files: files)
        let ref = WireVisualRef(id: "flow", revision: 3, kinds: ["flow"], alternates: [alt], states: ["idle", "failed", "gone"],
                                sizes: ["wide", "phone", "tablet"], aspect: 2, files: [])
        let opened = VisualBlockStyle.ref(opening: alt, of: ref)
        XCTAssertEqual(opened?.id, "flow")
        XCTAssertEqual(opened?.revision, 4)
        XCTAssertEqual(opened?.files, files)
        XCTAssertEqual(opened?.states, ["idle", "failed"], "the states this revision has pictures of")
        XCTAssertEqual(opened?.sizes, ["wide", "phone"])
        XCTAssertEqual(opened?.aspect, 2)
        XCTAssertEqual(opened?.alternates, [], "an alternate has no alternates of its own")
        // A state whose name ends in another size's suffix is not mistaken for that size.
        let tricky = WireVisualAlternate(revision: 6, kind: "x", files: [WireVisualFile(path: "snapshot@a-phone-wide.png", size: 1, sha256: "a")])
        let trickyRef = WireVisualRef(id: "flow", revision: 3, states: ["a-phone", "a"], sizes: ["phone", "wide"])
        let opened2 = VisualBlockStyle.ref(opening: tricky, of: trickyRef)
        XCTAssertEqual(opened2?.states, ["a-phone"], "state a-phone at size wide; no state a")
        XCTAssertEqual(opened2?.sizes, ["wide"], "no picture at size phone")
        XCTAssertNil(VisualBlockStyle.ref(opening: WireVisualAlternate(revision: 5, kind: "flow"), of: ref), "no files: only a chip")
        XCTAssertNil(VisualBlockStyle.ref(opening: WireVisualAlternate(revision: 5, kind: "flow", files: []), of: ref))
    }
}
