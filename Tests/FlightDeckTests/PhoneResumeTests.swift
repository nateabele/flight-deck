import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// The phone's fast cold launch: a fleet and feeds kept on disk, and a resume point the Mac can
/// check across its own restarts. Each test names the failure it prevents.
@MainActor
final class PhoneResumeTests: XCTestCase {
    private let sessionID = UUID()
    private let projectID = UUID()

    private func fleet(_ title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd", sessions: [
                WireSession(id: sessionID, title: title, agent: "claude")
            ])
        ])
    }

    // MARK: The Mac's epoch

    /// The hole the epoch closes: a cursor from yesterday's run that is numerically inside
    /// today's ring used to be replayed today's events onto yesterday's fleet.
    func testACursorFromAnotherRunIsSnapshottedEvenWhenItsNumberIsInRange() {
        var log = FleetEventLog(capacity: 64, mirror: fleet("a"), epoch: "today")
        _ = log.append((0..<10).map { .renamed(id: sessionID, title: "t\($0)", origin: .user) })
        XCTAssertEqual(log.resume(from: 5, epoch: "yesterday"), .resnapshot(.seqTooOld))
        guard case .replay(let events) = log.resume(from: 5, epoch: "today") else {
            return XCTFail("a cursor from this run inside the ring must replay")
        }
        XCTAssertEqual(events.last?.seq, 10)
    }

    /// A client that claims no epoch — every phone in the field, and `flightdeck tail --since`
    /// — keeps exactly the judgement it always had.
    func testAClientClaimingNoEpochIsJudgedOnTheNumberAlone() {
        var log = FleetEventLog(capacity: 64, mirror: fleet("a"), epoch: "today")
        _ = log.append([.renamed(id: sessionID, title: "b", origin: .user)])
        XCTAssertEqual(log.resume(from: 1, epoch: nil), .replay([]))
        XCTAssertEqual(log.resume(from: 0, epoch: "today"), .resnapshot(.initial))
    }

    /// Copies of the log (the socket queue's) and a reset keep the epoch: only a new run mints
    /// one, or every phone would be re-snapshotted on the socket copy's first resync.
    func testTheEpochSurvivesCopiesAndResets() {
        var log = FleetEventLog(capacity: 64, mirror: fleet("a"))
        let copy = log
        log.reset(mirror: fleet("b"))
        XCTAssertEqual(copy.epoch, log.epoch)
        XCTAssertNotEqual(FleetEventLog(capacity: 1, mirror: .empty).epoch, log.epoch)
    }

    // MARK: Frames

    func testHelloCarriesItsEpochAndOmitsItWhenThereIsNone() throws {
        let with = ClientFrame.hello(lastSeq: 7, device: nil, epoch: "E")
        XCTAssertEqual(try JSONDecoder().decode(ClientFrame.self, from: JSONEncoder().encode(with)), with)
        let without = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ClientFrame.hello(lastSeq: 0, device: nil))
        ) as? [String: Any]
        XCTAssertNil(without?["epoch"], "a client resuming nothing must send the bytes it always did")
    }

    func testSnapshotEpochAndCaughtUpRoundTrip() throws {
        for frame: ServerFrame in [
            .snapshot(seq: 3, fleet: fleet("a"), reason: .initial, epoch: "E"),
            .snapshot(seq: 3, fleet: fleet("a"), reason: .initial),
            .caughtUp,
        ] {
            XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame)), frame)
        }
    }

    // MARK: The connector

    /// The bug `caughtUp` fixes: a resume with nothing to replay sent no frame at all, so the
    /// connector never picked a winner and redialled every `raceTimeout`. And the resume point
    /// a restored connector dials with is the one it was handed — sequence and epoch together.
    func testARestoredConnectorResumesAndConnectsOnAnEmptyReplay() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        var claimed: (seq: Int, epoch: String?, caps: Set<String>)?
        server.onHello = { attachment, lastSeq in
            claimed = (lastSeq, attachment.epoch, attachment.caps)
            return attachment.caps.contains(FleetCapability.caughtUp) ? [.caughtUp] : []
        }
        defer { server.stop() }
        let port = try await server.start(keys: [key], port: nil)
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"]
        )
        let connector = FleetConnector(mac: mac, store: InMemoryPairedMacStore(), browse: false)
        defer { connector.stop() }
        connector.restore(fleet: fleet("cached"), seq: 41, epoch: "E1")
        let connected = expectation(description: "connected")
        connector.onState = { if case .connected = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(claimed?.seq, 41)
        XCTAssertEqual(claimed?.epoch, "E1")
        XCTAssertEqual(connector.resumePoint.seq, 41)
        XCTAssertEqual(connector.resumePoint.epoch, "E1")
    }

    /// A snapshot replaces the epoch along with the fleet — including with nil, so a
    /// downgraded Mac is never handed a cursor vouched for by the newer build's epoch.
    func testASnapshotSetsTheEpochTheNextHelloClaims() async throws {
        let key = FleetDeviceKey.mint()
        let server = FleetSocketServer()
        server.onHello = { _, _ in [.snapshot(seq: 9, fleet: self.fleet("live"), reason: .seqTooOld, epoch: "E2")] }
        defer { server.stop() }
        let port = try await server.start(keys: [key], port: nil)
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"]
        )
        let connector = FleetConnector(mac: mac, store: InMemoryPairedMacStore(), browse: false)
        defer { connector.stop() }
        connector.restore(fleet: fleet("cached"), seq: 41, epoch: "E1")
        let got = expectation(description: "fleet")
        var seen: FleetSnapshot?
        connector.onFleet = { seen = $0; got.fulfill() }
        connector.start()
        await fulfillment(of: [got], timeout: 20)
        XCTAssertEqual(seen, fleet("live"))
        XCTAssertEqual(connector.resumePoint.seq, 9)
        XCTAssertEqual(connector.resumePoint.epoch, "E2")
    }

    // MARK: Caching a feed

    private func item(_ offset: Int, _ index: Int = 0, _ text: String = "x", placeholder: Bool = false) -> TimelineItem {
        TimelineItem(
            id: TimelineItem.identifier(offset: offset, index: index), kind: .assistantText,
            status: .complete, body: .init(text: text, isPlaceholder: placeholder)
        )
    }

    private func feed(_ items: [TimelineItem], start: Int, end: Int, hasMore: Bool = false) -> TimelineFeed {
        var feed = TimelineFeed()
        feed.merge(TimelinePage(session: sessionID, items: items, start: start, end: end,
                                hasMore: hasMore, reset: false))
        return feed
    }

    func testASmallFeedIsCachedWhole() {
        let whole = feed([item(10), item(20)], start: 5, end: 30, hasMore: true)
        XCTAssertEqual(whole.cacheable(maxItems: 10, maxBytes: 1_000), whole)
    }

    /// Cut at a record, never inside one, and the new top cursor is that record's own offset,
    /// with older history admitted to exist.
    func testALongFeedIsCutAtARecordBoundary() {
        let long = feed([item(10), item(20, 0), item(20, 1), item(30)], start: 0, end: 40)
        let cut = long.cacheable(maxItems: 2, maxBytes: 1_000)
        XCTAssertEqual(cut?.items.map(\.id), ["30#0"], "a record's items are kept together or not at all")
        XCTAssertEqual(cut?.olderAnchor, .before(30))
        XCTAssertEqual(cut?.newerAnchor, .after(40))
        XCTAssertEqual(cut?.hasOlder, true)
    }

    /// A spilled body may not exist on disk by the time the cache is read, so it — and
    /// everything older, or the feed would have a hole — stays out.
    func testASpilledPlaceholderEndsTheCut() {
        var long = feed([item(10), item(20), item(30)], start: 0, end: 40)
        long.spill(["20#0"])
        XCTAssertEqual(long.cacheable(maxItems: 10, maxBytes: 1_000)?.items.map(\.id), ["30#0"])
        long.spill(["30#0"])
        XCTAssertNil(long.cacheable(maxItems: 10, maxBytes: 1_000))
    }

    /// The newest record is kept however large, so a session ending in one huge result still
    /// opens on it.
    func testTheNewestRecordIsKeptPastTheByteBudget() {
        let big = feed([item(10), item(20, 0, String(repeating: "y", count: 500))], start: 0, end: 30)
        XCTAssertEqual(big.cacheable(maxItems: 10, maxBytes: 100)?.items.map(\.id), ["20#0"])
    }

    // MARK: The disk cache

    private func temporaryCache() -> PhoneCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneResumeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return PhoneCache(directory: dir)
    }

    func testTheFleetRoundTripsOnlyForItsOwnMac() {
        let cache = temporaryCache()
        let saved = CachedFleet(mac: "mac-a", epoch: "E", seq: 12, fleet: fleet("a"),
                                savedAt: Date(timeIntervalSince1970: 1_000))
        cache.save(saved)
        XCTAssertEqual(cache.fleet(for: "mac-a"), saved)
        XCTAssertNil(cache.fleet(for: "mac-b"), "a re-pair to another Mac must not open on this one's sessions")
        cache.purgeAll()
        XCTAssertNil(cache.fleet(for: "mac-a"))
    }

    func testTimelinesAreKeptPrunedAndRemovedPerSession() {
        let cache = temporaryCache()
        let kept = UUID(), gone = UUID()
        let held = CachedTimeline(source: "S", feed: feed([item(10)], start: 0, end: 20),
                                  savedAt: Date(timeIntervalSince1970: 1_000))
        cache.save(held, for: kept)
        cache.save(held, for: gone)
        cache.pruneTimelines(keeping: [kept])
        XCTAssertEqual(cache.timeline(for: kept), held)
        XCTAssertNil(cache.timeline(for: gone), "a session the Mac no longer has must not stay on the phone")
        cache.removeTimeline(for: kept)
        XCTAssertNil(cache.timeline(for: kept))
    }

    // MARK: The transcript's identity

    /// The case `reset` cannot see: a transcript replaced by one at least as long. Same path,
    /// new file — the token must change, or a cached feed's cursors land in the wrong file.
    func testTheSourceTokenChangesWhenTheFileIsReplacedInPlace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneResumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)
        let first = TimelineReader.identity(of: url)
        try Data("{\"a\":1}\n{\"b\":2}\n".utf8).write(to: url, options: .atomic)
        let replaced = TimelineReader.identity(of: url)
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, replaced)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"c\":3}\n".utf8))
        try handle.close()
        XCTAssertEqual(TimelineReader.identity(of: url), replaced, "an append is the same file")
    }
}
