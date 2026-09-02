import FleetKit
import XCTest
@testable import FlightDeckMobile

/// A `FleetModel` stand-in that hands the completion back to the test instead of to a socket.
///
/// The real thing needs a pairing, a Bonjour browse and a Mac to answer anything at all, so
/// this is the only way the transitions below can be driven: a fetch that is never answered,
/// an answer that arrives after its deadline, and a refusal delivered *before* the request
/// returns are all ordinary on a real link and none of them is reproducible on demand.
@MainActor
private final class StubPager: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
    /// Recorded so a test can assert the screen reports itself; see `viewing(_:)`.
    private(set) var viewingReports: [UUID?] = []
    func viewing(_ session: UUID?) { viewingReports.append(session) }

    private(set) var requests: [FleetRequest] = []
    /// Every session this pager was told had been looked at, in order.
    private(set) var marksRead: [UUID] = []
    private var pending: [(Result<TimelinePage, FleetRequestError>) -> Void] = []

    /// When set, every request is answered **before `timelinePage` returns** — the
    /// `.disconnected` path `FleetConnector.request(_:then:)` takes deliberately, and the one
    /// that runs a completion inside the frame that started the fetch.
    var answerBeforeReturning: Result<TimelinePage, FleetRequestError>?

    var isWaiting: Bool { !pending.isEmpty }
    var anchors: [TimelineAnchor] {
        requests.compactMap { request in
            guard case .timeline(_, let anchor, _) = request else { return nil }
            return anchor
        }
    }

    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        requests.append(request)
        if let answer = answerBeforeReturning { return completion(answer) }
        pending.append(completion)
    }

    func markRead(_ id: UUID) { marksRead.append(id) }

    /// This file's tests never send a prompt — `SessionTimelinePromptTests` owns that half —
    /// but `SessionTimelineModel` now requires both verbs from one object, so the stub has to
    /// answer this. Recorded rather than ignored, so a stray send from the paging path shows
    /// up here rather than disappearing.
    private(set) var commands: [FleetCommand] = []

    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        commands.append(command)
    }

    /// Nor does this file answer a prompt — `SessionTimelineBlockedTests` owns that half — but
    /// the model requires all three verbs from one object. Recorded rather than ignored, so a
    /// stray answer from the paging path shows up here rather than disappearing.
    var sent: FleetCommand?

    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    ) {
        sent = command
    }

    /// Answers the oldest outstanding request, the way the socket resolves a `cid`.
    func answer(_ result: Result<TimelinePage, FleetRequestError>, line: UInt = #line) {
        guard !pending.isEmpty else {
            return XCTFail("nothing was asked for, so there is nothing to answer", line: line)
        }
        pending.removeFirst()(result)
    }
}

/// The model between the fleet socket and the session screen: which fetch is in flight, how
/// long it is allowed to take, and what the screen says when one fails.
///
/// The pagination itself is `TimelineFeed`'s and is tested in `TimelineFeedTests` on macOS.
/// What is left here is the part a value type cannot hold — time, overlap, and the three
/// things that reach `phase` — and each test below is written to fail against one specific
/// way of getting it wrong rather than to observe that something changed.
///
/// **Every fixture's `start` is deliberately below its first item's offset and its `end`
/// deliberately above its last.** A page's boundary and its items' offsets are different
/// numbers — a blank line at the boundary is enough to separate them — and fixtures that set
/// them equal are why the cursor bug this repo already shipped stayed invisible through ten
/// tests. Here, an implementation that paged from `items.first` would ask for `.before(1040)`
/// and this file would say so.
@MainActor
final class SessionTimelineModelTests: XCTestCase {
    private let session = UUID()

    private func item(_ offset: Int, _ text: String) -> TimelineItem {
        TimelineItem(id: "\(offset)#0", kind: .assistantText, status: .complete,
                     body: TimelineItem.Body(text: text))
    }

    /// Like `item(_:_:)`, but for the multi-item-per-offset tests below, where the kind and
    /// the sub-index both matter and `.assistantText` at `#0` is too little to tell them apart.
    private func item(_ offset: Int, index: Int, kind: TimelineItem.Kind, _ text: String) -> TimelineItem {
        TimelineItem(id: "\(offset)#\(index)", kind: kind, status: .complete,
                     body: TimelineItem.Body(text: text))
    }

    private func page(
        _ items: [TimelineItem], start: Int, end: Int,
        hasMore: Bool = false, reset: Bool = false
    ) -> Result<TimelinePage, FleetRequestError> {
        .success(TimelinePage(session: session, items: items, start: start, end: end,
                              hasMore: hasMore, reset: reset))
    }

    /// The tail of a conversation: two records at 1040 and 1090, in a page whose boundaries
    /// are 1000 and 1200 and match neither.
    private func tail(hasMore: Bool = true) -> Result<TimelinePage, FleetRequestError> {
        page([item(1040, "first"), item(1090, "second")],
             start: 1000, end: 1200, hasMore: hasMore)
    }

    private func model(
        _ pager: StubPager, timeout: Duration = .seconds(15)
    ) -> SessionTimelineModel {
        SessionTimelineModel(sessionID: session, fleet: pager, timeout: timeout)
    }

    /// Spins the main actor until `condition` holds. Only the deadline tests use it, and only
    /// because a deadline is the one thing here that is genuinely about elapsed time.
    private func settle(
        until condition: () -> Bool, _ message: String, line: UInt = #line
    ) async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(5) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting: \(message)", line: line)
    }

    // MARK: Opening a session

    /// **Where the read mark comes from, and why it moved here.**
    ///
    /// The fleet list used to send it from a `.simultaneousGesture(TapGesture())` hung off
    /// each row's `NavigationLink` — a second recogniser competing for the tap that opens the
    /// session, which swallowed enough of them that rows stopped opening at all. Opening the
    /// conversation is the "I have looked at this" spec §8's unread means, so the mark
    /// belongs on the screen that opens rather than on a gesture that might not have opened
    /// anything.
    ///
    /// Both halves asserted together, not two tests: `open()` exists precisely because they
    /// are one event, and a version that marked read without fetching (or fetched without
    /// marking) would pass a test that only looked at its own half.
    func testOpeningASessionTellsTheMacItHasBeenLookedAtAndAsksForTheLatest() {
        let pager = StubPager()
        let model = model(pager)

        model.open()

        XCTAssertEqual(pager.marksRead, [session], "opening a session is what marks it read")
        XCTAssertEqual(pager.anchors, [.latest], "and it still asks for the conversation")
    }

    /// Coming back to a screen marks it again, and that is deliberate: a session that
    /// finished while the reader was elsewhere is unread again by then, and looking at it a
    /// second time is as much a look as the first. The Mac collapses a mark for a session
    /// that is already read — `setUnread` returns early on an unchanged flag — so the cost of
    /// being wrong in this direction is one frame, against a row that stays bold forever if
    /// this only ever fired once.
    func testComingBackToASessionMarksItReadAgainRatherThanOnlyTheFirstTime() {
        let pager = StubPager()
        let model = model(pager)

        model.open()
        pager.answer(tail())
        model.open()

        XCTAssertEqual(pager.marksRead, [session, session])
    }

    func testOpeningASessionAsksForTheLatestAndSpinsUntilThePageLands() {
        let pager = StubPager()
        let model = model(pager)

        model.loadLatest()

        XCTAssertEqual(pager.anchors, [.latest], "nothing is held, so there is no cursor")
        XCTAssertEqual(model.phase, .loading, "an empty screen with a fetch running says so")

        pager.answer(tail())

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.feed.items.map(\.body.text), ["first", "second"])
        XCTAssertEqual(model.feed.olderAnchor, .before(1000),
                       "the page's own start, not the first item's offset")
    }

    func testASecondFetchWhileOneIsStillRunningIsRefused() {
        let pager = StubPager()
        let model = model(pager)

        model.loadLatest()
        model.loadLatest()
        model.loadNewer()

        XCTAssertEqual(pager.requests.count, 1,
                       "two fetches from the same cursor would re-fetch the same page")
    }

    /// The trap this whole model is arranged around. `TimelineFeed` orders by file position
    /// and dedupes, but its invariant is *not* contiguity — a `.latest` page merged over a
    /// feed that already holds an older range leaves a hole in the middle that nothing can
    /// see and nothing can close. Coming back to a kept model must therefore ask for what is
    /// new, from the newest boundary held.
    func testComingBackToALoadedSessionAsksForWhatIsNewRatherThanForTheLatestAgain() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.loadLatest()

        XCTAssertEqual(pager.anchors, [.latest, .after(1200)],
                       "a second .latest here is a silent gap in the middle of a conversation")
        XCTAssertNotEqual(pager.anchors.last, .after(1090),
                          "the page's own end, not the last item's offset")
    }

    // MARK: A resumed link

    /// **The guard `linkResumed()` exists for.** `FleetModel.timelineModels` is never evicted
    /// short of `unpair()`, so a reader who has opened ten sessions and moved on holds ten
    /// live models — and `FleetModel` tells every one of them a link resumed, with no idea
    /// which of them, if any, is on screen. A model that fetched unconditionally would turn
    /// one reconnect into a burst of requests for conversations nobody is looking at, and a
    /// screen the reader never returns to would keep polling a Mac for no reader at all. A
    /// fresh model has never been told `viewing(true)`, so this is the ordinary case for most
    /// of the ten, not an edge case for one.
    func testAModelThatIsNotOnScreenIgnoresAResumedLink() {
        let pager = StubPager()
        let model = model(pager)

        model.linkResumed()

        XCTAssertEqual(pager.requests.count, 0, "nothing here is on screen to refresh")
        XCTAssertTrue(pager.viewingReports.isEmpty, "and no presence report for a session no one is viewing")
    }

    /// **The fix itself.** A session on screen when the phone slept comes back to a link that
    /// answers with a replay the `.onChange` triggers cannot see — same `activity`, same
    /// `call`, sometimes literally `.replay([])` — so nothing else in the model reacts to the
    /// reconnect at all. `linkResumed()` is the one path that does not wait for a value to
    /// change: it re-sends presence, because the new socket carries none of the old one's
    /// state and the Mac's badge would otherwise sit wrong until an appear/disappear a sleep
    /// never produces, and it fetches forward from the boundary the feed already holds.
    ///
    /// **The anchor is asserted specifically, not just the request count.** `.after(1200)` is
    /// the fix; `.latest` is the regression this whole feature exists to avoid — merging a
    /// `.latest` page over a feed that already holds this range would leave an invisible hole
    /// between the loaded tail and whatever the Mac sends back, which is exactly the defect
    /// `loadNewer()`'s own doc comment (and `testComingBackToALoadedSessionAsksForWhatIsNewRatherThanForTheLatestAgain`
    /// above) is about.
    func testAModelOnScreenReassertsPresenceAndFetchesForward() {
        let pager = StubPager()
        let model = model(pager)
        model.viewing(true)
        model.loadLatest()
        pager.answer(tail())

        model.linkResumed()

        XCTAssertEqual(pager.requests.count, 2, "the initial load, then exactly one more for the resume")
        XCTAssertEqual(pager.anchors.last, .after(1200),
                       "forward from the held boundary — a .latest here reopens the mid-feed hole")
        XCTAssertEqual(pager.viewingReports.last, session,
                       "the new link carries none of the old one's presence state")
    }

    /// **The other half of the guard.** A reader who leaves a session mid-read and goes back
    /// to the fleet list calls `viewing(false)` on the way out (`SessionTimelineScreen`'s
    /// `.onDisappear`), and the model is still one of the ten `timelineModels` keeps forever.
    /// A resume must not treat "was on screen a minute ago" as "is on screen now" — that is
    /// the same over-fetch `testAModelThatIsNotOnScreenIgnoresAResumedLink` guards, reached
    /// by a different route, so both are asserted rather than assuming one implies the other.
    func testLeavingTheScreenStopsAResumedLinkFromFetching() {
        let pager = StubPager()
        let model = model(pager)
        model.viewing(true)
        model.viewing(false)

        model.linkResumed()

        XCTAssertEqual(pager.requests.count, 0, "the reader left before the link came back")
    }

    // MARK: Paging up

    /// `olderAnchor` is non-nil at the top of history too — the feed still has a perfectly
    /// good `oldest` — so `hasOlder` is the only thing that stops the fetch. A model that
    /// checked the cursor alone would re-request the first page forever, and now that the
    /// fetch is automatic there is no tap rationing it: it would spin on the first page for
    /// the life of the screen.
    func testPagingUpStopsAtTheTopOfHistoryEvenThoughTheCursorIsStillThere() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail(hasMore: false))
        XCTAssertNotNil(model.feed.olderAnchor, "the premise: there is still a cursor")
        XCTAssertFalse(model.feed.hasOlder)

        model.prefetchOlder()

        XCTAssertEqual(pager.requests.count, 1, "the top of the transcript was already reached")
        XCTAssertFalse(model.isLoadingOlder, "and no spinner is left at the top")
    }

    func testPagingUpAsksFromThePagesOwnStartAndNotFromTheFirstItemsOffset() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.prefetchOlder()

        XCTAssertEqual(pager.anchors.last, .before(1000),
                       "1040 is where the first record is; 1000 is where the page began, and "
                           + "the record behind the boundary is lost by asking for the former")
        XCTAssertTrue(model.isLoadingOlder, "the top shows a spinner while this runs")
        XCTAssertEqual(model.phase, .idle, "and the screen full of content is not replaced")

        pager.answer(page([item(240, "earlier")], start: 200, end: 1000, hasMore: false))

        XCTAssertFalse(model.isLoadingOlder)
        XCTAssertEqual(model.feed.items.map(\.body.text), ["earlier", "first", "second"])
        XCTAssertFalse(model.feed.hasOlder, "and the top goes quiet")
    }

    /// **The runway, and it is the whole point of the prefetch.** One page behind the reader
    /// is not a buffer: a page is 40 records, a flick covers that, and the reader lands on a
    /// spinner — which is the "Load earlier" wait under a different name. So a trigger pulls
    /// `prefetchPages` of them, each anchored on the last one's own `start`, without waiting
    /// to be asked again.
    func testNearingTheTopPullsAWholeRunwayRatherThanTheOnePageATapUsedTo() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.prefetchOlder()
        pager.answer(page([item(940, "p1")], start: 900, end: 1000, hasMore: true))
        pager.answer(page([item(840, "p2")], start: 800, end: 900, hasMore: true))
        pager.answer(page([item(740, "p3")], start: 700, end: 800, hasMore: true))

        XCTAssertEqual(pager.anchors,
                       [.latest, .before(1000), .before(900), .before(800)],
                       "each page is asked for from the one before it, three deep")
        XCTAssertEqual(pager.requests.count, 4,
                       "and the run stops at \(SessionTimelineModel.prefetchPages) rather "
                           + "than reading the whole transcript on one trigger")
        XCTAssertFalse(model.isLoadingOlder)
        XCTAssertEqual(model.phase, .idle, "none of it is a screen state")
    }

    /// The runway is a ceiling, not a quota: a conversation with two pages of history left
    /// stops after two. Without this the third request asks `.before` a cursor at the top of
    /// the file, and the Mac answers an empty page forever.
    func testTheRunwayStopsAtTheBeginningRatherThanAskingPastIt() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.prefetchOlder()
        pager.answer(page([item(940, "p1")], start: 900, end: 1000, hasMore: true))
        pager.answer(page([item(840, "p2")], start: 800, end: 900, hasMore: false))

        XCTAssertEqual(pager.requests.count, 3, "the beginning is the beginning")
        XCTAssertFalse(model.feed.hasOlder)
        XCTAssertFalse(model.isLoadingOlder)
    }

    /// **A prefetch nobody asked for must not take the conversation away.** It runs on a
    /// scroll rather than on a tap, so treating its failure the way a reader-triggered fetch
    /// is treated would replace a screen full of history with an error message because the
    /// phone lost its link while somebody was reading. The reason goes at the top, where the
    /// missing history is, and `phase` never hears about it.
    func testAPrefetchThatFailsSaysSoAtTheTopAndLeavesTheConversationOnScreen() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.prefetchOlder()
        pager.answer(.failure(.disconnected))

        XCTAssertEqual(model.phase, .idle, "the history on screen is still the truth")
        XCTAssertEqual(model.feed.items.map(\.body.text), ["first", "second"],
                       "and it is still there")
        XCTAssertEqual(model.olderFailure, "Not connected to your Mac.")
        XCTAssertFalse(model.isLoadingOlder, "the spinner stops, or it is a spinner with no end")
    }

    /// The retry, and it is why no button came back. `onAppear` fires once for a row that is
    /// already on screen, so a failed prefetch would strand a reader at the top of what the
    /// phone managed to load with nothing to touch. The screen re-arms this on the reader's
    /// own scroll — see `SessionTimelineScreen.prefetchTrigger` — and the second attempt has
    /// to be a real request, not a refusal from a model still holding the first one's state.
    func testAFailedPrefetchIsAskedForAgainRatherThanStrandingTheReaderAtTheTop() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())
        model.prefetchOlder()
        pager.answer(.failure(.disconnected))

        model.prefetchOlder()

        XCTAssertEqual(pager.anchors.last, .before(1000), "it asks again, from the same cursor")
        XCTAssertNil(model.olderFailure,
                     "and the reason for the last attempt goes with the new one")

        pager.answer(page([item(240, "earlier")], start: 200, end: 1000, hasMore: false))

        XCTAssertEqual(model.feed.items.map(\.body.text), ["earlier", "first", "second"])
        XCTAssertNil(model.olderFailure)
    }

    // MARK: Reaching the live edge

    /// A page is capped at 40 records, so a screen returned to after a long turn is several
    /// pages behind the end. Stopping at the first page shows a conversation that ends in the
    /// middle with nothing on screen to say it does — there is no "load newer" affordance,
    /// and the poll only runs while the session is busy.
    func testAPageShortOfTheLiveEdgeIsChasedRatherThanLeavingTheConversationCutOff() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())
        model.loadNewer()

        pager.answer(page([item(1240, "third")], start: 1200, end: 1400, hasMore: true))

        XCTAssertEqual(pager.anchors, [.latest, .after(1200), .after(1400)],
                       "the Mac said there was more after 1400 was read")

        pager.answer(page([item(1440, "fourth")], start: 1400, end: 1600, hasMore: false))

        XCTAssertEqual(pager.requests.count, 3, "and the chase stops at the live edge")
        XCTAssertEqual(model.feed.items.map(\.body.text),
                       ["first", "second", "third", "fourth"])
        XCTAssertEqual(model.phase, .idle)
    }

    /// `hasMore` means opposite ends of the file in the two directions: on a `.latest` or a
    /// `.before` page it reports what precedes `start`, because `TimelineReader` budgets those
    /// from their oldest end. Chasing one would fetch forwards on the strength of a fact about
    /// history — every opening fetch, on every session with more than one page of it.
    func testAPageFetchedBackwardsIsNeverChasedForwards() {
        let pager = StubPager()
        let model = model(pager)

        model.loadLatest()
        pager.answer(tail(hasMore: true))

        XCTAssertEqual(pager.requests.count, 1,
                       "hasMore on a .latest page is about older records, not newer ones")

        model.prefetchOlder()
        pager.answer(page([item(240, "earlier")], start: 200, end: 1000, hasMore: true))

        XCTAssertEqual(pager.anchors.last, .before(200),
                       "the runway keeps reading BACKWARDS on that hasMore, which is what it "
                           + "is a fact about — it must never turn into a forward fetch")
    }

    /// **The live edge must not be starved by the runway.** Every fetch shares one `inFlight`
    /// slot, and a prefetch now runs on a scroll rather than on a tap — so the fetch that
    /// follows a live turn, and the one that confirms a sent message reached the agent, are
    /// suddenly competing with three background reads. Dropped, they would leave the
    /// conversation ending in the middle and an outbox row claiming a message never landed.
    /// So a forward fetch refused by a running prefetch is re-issued when the slot frees.
    func testAFetchOfTheLiveEdgeRefusedByARunningPrefetchIsReissuedRatherThanLost() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())
        model.prefetchOlder()
        XCTAssertTrue(model.isLoadingOlder, "the premise: the slot is held by the runway")

        model.loadNewer()

        XCTAssertEqual(pager.anchors, [.latest, .before(1000)],
                       "it cannot go out yet — one fetch at a time")

        pager.answer(page([item(940, "p1")], start: 900, end: 1000, hasMore: false))

        XCTAssertEqual(pager.anchors.last, .after(1200),
                       "and the moment the runway is done it goes out, from the newest cursor")
    }

    // MARK: A session that has not started

    /// **A brand-new session is not a broken one.** The Mac answers `unreadable` for a tab
    /// whose agent has not written a transcript yet — which is every session between being
    /// created and taking its first turn — and routing that into `.failed` put a warning and
    /// a "Try again" button on a screen where nothing had gone wrong and retrying fixes
    /// nothing. What clears this state is the agent taking a turn, not the reader pressing
    /// a button.
    func testASessionThatHasNotTakenATurnIsNotAFailure() {
        let pager = StubPager()
        let model = model(pager)

        model.loadLatest()
        pager.answer(.failure(.server(code: "unreadable")))

        XCTAssertEqual(model.phase, .notStarted)
    }

    /// The recovery is the ordinary one and must still work: the reader sends a message, the
    /// agent takes its turn, the next fetch finds a transcript. Nothing about `.notStarted`
    /// may latch.
    func testASessionThatStartsLaterFillsInLikeAnyOther() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(.failure(.server(code: "unreadable")))
        XCTAssertEqual(model.phase, .notStarted, "the premise")

        model.loadLatest()
        pager.answer(tail())

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.feed.items.map(\.body.text), ["first", "second"])
    }

    /// **Only on an empty screen.** `unreadable` arriving over a conversation the phone has
    /// already read means something different — a transcript that was there and cannot be read
    /// now — and quietly calling that "not started yet" would tell the reader their session
    /// never began while its own history sits above the message.
    func testUnreadableOverAConversationAlreadyOnScreenIsStillAFailure() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.loadLatest()
        pager.answer(.failure(.server(code: "unreadable")))

        guard case .failed = model.phase else {
            return XCTFail("expected a failure, got \(model.phase)")
        }
    }

    // MARK: Failure

    func testEachRefusalGetsCopyThatSaysWhatToDoAboutIt() {
        let messages = [
            FleetRequestError.disconnected,
            .server(code: "unknown_session"),
            .server(code: "no_transcript"),
            .server(code: "wedged"),
        ].map { error -> String in
            let pager = StubPager()
            let model = model(pager)
            model.loadLatest()
            pager.answer(.failure(error))
            guard case .failed(let message) = model.phase else {
                XCTFail("\(error) left the screen in \(model.phase)")
                return ""
            }
            return message
        }

        XCTAssertEqual(messages[0], "Not connected to your Mac.")
        XCTAssertEqual(messages[1], "This session is no longer open on your Mac.")
        XCTAssertEqual(messages[2],
                       "This agent doesn't keep a transcript, so there's nothing to show.")
        XCTAssertEqual(
            SessionTimelineModel.message(for: .server(code: "unreadable")),
            "Nothing here yet — this session hasn't taken its first turn.",
            "the copy still exists; what changed is that it is no longer reached through "
                + "`phase`, because it never described a failure"
        )
        XCTAssertEqual(messages[3], "Your Mac couldn't read this session (wedged).",
                       "an unrecognised code must carry the code, not become a shrug")
        XCTAssertEqual(Set(messages).count, 4, "each refusal gets its own words: \(messages)")
    }

    /// A background poll that fails must not replace a screen full of conversation with an
    /// error: the content is still the last thing the Mac said, and the fleet list's own
    /// banner already says the phone is offline.
    func testAPollThatFailsLeavesTheConversationOnScreen() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())

        model.loadNewer()
        pager.answer(.failure(.disconnected))

        XCTAssertEqual(model.phase, .idle, "a failed poll is not a screenful of error")
        XCTAssertEqual(model.feed.items.map(\.body.text), ["first", "second"])

        model.loadNewer()
        XCTAssertEqual(pager.requests.count, 3, "and the next poll still runs")
    }

    /// The other half of the same rule: the *first* fetch is loud however it was triggered,
    /// because an empty screen has nothing to fall back on and a silent refusal there is a
    /// blank page with no explanation.
    func testTheFirstFetchIsLoudEvenWhenAPollTriggersIt() {
        let pager = StubPager()
        let model = model(pager)

        model.loadNewer()

        XCTAssertEqual(pager.anchors, [.latest])
        XCTAssertEqual(model.phase, .loading)

        pager.answer(.failure(.server(code: "unknown_session")))

        XCTAssertEqual(model.phase, .failed("This session is no longer open on your Mac."))
    }

    /// `FleetConnector.request(_:then:)` answers `.disconnected` **synchronously**, so this
    /// completion runs inside the frame that started the fetch, before `fetch` has returned.
    /// The state it clears has to be state that was already set.
    func testARefusalDeliveredBeforeTheRequestReturnsStillEndsTheFetch() {
        let pager = StubPager()
        pager.answerBeforeReturning = .failure(.disconnected)
        let model = model(pager)

        model.loadLatest()

        XCTAssertEqual(model.phase, .failed("Not connected to your Mac."))

        model.loadLatest()

        XCTAssertEqual(pager.requests.count, 2,
                       "the in-flight gate must have been released by the synchronous answer")
    }

    // MARK: The deadline

    /// **Nothing else in this stack has a timeout.** Delivery is exactly-once only because
    /// the socket eventually reports an error, and on a half-open connection it does not:
    /// `FleetClient` and `FleetConnector` run no liveness timer, so a request can sit for the
    /// TCP retransmit horizon. Without a deadline here that is a spinner with no end — and a
    /// permanently closed gate, so nothing the screen does afterwards asks for anything ever
    /// again.
    func testAFetchNobodyAnswersFailsOnItsOwnDeadlineInsteadOfSpinningForever() async {
        let pager = StubPager()
        let model = model(pager, timeout: .milliseconds(50))

        model.loadLatest()
        XCTAssertEqual(model.phase, .loading)

        await settle(until: { model.phase != .loading }, "the deadline to fire")

        XCTAssertEqual(model.phase, .failed("Your Mac didn't answer in time."))

        model.loadLatest()
        XCTAssertEqual(pager.requests.count, 2, "and the screen can ask again")
    }

    /// The other half of the deadline: the socket may still answer afterwards — a drained
    /// `pending` table delivers `.disconnected` late, and a slow page simply arrives. That
    /// answer belongs to a fetch nobody is waiting on, so it must not touch anything. If it
    /// did, the late answer to a dead request would open the gate on the live one and two
    /// fetches computed from the same cursor would run at once.
    func testAnAnswerThatArrivesAfterItsDeadlineChangesNothing() async {
        let pager = StubPager()
        let model = model(pager, timeout: .milliseconds(50))
        model.loadLatest()
        await settle(until: { model.phase != .loading }, "the deadline to fire")

        // A second fetch, live, with the first one's completion still sitting in the stub the
        // way it sits in a drained `pending` table.
        model.loadLatest()
        XCTAssertEqual(pager.requests.count, 2)
        XCTAssertEqual(model.phase, .loading)

        pager.answer(tail())

        XCTAssertTrue(model.feed.items.isEmpty,
                      "that page answered the first fetch, which timed out and is gone")
        XCTAssertEqual(model.phase, .loading, "and the live fetch's spinner is untouched")
        XCTAssertTrue(pager.isWaiting, "the live fetch is still outstanding")

        model.loadLatest()
        XCTAssertEqual(pager.requests.count, 2, "and its gate is still closed")
    }

    /// A quiet fetch that times out stays quiet, for the same reason a quiet one that fails
    /// does: the screen still holds the last thing the Mac said.
    func testAPollThatTimesOutDoesNotReplaceTheConversationWithAnError() async {
        let pager = StubPager()
        let model = model(pager, timeout: .milliseconds(50))
        model.loadLatest()
        pager.answer(tail())
        model.loadNewer()
        XCTAssertTrue(pager.isWaiting)

        // The poll is what notices. It re-fires every 1.5s in the app and is refused while
        // the gate is closed, so a third request landing IS the deadline releasing it —
        // which is a fact about the model rather than about how long this test slept.
        await settle(until: {
            model.loadNewer()
            return pager.requests.count == 3
        }, "the deadline to release the poll's gate")

        XCTAssertEqual(model.phase, .idle, "a poll that timed out says nothing on screen")
        XCTAssertEqual(model.feed.items.map(\.body.text), ["first", "second"])
    }

    // MARK: Reset

    /// Item ids are byte offsets, so a replaced transcript makes every id the feed holds name
    /// a different record. The feed discards itself; this has to fetch again from the end, or
    /// the screen is left blank with nothing that will ever fill it.
    func testAResetPageDiscardsWhatIsHeldAndStartsAgainFromTheLatest() {
        let pager = StubPager()
        let model = model(pager)
        model.loadLatest()
        pager.answer(tail())
        model.loadNewer()

        pager.answer(page([], start: 60, end: 60, reset: true))

        XCTAssertTrue(model.feed.items.isEmpty, "the transcript those offsets came from is gone")
        XCTAssertEqual(pager.anchors, [.latest, .after(1200), .latest],
                       "and the screen starts again from the end rather than staying blank")

        pager.answer(page([item(40, "new file")], start: 0, end: 200))

        XCTAssertEqual(model.feed.items.map(\.body.text), ["new file"])
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: A search jump

    /// `openAt` is a one-shot instruction for the very next `open()`, not an ordinary cursor:
    /// the fleet list sets it just before pushing a session a search hit opened, and this is
    /// the fetch that must land on the hit rather than at the live edge.
    func testOpenAtLandsTheNextOpenOnAnAroundFetchRatherThanTheLatest() {
        let pager = StubPager()
        let model = model(pager)

        model.openAt(1090)
        model.open()

        XCTAssertEqual(pager.marksRead, [session], "a search jump is still a look at the session")
        XCTAssertEqual(pager.anchors, [.around(1090)])
    }

    /// The instruction is consumed once. A screen kept alive and reopened later — the reader
    /// backing out and back in — must fall through to the ordinary `open()` path rather than
    /// jumping to the same line again on every return.
    func testOpenAtOnlyAppliesToTheOneOpenItWasSetBefore() {
        let pager = StubPager()
        let model = model(pager)
        model.openAt(1090)
        model.open()
        pager.answer(tail())

        model.open()

        XCTAssertEqual(pager.anchors, [.around(1090), .after(1200)],
                       "the second open is an ordinary return, not a second jump")
    }

    /// What a search jump is FOR: the page it asked for lands, and the screen learns which row
    /// to scroll to and flash.
    func testAnAroundFetchLandingSetsTheScrollTargetToTheMatchingItem() {
        let pager = StubPager()
        let model = model(pager)
        model.openAt(1090)

        model.open()
        pager.answer(tail())

        XCTAssertEqual(model.scrollTarget, "1090#0")
    }

    /// **The old-Mac fallback.** A Mac that predates `.around` cannot decode it and answers
    /// `unsupported` rather than dropping the socket — see `FleetSocketServer.onUndecodable`.
    /// That must read as "no scroll", not as a failure: the conversation still opens, at the
    /// live edge, exactly as it would have without a search hit at all.
    func testAnUnsupportedAroundFetchFallsBackToTheLiveEdgeWithoutSurfacingAsAnError() {
        let pager = StubPager()
        let model = model(pager)
        model.openAt(1090)
        model.open()

        pager.answer(.failure(.server(code: "unsupported")))

        XCTAssertEqual(pager.anchors, [.around(1090), .latest],
                       "the refusal itself falls back to the live edge, unasked")
        XCTAssertEqual(model.phase, .loading, "the fallback is a fetch in flight, not a failure")

        pager.answer(tail())

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.feed.items.map(\.body.text), ["first", "second"],
                       "the conversation still opens")
        XCTAssertNil(model.scrollTarget, "there was nothing to scroll to on a fallback page")
    }

    /// The fallback is specific to `.around` refused as `unsupported` — not to every failure a
    /// search jump's fetch can hit. A disconnected phone still says so, the ordinary way.
    func testAnAroundFetchRefusedForAnyOtherReasonFailsOrdinarilyRatherThanFallingBack() {
        let pager = StubPager()
        let model = model(pager)
        model.openAt(1090)
        model.open()

        pager.answer(.failure(.disconnected))

        XCTAssertEqual(pager.anchors, [.around(1090)], "no fallback fetch went out")
        XCTAssertEqual(model.phase, .failed("Not connected to your Mac."))
    }

    /// Nor is `unsupported` special on its own — only paired with the anchor it names. An
    /// ordinary `.latest` fetch refused with the same code is just an unrecognised refusal,
    /// carrying its code rather than silently retrying.
    func testAnUnsupportedRefusalOnAnOrdinaryFetchDoesNotTriggerTheFallback() {
        let pager = StubPager()
        let model = model(pager)

        model.loadLatest()
        pager.answer(.failure(.server(code: "unsupported")))

        XCTAssertEqual(pager.anchors, [.latest], "nothing was retried")
        XCTAssertEqual(model.phase, .failed("Your Mac couldn't read this session (unsupported)."))
    }

    /// `TranscriptExtractor` only indexes text content, so a search hit's offset always lands
    /// on a `.userTurn` or `.assistantText` item — but a record can still yield several items
    /// at one offset (a wrapped user turn's harness notices sit beside the reader's own words).
    /// The text item among them is what a search jump meant to land on.
    func testHighlightTargetPrefersTheTextItemAmongSeveralSharingAnOffset() {
        let items = [
            item(500, index: 0, kind: .toolCall, "notice"),
            item(500, index: 1, kind: .userTurn, "the actual words"),
            item(500, index: 2, kind: .toolResult, "result"),
        ]

        XCTAssertEqual(SessionTimelineModel.highlightTarget(offset: 500, in: items), "500#1")
    }

    /// Falls back to whatever shares the offset when none of it is a text item, rather than to
    /// nothing: a page that has the offset at all should still land somewhere close to what was
    /// searched, not miss the jump entirely over a kind mismatch.
    func testHighlightTargetFallsBackToAnyItemAtTheOffsetWhenNoneIsText() {
        let items = [
            item(500, index: 0, kind: .toolCall, "notice"),
            item(500, index: 1, kind: .toolResult, "result"),
        ]

        XCTAssertEqual(SessionTimelineModel.highlightTarget(offset: 500, in: items), "500#0")
    }

    /// The offset the search hit named simply is not on the page that landed — a possibility
    /// worth naming explicitly rather than leaving `nil` to mean it by accident.
    func testHighlightTargetIsNilWhenThePageDoesNotHoldTheOffsetAtAll() {
        let items = [item(1040, "first"), item(1090, "second")]

        XCTAssertNil(SessionTimelineModel.highlightTarget(offset: 240, in: items))
    }
}
