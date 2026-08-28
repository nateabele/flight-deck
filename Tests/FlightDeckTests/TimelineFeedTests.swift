import XCTest
@testable import FleetKit

/// What a screen holds while it pages: the items it has, in order, and the two cursors that
/// say what to ask for next.
///
/// Five properties are load-bearing, and each is a bug that looks like a rendering glitch
/// rather than a state bug — which is why they are tested here and not left to the screen:
/// a page merged twice must not double the rows, a page must land where its records BELONG
/// rather than at whichever end arrived last, the cursors must widen in both directions
/// rather than being overwritten, the cursors must be the page's own boundaries and never
/// an item's offset, and a `reset` page must clear everything.
///
/// Every assertion block checks `items`, `oldest`, `newest`, `hasOlder` and
/// `hasLoadedAnything` rather than just the item list: a merge that corrupts a cursor while
/// producing the right rows is exactly the failure that ships, because it looks fine until
/// the next fetch starts inside a record.
final class TimelineFeedTests: XCTestCase {
    private let session = UUID()

    private func item(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText, status: .complete,
                     body: TimelineItem.Body(text: text))
    }

    private func page(
        _ items: [TimelineItem], start: Int, end: Int,
        hasMore: Bool = false, reset: Bool = false
    ) -> TimelinePage {
        TimelinePage(session: session, items: items, start: start, end: end,
                     hasMore: hasMore, reset: reset)
    }

    /// Every observable value at once, so no test can assert the item list and quietly leave
    /// a corrupted cursor behind it.
    private func expect(
        _ feed: TimelineFeed, texts: [String], oldest: Int?, newest: Int?,
        hasOlder: Bool, hasLoadedAnything: Bool,
        _ message: String = "", line: UInt = #line
    ) {
        XCTAssertEqual(feed.items.map(\.body.text), texts, message, line: line)
        XCTAssertEqual(feed.oldest, oldest, "oldest. \(message)", line: line)
        XCTAssertEqual(feed.newest, newest, "newest. \(message)", line: line)
        XCTAssertEqual(feed.hasOlder, hasOlder, "hasOlder. \(message)", line: line)
        XCTAssertEqual(feed.hasLoadedAnything, hasLoadedAnything,
                       "hasLoadedAnything. \(message)", line: line)
        XCTAssertEqual(feed.olderAnchor, oldest.map { TimelineAnchor.before($0) },
                       "olderAnchor must track oldest. \(message)", line: line)
        XCTAssertEqual(feed.newerAnchor, newest.map { TimelineAnchor.after($0) } ?? .latest,
                       "newerAnchor must track newest. \(message)", line: line)
    }

    func testAnEmptyFeedHasLoadedNothingAndAsksForTheLatest() {
        let feed = TimelineFeed()
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertFalse(feed.hasLoadedAnything)
        XCTAssertNil(feed.olderAnchor, "nothing has been loaded, so there is no cursor to "
                     + "page up from — the screen asks for .latest instead")
        XCTAssertEqual(feed.newerAnchor, .latest)
        XCTAssertNil(feed.oldest)
        XCTAssertNil(feed.newest)
        XCTAssertFalse(feed.hasOlder)
    }

    func testTheFirstPageBecomesTheFeed() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true))
        expect(feed, texts: ["a", "b"], oldest: 10, newest: 30,
               hasOlder: true, hasLoadedAnything: true)
    }

    /// **The cursors are the PAGE's boundaries, never an item's offset.** When the oldest
    /// boundary in a page is a blank line, `start` names the blank and the first record
    /// begins a byte later; `end` is the boundary past the last record, not that record's own
    /// offset. Deriving either from `items` drops the blank's byte, so the next `.before`
    /// starts inside the record above it and that record is lost while the cursor moves past
    /// it. The Mac already shipped one instance of this class of bug; this is the last layer
    /// it could reappear in.
    ///
    /// No fixture value here coincides with any other: 10 is not 11, and 42 is not 31.
    func testTheCursorsComeFromThePageBoundariesAndNotFromTheItems() {
        var feed = TimelineFeed()
        feed.merge(page([item("11#0", "a"), item("31#0", "b")], start: 10, end: 42, hasMore: true))
        expect(feed, texts: ["a", "b"], oldest: 10, newest: 42,
               hasOlder: true, hasLoadedAnything: true,
               "start names a blank line one byte before the first record")
    }

    /// **An older page goes on the front.** Appending it instead puts the conversation's
    /// beginning underneath its end — which on screen reads as the agent answering before it
    /// was asked, and looks like a rendering bug rather than a merge bug.
    func testAnOlderPageIsPrepended() {
        var feed = TimelineFeed()
        feed.merge(page([item("30#0", "c")], start: 30, end: 40, hasMore: true))
        feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: false))
        XCTAssertEqual(feed.items.map(\.body.text), ["a", "b", "c"])
        XCTAssertEqual(feed.oldest, 10)
        XCTAssertEqual(feed.newest, 40, "a page above must not drag the newest cursor back")
        XCTAssertFalse(feed.hasOlder)
        expect(feed, texts: ["a", "b", "c"], oldest: 10, newest: 40,
               hasOlder: false, hasLoadedAnything: true)
    }

    func testANewerPageIsAppended() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([item("20#0", "b")], start: 20, end: 30))
        XCTAssertEqual(feed.items.map(\.body.text), ["a", "b"])
        XCTAssertEqual(feed.oldest, 10, "a page below must not drag the oldest cursor forward")
        XCTAssertEqual(feed.newest, 30)
        XCTAssertTrue(feed.hasOlder, "hasOlder is about the TOP of the feed and a page at the "
                      + "bottom says nothing about it")
        expect(feed, texts: ["a", "b"], oldest: 10, newest: 30,
               hasOlder: true, hasLoadedAnything: true)
    }

    /// **A page lands where its records belong, not at whichever end arrived last.** Prepend
    /// an older page and append a newer one and the two anchors a screen issues are served
    /// correctly — right up until a third page arrives for a range BETWEEN two already held.
    /// A reply that overtook another, or a `.latest` fetched over a feed that had scrolled
    /// away from the bottom, both produce that, and the result is the middle of the
    /// conversation printed after its end.
    func testAPageForTheMiddleLandsInTheMiddle() {
        var feed = TimelineFeed()
        feed.merge(page([item("0#0", "a")], start: 0, end: 10, hasMore: false))
        feed.merge(page([item("200#0", "d")], start: 200, end: 210, hasMore: true))
        feed.merge(page([item("100#0", "b"), item("120#0", "c")], start: 100, end: 130,
                        hasMore: true))
        expect(feed, texts: ["a", "b", "c", "d"], oldest: 0, newest: 210,
               hasOlder: false, hasLoadedAnything: true,
               "the top was reached at offset 0 and no later page may reopen it")
    }

    /// **Dedupe.** The poll re-asks from `newest` and a screen re-entered re-asks for
    /// `.latest`, so overlapping pages are ordinary rather than exceptional. Ids are stable
    /// (they are byte offsets), which is what makes this possible at all.
    func testMergingTheSamePageTwiceChangesNothing() {
        var feed = TimelineFeed()
        let first = page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true)
        feed.merge(first)
        let once = feed
        feed.merge(first)
        XCTAssertEqual(feed.items.map(\.id), ["10#0", "20#0"])
        XCTAssertEqual(feed.oldest, 10)
        XCTAssertEqual(feed.newest, 30)
        XCTAssertEqual(feed, once, "merging a page twice must be indistinguishable from once")
        expect(feed, texts: ["a", "b"], oldest: 10, newest: 30,
               hasOlder: true, hasLoadedAnything: true)
    }

    func testAPartiallyOverlappingPageAddsOnlyWhatIsNew() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true))
        feed.merge(page([item("20#0", "b"), item("30#0", "c")], start: 20, end: 40))
        XCTAssertEqual(feed.items.map(\.id), ["10#0", "20#0", "30#0"])
        expect(feed, texts: ["a", "b", "c"], oldest: 10, newest: 40,
               hasOlder: true, hasLoadedAnything: true)
    }

    /// The same overlap in the other direction, which is the one a merge gets wrong: the
    /// shared record must not be doubled AND the page's new record must go above what is
    /// held, not below it.
    func testAnOlderOverlappingPageNeitherDuplicatesNorReorders() {
        var feed = TimelineFeed()
        feed.merge(page([item("20#0", "b"), item("30#0", "c")], start: 20, end: 40, hasMore: true))
        feed.merge(page([item("0#0", "a"), item("20#0", "b")], start: 0, end: 30, hasMore: false))
        XCTAssertEqual(feed.items.map(\.id), ["0#0", "20#0", "30#0"])
        expect(feed, texts: ["a", "b", "c"], oldest: 0, newest: 40,
               hasOlder: false, hasLoadedAnything: true)
    }

    /// A re-delivered item wins on content, not on arrival order: a body that was truncated
    /// by a page budget and arrives whole in a later page must replace the short one, not be
    /// discarded as a duplicate.
    func testARedeliveredItemReplacesTheOneHeld() {
        var feed = TimelineFeed()
        var short = item("10#0", "abc")
        short.body.truncatedBytes = 100
        feed.merge(page([short], start: 10, end: 20))
        feed.merge(page([item("10#0", "abcdef")], start: 10, end: 20))
        XCTAssertEqual(feed.items.map(\.body.text), ["abcdef"])
        XCTAssertEqual(feed.items[0].body.truncatedBytes, 0)
        expect(feed, texts: ["abcdef"], oldest: 10, newest: 20,
               hasOlder: false, hasLoadedAnything: true)
    }

    /// **`reset` clears everything.** Item ids are byte offsets into the transcript, so a
    /// replaced file makes every id the feed holds name a different record. Merging into it
    /// would interleave two conversations under matching ids — the exact failure the flag
    /// exists to prevent, and it would look like corruption rather than staleness.
    func testAResetPageEmptiesTheFeed() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([], start: 0, end: 0, reset: true))
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertNil(feed.oldest)
        XCTAssertNil(feed.newest)
        XCTAssertFalse(feed.hasLoadedAnything, "the screen must fetch .latest again, not page "
                       + "from a cursor that has been declared meaningless")
        XCTAssertEqual(feed.newerAnchor, .latest)
        XCTAssertEqual(feed, TimelineFeed(), "a reset feed is a new feed, in every field")
    }

    /// A `reset` after several pages have been merged, with a `reset` page whose own cursors
    /// are non-zero — which is what the Mac actually sends: `TranscriptPager.reset` reports
    /// the file's new size at both ends. Those must not become the feed's cursors, and
    /// `hasOlder` must go back to false rather than surviving from the pages being discarded.
    func testAResetDiscardsEveryPageMergedBeforeItAndAdoptsNoneOfItsOwnCursors() {
        var feed = TimelineFeed()
        feed.merge(page([item("100#0", "b")], start: 100, end: 110, hasMore: true))
        feed.merge(page([item("0#0", "a")], start: 0, end: 100, hasMore: true))
        expect(feed, texts: ["a", "b"], oldest: 0, newest: 110,
               hasOlder: true, hasLoadedAnything: true, "before the reset")

        feed.merge(page([], start: 512, end: 512, reset: true))
        expect(feed, texts: [], oldest: nil, newest: nil,
               hasOlder: false, hasLoadedAnything: false,
               "512 is the replaced file's size and means nothing to a feed that must "
               + "re-fetch .latest")
    }

    /// An empty page from a poll is the ordinary case — nothing new since the last look —
    /// and must not read as "the conversation ended".
    func testAnEmptyNewerPageLeavesTheFeedAlone() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([], start: 20, end: 20))
        XCTAssertEqual(feed.items.map(\.id), ["10#0"])
        XCTAssertEqual(feed.newest, 20)
        XCTAssertTrue(feed.hasOlder)
        expect(feed, texts: ["a"], oldest: 10, newest: 20,
               hasOlder: true, hasLoadedAnything: true)
    }

    /// The other legitimate empty page: paging up has reached the top of history. It carries
    /// no items and it still carries a real boundary, so it moves `oldest` and answers
    /// `hasOlder` — and it must not drag `newest` back to that boundary with it.
    func testAnEmptyOlderPageReachesTheTopWithoutDisturbingWhatIsHeld() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([], start: 0, end: 0, hasMore: false))
        expect(feed, texts: ["a"], oldest: 0, newest: 20,
               hasOlder: false, hasLoadedAnything: true,
               "olderAnchor stays non-nil at the top; hasOlder is what stops the fetch")
    }

    /// Reaching the top is a fact the screen renders (no spinner, no further fetch), so it
    /// has to survive later pages arriving at the bottom.
    func testReachingTheTopStaysReachedAsNewerPagesArrive() {
        var feed = TimelineFeed()
        feed.merge(page([item("0#0", "a")], start: 0, end: 10, hasMore: false))
        XCTAssertFalse(feed.hasOlder)
        feed.merge(page([item("10#0", "b")], start: 10, end: 20, hasMore: true))
        XCTAssertFalse(feed.hasOlder, "hasMore on a page BELOW says nothing about the top")
        expect(feed, texts: ["a", "b"], oldest: 0, newest: 20,
               hasOlder: false, hasLoadedAnything: true)
    }

    /// And it has to survive a STALE page from above arriving late. A `.before` reply that
    /// overtook the one after it still says `hasMore: true` about a top that has since been
    /// reached, and believing it puts a spinner back above the first line of the
    /// conversation with nothing left to fetch.
    func testAStaleOlderPageArrivingLateDoesNotReopenTheTop() {
        var feed = TimelineFeed()
        feed.merge(page([item("100#0", "c")], start: 100, end: 110, hasMore: true))
        let middle = page([item("50#0", "b")], start: 50, end: 100, hasMore: true)
        feed.merge(middle)
        XCTAssertTrue(feed.hasOlder, "there really is more above offset 50")
        feed.merge(page([item("0#0", "a")], start: 0, end: 50, hasMore: false))
        feed.merge(middle)
        expect(feed, texts: ["a", "b", "c"], oldest: 0, newest: 110,
               hasOlder: false, hasLoadedAnything: true,
               "the re-delivered middle page's hasMore is about offset 50, not about the top")
    }

    /// `TimelinePage.items` is documented as file order for every anchor, so this is a
    /// defence rather than an observed Mac behaviour — but it is the defence that keeps the
    /// ordering invariant unconditional. One page that ever arrived out of order would leave
    /// `items` permanently unsorted and every merge after it wrong.
    func testAPageWhoseItemsArriveOutOfOrderIsStillHeldInOrder() {
        var feed = TimelineFeed()
        feed.merge(page([item("0#0", "a")], start: 0, end: 10, hasMore: false))
        feed.merge(page([item("30#0", "d"), item("10#0", "b"), item("20#0", "c")],
                        start: 10, end: 40))
        expect(feed, texts: ["a", "b", "c", "d"], oldest: 0, newest: 40,
               hasOlder: false, hasLoadedAnything: true)
    }

    /// Order comes from the id's two NUMBERS, not from the id as text. One assistant record
    /// can carry eleven blocks, and `"10#10"` sorts before `"10#2"` as a string — which would
    /// print a reply's eleventh paragraph as its second.
    func testBlocksOfOneRecordOrderByIndexNumericallyRatherThanAsText() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#10", "k"), item("10#2", "c"), item("10#0", "a")],
                        start: 10, end: 20))
        expect(feed, texts: ["a", "c", "k"], oldest: 10, newest: 20,
               hasOlder: false, hasLoadedAnything: true)
    }

    /// An id shaped by a Mac newer than this build sorts last rather than scrambling the ids
    /// this build does understand — the same promise `TimelineItem.Kind.unknown` makes.
    func testAnUnparseableIdSortsLastAndLeavesTheRestInOrder() {
        var feed = TimelineFeed()
        feed.merge(page([item("30#0", "c"), item("v2:abc", "z"), item("10#0", "a")],
                        start: 10, end: 40))
        expect(feed, texts: ["a", "c", "z"], oldest: 10, newest: 40,
               hasOlder: false, hasLoadedAnything: true)
    }
}
