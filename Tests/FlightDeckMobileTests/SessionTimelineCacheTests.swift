import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Answers each request when the test says so, like `SessionTimelineModelTests`' stub.
@MainActor
private final class CachePager: TimelinePaging, PromptSending, PromptAnswering, PresenceReporting {
    private(set) var anchors: [TimelineAnchor] = []
    private var pending: [(Result<TimelinePage, FleetRequestError>) -> Void] = []

    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        if case .timeline(_, let anchor, _, _) = request { anchors.append(anchor) }
        pending.append(completion)
    }
    func markRead(_ id: UUID) {}
    func viewing(_ session: UUID?) {}
    func sendPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}
    func answerPrompt(_ command: FleetCommand, then completion: @escaping (Result<Void, FleetRequestError>) -> Void) {}

    func answer(_ page: TimelinePage, line: UInt = #line) {
        guard !pending.isEmpty else { return XCTFail("nothing was asked for", line: line) }
        pending.removeFirst()(.success(page))
    }
}

/// A session's conversation kept on disk between launches: opened at once from the copy, then
/// only what is newer asked for — and thrown away whenever the copy cannot be trusted.
@MainActor
final class SessionTimelineCacheTests: XCTestCase {
    private let session = UUID()

    private func item(_ offset: Int, _ text: String) -> TimelineItem {
        TimelineItem(id: "\(offset)#0", kind: .assistantText, status: .complete,
                     body: TimelineItem.Body(text: text))
    }

    private func page(
        _ items: [TimelineItem], start: Int, end: Int, hasMore: Bool = false, source: String? = "S"
    ) -> TimelinePage {
        TimelinePage(session: session, items: items, start: start, end: end,
                     hasMore: hasMore, reset: false, source: source)
    }

    private func cache() -> PhoneCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-cache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return PhoneCache(directory: dir)
    }

    private func spill() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-\(UUID().uuidString)", isDirectory: true)
    }

    private func model(_ pager: CachePager, _ cache: PhoneCache) -> SessionTimelineModel {
        SessionTimelineModel(sessionID: session, fleet: pager, spillDirectory: spill(), cache: cache)
    }

    /// Loads a model, lands one page, and writes it — what a previous launch leaves behind.
    private func seed(_ cache: PhoneCache, source: String = "S") {
        let pager = CachePager()
        let first = model(pager, cache)
        first.open()
        pager.answer(page([item(1040, "first"), item(1090, "second")],
                          start: 1000, end: 1200, source: source))
        first.persist()
    }

    func testAReopenedSessionShowsItsCopyAndAsksOnlyForWhatIsNewer() {
        let cache = cache()
        seed(cache)
        let pager = CachePager()
        let reopened = model(pager, cache)
        XCTAssertEqual(reopened.feed.items.map(\.id), ["1040#0", "1090#0"], "on screen before any answer")
        reopened.open()
        XCTAssertEqual(pager.anchors, [.after(1200)])
        pager.answer(page([item(1210, "third")], start: 1200, end: 1300))
        XCTAssertEqual(reopened.feed.items.map(\.id), ["1040#0", "1090#0", "1210#0"])
    }

    /// The case `reset` cannot see: another file at the same tab, at least as long as the
    /// cursor. Merging would interleave two conversations under matching ids.
    func testADifferentTranscriptDiscardsTheCopy() {
        let cache = cache()
        seed(cache, source: "old")
        let pager = CachePager()
        let reopened = model(pager, cache)
        reopened.open()
        pager.answer(page([item(1210, "elsewhere")], start: 1200, end: 1300, source: "new"))
        XCTAssertTrue(reopened.feed.items.isEmpty, "nothing from the old file may survive")
        XCTAssertEqual(pager.anchors, [.after(1200), .latest])
        XCTAssertNil(cache.timeline(for: session))
    }

    /// A copy more than a page behind is replaced with one `.latest`, rather than chased
    /// forward a page per round trip across everything that happened while the phone was away.
    func testACopyFarBehindIsReplacedRatherThanChased() {
        let cache = cache()
        seed(cache)
        let pager = CachePager()
        let reopened = model(pager, cache)
        reopened.open()
        pager.answer(page([item(1210, "next")], start: 1200, end: 1300, hasMore: true))
        XCTAssertEqual(pager.anchors, [.after(1200), .latest])
        pager.answer(page([item(90_000, "now")], start: 89_000, end: 91_000, hasMore: true))
        XCTAssertEqual(reopened.feed.items.map(\.id), ["90000#0"], "no hole between the copy and the live edge")
    }

    /// Scrollback from a reopened copy: the older cursor survives the disk round trip, and a
    /// prefetch asked for while the first forward page is still out is issued once it lands.
    func testAReopenedCopyStillScrollsBack() {
        let cache = cache()
        let pager = CachePager()
        let first = model(pager, cache)
        first.open()
        pager.answer(page([item(1040, "first"), item(1090, "second")],
                          start: 1000, end: 1200, hasMore: true))
        first.persist()

        let again = CachePager()
        let reopened = model(again, cache)
        XCTAssertTrue(reopened.feed.hasOlder, "the copy must still know there is more above it")
        reopened.open()
        reopened.prefetchOlder()
        again.answer(page([], start: 1200, end: 1200))
        XCTAssertEqual(again.anchors, [.after(1200), .before(1000)])
        again.answer(page([item(900, "older")], start: 800, end: 1000, hasMore: true))
        XCTAssertEqual(reopened.feed.items.map(\.id), ["900#0", "1040#0", "1090#0"])
    }

    /// The same without a cache at all, so a failure above can be told from one in paging.
    func testAFreshSessionScrollsBack() {
        let pager = CachePager()
        let fresh = SessionTimelineModel(sessionID: session, fleet: pager, spillDirectory: spill())
        fresh.open()
        pager.answer(page([item(1040, "first")], start: 1000, end: 1200, hasMore: true))
        fresh.prefetchOlder()
        XCTAssertEqual(pager.anchors, [.latest, .before(1000)])
    }

    /// The launch kill: a 294-item copy, drawn before the first frame, got the app killed
    /// at every launch. A copy written larger than `cachedItems` — by an older build — comes
    /// back cut to it, newest end kept.
    func testAnOversizedCopyIsCutOnTheWayIn() {
        let cache = cache()
        var big = TimelineFeed()
        big.merge(page((0..<300).map { item(10_000 + $0 * 10, "row \($0)") },
                       start: 10_000, end: 13_000))
        cache.save(CachedTimeline(source: "S", feed: big, savedAt: Date()), for: session)
        let reopened = model(CachePager(), cache)
        XCTAssertEqual(reopened.feed.items.count, SessionTimelineModel.cachedItems)
        XCTAssertEqual(reopened.feed.items.last?.id, big.items.last?.id)
        XCTAssertTrue(reopened.feed.hasOlder, "the rest is still reachable by scrolling")
    }

    /// A Mac that sends no `source` cannot have its cursors checked later, so nothing is kept.
    func testNothingIsCachedWithoutASourceToken() {
        let cache = cache()
        let pager = CachePager()
        let first = model(pager, cache)
        first.open()
        pager.answer(page([item(1040, "first")], start: 1000, end: 1200, source: nil))
        first.persist()
        XCTAssertNil(cache.timeline(for: session))
    }
}

/// The fleet half: a cold launch opens on the cached list, labelled as cached, and a revoked
/// pairing takes the cache with it.
@MainActor
final class FleetModelCacheTests: XCTestCase {
    func testAColdLaunchOpensOnTheCachedFleetAndUnpairingForgetsIt() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-cache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cache = PhoneCache(directory: dir)
        let mac = PairedMac(key: .mint(), macName: "Mac", serviceName: "svc-\(UUID().uuidString)",
                            endpoints: [])
        let store = InMemoryPairedMacStore()
        store.save(mac)
        let fleet = FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [
                WireSession(id: UUID(), title: "cached", agent: "claude")
            ])
        ])
        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        cache.save(CachedFleet(mac: mac.serviceName, epoch: "E", seq: 7, fleet: fleet, savedAt: savedAt))

        let model = FleetModel(store: store, cache: cache)
        XCTAssertEqual(model.fleet, fleet, "on screen before the Mac has said anything")
        XCTAssertTrue(model.isShowingCache)
        XCTAssertEqual(model.lastLive, savedAt, "a restored list must say how old it is")

        model.unpair()
        XCTAssertNil(cache.fleet(for: mac.serviceName))
    }
}
