import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
final class TimelineSegmentCacheTests: XCTestCase {
    private func prose(_ id: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText, status: .complete,
                     body: .init(text: "**bold** and `code` across a line or two"))
    }

    func testASecondCallWithTheSameKeyIsAMemoHit() {
        let cache = TimelineSegmentCache()
        let item = prose("0#0")
        let first = cache.clamped(for: item, expanded: false, widthBucket: 12)
        let second = cache.clamped(for: item, expanded: false, widthBucket: 12)
        XCTAssertEqual(cache.computeCount, 1, "the segmenter ran once for two identical asks")
        XCTAssertEqual(first, second)
    }

    func testExpandedAndWidthAndIdAreEachPartOfTheKey() {
        let cache = TimelineSegmentCache()
        let item = prose("0#0")
        _ = cache.clamped(for: item, expanded: false, widthBucket: 12)
        _ = cache.clamped(for: item, expanded: true, widthBucket: 12)   // expanded differs
        _ = cache.clamped(for: item, expanded: false, widthBucket: 11)  // width differs
        _ = cache.clamped(for: prose("10#0"), expanded: false, widthBucket: 12) // id differs
        XCTAssertEqual(cache.computeCount, 4, "each axis of the key is a distinct entry")
    }

    func testTheCacheIsBoundedAndEvicts() {
        let cache = TimelineSegmentCache(capacity: 2)
        _ = cache.clamped(for: prose("0#0"), expanded: false, widthBucket: 1)
        _ = cache.clamped(for: prose("1#0"), expanded: false, widthBucket: 1)
        _ = cache.clamped(for: prose("2#0"), expanded: false, widthBucket: 1) // evicts 0#0
        _ = cache.clamped(for: prose("0#0"), expanded: false, widthBucket: 1) // recompute
        XCTAssertEqual(cache.computeCount, 4, "the evicted key recomputes rather than hitting")
    }

    /// **The reason `TimelineRow.expandsInPlace` may not reuse the `isExpanded`-keyed clamp.**
    /// `TimelineStyle.clampedProse(for:expanded:)` always answers `hasMore: false` once
    /// `expanded` is `true` — the clamp only ever runs when `!expanded` — so the expanded entry
    /// in this cache carries no memory of whether the message needed cutting at all. A More/Less
    /// link driven off it would show More, then vanish the instant the row expands, with no way
    /// back to collapsed. This is the invariant `TimelineRow.collapsedClamped` exists to route
    /// around by always asking this cache with `expanded: false`.
    func testTheExpandedEntryAlwaysAnswersNoMoreEvenWhenTheCollapsedFormWasCut() {
        let cache = TimelineSegmentCache()
        let long = TimelineFixtures.assistantJustOverTheCeiling
        XCTAssertTrue(
            cache.clamped(for: long, expanded: false, widthBucket: 12).hasMore,
            "collapsed, a 134-line answer against a 120-line ceiling is cut and offers More"
        )
        XCTAssertFalse(
            cache.clamped(for: long, expanded: true, widthBucket: 12).hasMore,
            "expanded, the same answer is drawn whole and its own entry says so"
        )
    }
}
