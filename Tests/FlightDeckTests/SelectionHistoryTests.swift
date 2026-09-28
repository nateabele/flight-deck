import XCTest
@testable import FlightDeck

final class SelectionHistoryTests: XCTestCase {
    private let a = SelectionTarget.session(UUID())
    private let b = SelectionTarget.session(UUID())
    private let c = SelectionTarget.session(UUID())
    private let p = SelectionTarget.project(path: "/w/p")
    private let live: (SelectionTarget) -> Bool = { _ in true }

    func testRecordPushesTheOriginOntoBack() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        XCTAssertEqual(h.back, [a])
        XCTAssertEqual(h.forward, [])
    }

    func testRecordIgnoresNilAndSameTarget() {
        var h = SelectionHistory()
        h.record(from: nil, to: a)
        h.record(from: a, to: nil)
        h.record(from: a, to: a)
        XCTAssertTrue(h.isEmpty)
    }

    func testBackThenForwardRoundTrips() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        h.record(from: b, to: c)
        XCTAssertEqual(h.goBack(from: c, isLive: live), b)
        XCTAssertEqual(h.goBack(from: b, isLive: live), a)
        XCTAssertNil(h.goBack(from: a, isLive: live))
        XCTAssertEqual(h.goForward(from: a, isLive: live), b)
        XCTAssertEqual(h.goForward(from: b, isLive: live), c)
        XCTAssertNil(h.goForward(from: c, isLive: live))
    }

    func testANewSelectionClearsForward() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        _ = h.goBack(from: b, isLive: live)
        h.record(from: a, to: c)
        XCTAssertEqual(h.forward, [])
        XCTAssertEqual(h.back, [a])
    }

    func testDeadEntriesAreSkippedAndDiscarded() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        h.record(from: b, to: c)
        let dest = h.goBack(from: c, isLive: { $0 != self.b })
        XCTAssertEqual(dest, a)
        XCTAssertEqual(h.back, [])
        XCTAssertEqual(h.forward, [c])
    }

    func testNothingLiveLeavesCurrentOffForward() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        XCTAssertNil(h.goBack(from: b, isLive: { _ in false }))
        XCTAssertEqual(h.forward, [], "no destination, so `current` must not be pushed")
        XCTAssertEqual(h.back, [], "the dead entry is discarded on the way")
    }

    /// ⌘⇧T reopens a closed session under its original id, so an entry dead at one moment
    /// can be live at the next. Nothing may prune it before a traversal actually skips it.
    func testAnEntryDeadAtRecordTimeIsStillReachableLater() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        XCTAssertEqual(h.goBack(from: b, isLive: live), a)
    }

    func testBackIsCappedAtTheLimit() {
        var h = SelectionHistory()
        var prev = SelectionTarget.session(UUID())
        let first = prev
        for _ in 0..<(SelectionHistory.limit + 5) {
            let next = SelectionTarget.session(UUID())
            h.record(from: prev, to: next)
            prev = next
        }
        XCTAssertEqual(h.back.count, SelectionHistory.limit)
        XCTAssertFalse(h.back.contains(first), "the oldest entries are the ones dropped")
    }

    func testCodableRoundTripKeepsBothCases() throws {
        var h = SelectionHistory()
        h.record(from: a, to: p)
        h.record(from: p, to: b)
        _ = h.goBack(from: b, isLive: live)
        let decoded = try JSONDecoder().decode(SelectionHistory.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(decoded, h)
    }
}
