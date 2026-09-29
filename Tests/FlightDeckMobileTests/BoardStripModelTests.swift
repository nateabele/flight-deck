import FleetKit
import XCTest
@testable import FlightDeckMobile

final class BoardStripModelTests: XCTestCase {
    static func detail(state: String = "shaping", run: String = "running", attention: Bool = false,
                       slots: [WireSlot], caption: String = "IN THE AIR", stop: String? = "encode-0") -> WireIntakeDetail {
        WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "T", state: state, needsAttention: attention,
                                       runStatus: run, createdAt: Date()),
            intent: "I", progress: [],
            board: WireBoard(slots: slots, nowName: "Refine 2", nowChip: "ON COURSE", clockCaption: caption,
                             clockSince: Date(timeIntervalSinceReferenceDate: 0), clockText: nil, stopsAt: "Encode",
                             stopSlotID: stop, callingAt: "2 · Polish 6 · Review",
                             convergence: WireConvergence(word: "DIVERGING ↗", amber: true, spark: []), defaultPlay: "nextMajor"),
            agents: [], rounds: [], pendingNotes: 0, servedAt: Date())
    }
    static let slots = [
        WireSlot(id: "refine-1", name: "Refine 1", code: "RF1", state: "done", major: false, group: "REFINE", checkpoint: 3, duration: 391),
        WireSlot(id: "refine-2", name: "Refine 2", code: "RF2", state: "live", major: false, group: "REFINE"),
        WireSlot(id: "refine-3", name: "Refine 3", code: "RF3", state: "future", major: false, group: "REFINE"),
        WireSlot(id: "encode-0", name: "Encode", code: "ENC", state: "future", major: true),
    ]

    func testNowCountsTheRoundInItsCycle() {
        XCTAssertEqual(BoardStripModel(detail: Self.detail(slots: Self.slots)).nowText, "REFINE 2 OF 3")
    }

    func testOnlyLandedDotsAreTappableAndTheStopIsMarked() {
        let dots = BoardStripModel(detail: Self.detail(slots: Self.slots)).dots
        XCTAssertEqual(dots.map(\.tappable), [true, false, false, false])
        XCTAssertEqual(dots.first { $0.isStop }?.id, "encode-0")
        XCTAssertEqual(dots[0].label, "Refine 1, landed, 6 minutes 31")
    }

    func testToneFollowsState() {
        XCTAssertEqual(BoardStripModel(detail: Self.detail(slots: Self.slots)).tone, .live)
        XCTAssertEqual(BoardStripModel(detail: Self.detail(run: "paused", slots: Self.slots, caption: "PAUSED FOR")).tone, .quiet)
        XCTAssertTrue(BoardStripModel(detail: Self.detail(run: "paused", slots: Self.slots, caption: "PAUSED FOR")).idle)
        XCTAssertEqual(BoardStripModel(detail: Self.detail(state: "review", run: "reachedReview", attention: true, slots: Self.slots)).tone, .attention)
        XCTAssertEqual(BoardStripModel(detail: Self.detail(state: "failed", run: "failed", attention: true, slots: Self.slots)).tone, .failure)
    }

    func testTheStopAndConvergenceLine() {
        let m = BoardStripModel(detail: Self.detail(slots: Self.slots))
        XCTAssertEqual(m.stopText, "→ STOPS AT ENCODE")
        XCTAssertEqual(m.convergence, "DIVERGING ↗")
        XCTAssertTrue(m.convergenceAmber)
    }

    func testANeedsAnswersIntakeWithNoBoardReadsItsTurn() {
        var d = Self.detail(state: "needsAnswers", attention: true, slots: [])
        d.board = nil
        d.summary.now = "Clarify 1"
        XCTAssertEqual(BoardStripModel(detail: d).nowText, "CLARIFY 1 · YOUR TURN")
    }
}
