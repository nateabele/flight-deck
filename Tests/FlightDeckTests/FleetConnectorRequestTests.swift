import Network
import XCTest
@testable import FleetKit

/// The connector's request half, against a real listener.
///
/// `browse: false` throughout, as every other connector test does: Bonjour on the build
/// machine finds whatever else is running and makes the race nondeterministic.
///
/// Every test here asserts **which** request got **which** answer, not that some callback
/// fired. A counting assertion passes just as happily when two in-flight fetches have had
/// their results swapped, and swapping them is the whole failure mode a `cid`-correlated
/// table exists to prevent.
@MainActor
final class FleetConnectorRequestTests: XCTestCase {
    private var server: FleetSocketServer!
    private var connector: FleetConnector!
    private let key = FleetDeviceKey.mint()
    private let session = UUID()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        connector?.stop()
        connector = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    /// Distinguishable by construction. A page whose every field is the same as the next
    /// one's cannot tell a crossed result from a correct one — see `TranscriptPagerTests`,
    /// where an offset bug survived a contents-only assertion.
    private func page(_ text: String, start: Int = 0, end: Int = 80) -> TimelinePage {
        TimelinePage(
            session: session,
            items: [TimelineItem(id: "\(start)#0", kind: .userTurn, status: .complete,
                                 body: .init(text: text))],
            start: start, end: end, hasMore: false, reset: false
        )
    }

    private func fetch(_ anchor: TimelineAnchor = .latest) -> FleetRequest {
        .timeline(session: session, anchor: anchor, limit: 40)
    }

    private func startConnector(
        lastSeq: Int = 0, store: InMemoryPairedMacStore = InMemoryPairedMacStore()
    ) async throws -> (FleetConnector, NWEndpoint.Port) {
        // A snapshot, not an empty reply: `FleetConnector` installs its winner and reports
        // `.connected` from `accept()`, which only runs when a frame actually arrives. Its
        // `seq` echoes the seeded resume point so the handshake leaves `lastSeq` exactly
        // where the test put it — `adopt(_:)` sets it absolutely — and any later movement is
        // the page's doing and nothing else's.
        server.onHello = { _, _ in [.snapshot(seq: lastSeq, fleet: .empty, reason: .initial)] }
        let port = try await server.start(keys: [key], port: nil)
        let mac = PairedMac(
            key: key, macName: "Test", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"], lastSeq: lastSeq
        )
        store.save(mac)
        // `browse: false`, as every connector test does: Bonjour on the build machine finds
        // whatever else is running and makes the race nondeterministic.
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        // `retryDelays` is left at its production value here. Only one test in this file
        // waits out a backoff, and it shortens it itself: a 50ms schedule shared by all
        // twelve means every test that ends with a dead server spends the rest of its run
        // redialling a closed port a few dozen times a second, for nothing.
        self.connector = connector
        let connected = expectation(description: "connected")
        connector.onState = { if case .connected = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 10)
        return (connector, port)
    }

    func testARequestResolvesWithItsPage() async throws {
        let expected = page("hello")
        server.onRequest = { _, cid, _, reply in reply(.page(cid: cid, expected)) }
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(fetch()) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .success(expected))
    }

    /// Two fetches in flight is the ordinary case — a screen asking for older history while a
    /// poll for newer is outstanding — and the server is free to answer them in either order,
    /// because a page is a file read and the second one can finish first.
    ///
    /// Answered deliberately backwards, and asserted by *which request got which page*: a
    /// test that only counted completions, or only checked that both pages arrived somewhere,
    /// would pass with the two results swapped.
    func testTwoRequestsInFlightGetTheirOwnPages() async throws {
        let older = page("older", start: 0, end: 10)
        let newer = page("newer", start: 20, end: 30)
        var deferred: [() -> Void] = []
        server.onRequest = { _, cid, request, reply in
            guard case .timeline(_, let anchor, _) = request else { return XCTFail("wrong verb") }
            let page = anchor == .before(10) ? older : newer
            deferred.append { reply(.page(cid: cid, page)) }
            // Both held until both have arrived, then answered youngest-first.
            if deferred.count == 2 { deferred.reversed().forEach { $0() } }
        }
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "both answered")
        answered.expectedFulfillmentCount = 2
        var results: [String: Result<TimelinePage, FleetRequestError>] = [:]
        connector.request(fetch(.before(10))) { results["older"] = $0; answered.fulfill() }
        connector.request(fetch(.after(20))) { results["newer"] = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(results, ["older": .success(older), "newer": .success(newer)])
    }

    func testAnErrorReplyResolvesWithItsCode() async throws {
        server.onRequest = { _, cid, _, reply in reply(.err(cid: cid, code: "no_transcript")) }
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(fetch()) { result = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.server(code: "no_transcript")))
    }

    /// One request's refusal must not disturb another's.
    ///
    /// That is the claim here, and nothing else in this file makes it: `err` is the answer to
    /// exactly one `cid`, not a verdict on the channel. The tempting wrong reading is that a
    /// server saying no means the conversation is over — `drainPending()` in the `err` arm is
    /// a two-character mistake — and it would strand a perfectly good fetch on a perfectly
    /// good socket, reported as `.disconnected` on a connector that is still connected.
    ///
    /// `unsupported` is the realistic code for it: a Mac older than this phone refusing a
    /// request it cannot parse, on the salvage path that deliberately leaves the socket alive
    /// (see `FleetRequestPlumbingTests`, which is where the code is actually produced). A
    /// refusal that took the connection with it is the one-second flap all over again, which
    /// is why the second request is answered over the *same* socket rather than a new one.
    func testARefusalResolvesItsOwnRequestAndLeavesAnotherPending() async throws {
        let expected = page("the survivor")
        // Each held reply closes over the `cid` the server echoed it, so nothing here depends
        // on guessing what the connector numbered its requests.
        var refuse: (() -> Void)?
        var answer: (() -> Void)?
        let reached = expectation(description: "both requests reached the server")
        reached.expectedFulfillmentCount = 2
        server.onRequest = { _, cid, request, reply in
            guard case .timeline(_, let anchor, _) = request else { return XCTFail("wrong verb") }
            if anchor == .before(4_096) {
                refuse = { reply(.err(cid: cid, code: "unsupported")) }
            } else {
                answer = { reply(.page(cid: cid, expected)) }
            }
            reached.fulfill()
        }
        let (connector, _) = try await startConnector()

        var results: [String: Result<TimelinePage, FleetRequestError>] = [:]
        let refused = expectation(description: "the refused one")
        let answered = expectation(description: "the other one")
        connector.request(fetch(.before(4_096))) { results["refused"] = $0; refused.fulfill() }
        connector.request(fetch(.after(20))) { results["survivor"] = $0; answered.fulfill() }
        await fulfillment(of: [reached], timeout: 10)

        refuse?()
        await fulfillment(of: [refused], timeout: 10)
        // Answered only now, and over the socket the refusal just travelled: if the `err`
        // had been read as "the channel is finished", this request would already hold
        // `.disconnected` and no page could reach it.
        answer?()
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(results, [
            "refused": .failure(.server(code: "unsupported")), "survivor": .success(expected)
        ])
    }

    /// A reply correlated to a `cid` nothing is waiting on any more — the screen scrolled
    /// away, or the Mac answered twice — is dropped in silence. The load-bearing half is the
    /// second assertion: dropped is not the same as *applied to whatever else is in the
    /// table*, and a lookup that fell back to "the only outstanding request" would resolve
    /// the wrong fetch with a page from a different one.
    ///
    /// No sleep and no second timeout: both frames are broadcast over one socket, so the
    /// stray is guaranteed to have been handled by the time the legitimate answer behind it
    /// lands.
    func testAReplyOnACidNobodyIsWaitingForResolvesNothing() async throws {
        var cids: [Int] = []
        var replies: [Int: (ServerFrame) -> Void] = [:]
        let reached = expectation(description: "both requests reached the server")
        reached.expectedFulfillmentCount = 2
        server.onRequest = { _, cid, _, reply in
            cids.append(cid)
            replies[cid] = reply
            reached.fulfill()
        }
        let (connector, _) = try await startConnector()

        let expected = page("the first")
        let firstAnswered = expectation(description: "first answered")
        var results: [String: Result<TimelinePage, FleetRequestError>] = [:]
        connector.request(fetch(.before(10))) { results["first"] = $0; firstAnswered.fulfill() }

        let secondAnswered = expectation(description: "second answered")
        connector.request(fetch(.after(20))) { results["second"] = $0; secondAnswered.fulfill() }
        await fulfillment(of: [reached], timeout: 10)

        replies[cids[0]]?(.page(cid: cids[0], expected))
        await fulfillment(of: [firstAnswered], timeout: 10)

        // A page on the `cid` the first request closed out on. Nobody is waiting for it.
        server.broadcast(.page(cid: cids[0], page("stray", start: 900, end: 999)))
        // An `ack` is the other shape of it: a server that answered a request with a
        // command's reply, on a `cid` that is likewise no longer pending.
        server.broadcast(.ack(cid: cids[0]))
        // Ordered behind both on the same socket: the answer the second request is owed.
        server.broadcast(.err(cid: cids[1], code: "no_transcript"))
        await fulfillment(of: [secondAnswered], timeout: 10)

        XCTAssertEqual(results, [
            "first": .success(expected),
            "second": .failure(.server(code: "no_transcript"))
        ], "the stray frames must have landed nowhere")
    }

    /// An `ack` correlated to a *pending* request is a server that answered the wrong verb —
    /// `ack` means dispatched, not done, which is no answer at all to a question whose whole
    /// point is the data it carries back. Released as a failure rather than dropped, because
    /// a dropped one is a caller waiting for a reply that has already been and gone.
    func testAnAckOnAPendingRequestReleasesItRatherThanStrandingIt() async throws {
        var cids: [Int] = []
        let reached = expectation(description: "reached")
        server.onRequest = { _, cid, _, _ in cids.append(cid); reached.fulfill() }
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(fetch()) { result = $0; answered.fulfill() }
        await fulfillment(of: [reached], timeout: 10)
        server.broadcast(.ack(cid: cids[0]))
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.server(code: "unexpected_ack")))
    }

    /// **The one that matters.** A socket that dies with a fetch outstanding must answer the
    /// callback, not abandon it. A screen waiting on a callback that never arrives shows a
    /// spinner forever with nothing to explain it — the same failure the stale-fleet banner
    /// exists to prevent, one layer down.
    func testAPendingRequestFailsWhenTheConnectionDrops() async throws {
        let held = expectation(description: "request reached the server")
        server.onRequest = { _, _, _, _ in held.fulfill() }   // deliberately never replies
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(fetch()) { result = $0; answered.fulfill() }
        await fulfillment(of: [held], timeout: 10)
        server.stop()
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(result, .failure(.disconnected))
    }

    /// Three in flight, all drained, each exactly once — asserted as three distinct entries
    /// rather than three fulfilments, so a drain that answered one request three times would
    /// still redden.
    func testStoppingTheConnectorAnswersEveryPendingRequest() async throws {
        let held = expectation(description: "reached")
        held.expectedFulfillmentCount = 3
        server.onRequest = { _, _, _, _ in held.fulfill() }
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "all answered")
        answered.expectedFulfillmentCount = 3
        var results: [Int: Result<TimelinePage, FleetRequestError>] = [:]
        var completions = 0
        for index in 0..<3 {
            connector.request(fetch(.before(index))) {
                results[index] = $0
                completions += 1
                answered.fulfill()
            }
        }
        await fulfillment(of: [held], timeout: 10)
        connector.stop()
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(completions, 3)
        XCTAssertEqual(results, [
            0: .failure(.disconnected), 1: .failure(.disconnected), 2: .failure(.disconnected)
        ])
    }

    /// The obvious thing a caller does with `.disconnected` is ask again, and the drain is
    /// where it first hears it — so the retry is issued from *inside* the drain, re-entrantly,
    /// while `teardown()` is still running.
    ///
    /// It has to be answered too. A retry filed into a pending table the drain has already
    /// emptied is a request nothing will ever resolve: `teardown()` will not run again for it
    /// (there is no connection left to lose) and no reply can arrive on a socket that is
    /// gone. That is the spinner-forever bug reached by the one path the drain itself opens,
    /// which is why the table is emptied and `winner` cleared *before* any completion is
    /// invoked.
    func testARetryIssuedFromInsideTheDrainIsAnsweredRatherThanStranded() async throws {
        let held = expectation(description: "reached")
        server.onRequest = { _, _, _, _ in held.fulfill() }
        let (connector, _) = try await startConnector()

        let answered = expectation(description: "the original and its retry")
        answered.expectedFulfillmentCount = 2
        var results: [String: Result<TimelinePage, FleetRequestError>] = [:]
        connector.request(fetch()) { original in
            results["original"] = original
            answered.fulfill()
            connector.request(self.fetch()) { retry in
                results["retry"] = retry
                answered.fulfill()
            }
        }
        await fulfillment(of: [held], timeout: 10)
        connector.stop()
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(results, [
            "original": .failure(.disconnected), "retry": .failure(.disconnected)
        ])
    }

    /// The other half of the same re-entrancy, and the one the consumer sees.
    ///
    /// `stop()` from inside a completion is what `resolve(_:with:)` calls the ordinary case,
    /// and the drain is where a completion first hears `.disconnected` — so the `stop()`
    /// lands in the middle of `scheduleRetry()`'s `teardown()`. What follows that `teardown()`
    /// on the way back out is `report(.lost(retryingIn:))`, which would make `.lost` the last
    /// word the consumer hears about a connector that has gone `.idle` and will never race
    /// again: `race()` guards on `running`, which this `stop()` just cleared.
    ///
    /// That is a "reconnecting in one second" banner with nothing reconnecting behind it and
    /// nothing on screen to explain it — the same user-visible shape as the flap this whole
    /// channel exists to have fixed. Asserted as the WHOLE sequence of reported states rather
    /// than the last one, because a `.lost` announced before `.idle` would be just as wrong.
    func testAStopFromInsideTheDrainLeavesTheConnectorIdleNotRetrying() async throws {
        let held = expectation(description: "reached")
        server.onRequest = { _, _, _, _ in held.fulfill() }
        let (connector, _) = try await startConnector()

        var states: [FleetConnector.State] = []
        let idle = expectation(description: "idle")
        connector.onState = { state in
            states.append(state)
            if case .idle = state { idle.fulfill() }
        }
        let answered = expectation(description: "answered")
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(fetch()) {
            result = $0
            connector.stop()
            answered.fulfill()
        }
        await fulfillment(of: [held], timeout: 10)
        server.stop()
        await fulfillment(of: [answered, idle], timeout: 10)
        // Detached before `tearDown()` stops the connector a second time, which would
        // over-fulfil `idle` after the wait has completed.
        connector.onState = nil
        XCTAssertEqual(result, .failure(.disconnected))
        XCTAssertEqual(states, [.idle], "a .lost around .idle is a banner nothing will clear")
    }

    /// A request made while nothing is connected has to answer immediately. `send(_ command:)`
    /// is a silent no-op in that state, which is correct for a command whose effect arrives
    /// as an event and wrong for a request whose whole point is the reply.
    func testARequestWhileDisconnectedFailsAtOnce() {
        let mac = PairedMac(key: key, macName: "Test",
                            serviceName: "none-\(UUID().uuidString)", endpoints: [])
        let store = InMemoryPairedMacStore()
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(fetch()) { result = $0 }
        XCTAssertEqual(result, .failure(.disconnected), "and synchronously, not eventually")
    }

    /// **How a late reply cannot be matched to a reused `cid`.** A `FleetClient`'s `cid`
    /// counter is per-connection and restarts at 1, so the second connection here hands out
    /// exactly the number the first one did — asserted, so this cannot quietly stop being the
    /// scenario it is named for.
    ///
    /// What makes that safe is that the pending table is emptied by the same `teardown()`
    /// that drops the connection, and `teardown()` is the only path by which `winner` is
    /// replaced. So the table a reused `cid` is looked up in never contains an entry from an
    /// earlier connection: the old request was already resolved `.disconnected`, and the new
    /// one is the only claimant on that number.
    func testACidReusedByTheNextConnectionAnswersTheNewRequestOnly() async throws {
        var cids: [Int] = []
        let reached = expectation(description: "the first request reached the server")
        server.onRequest = { _, cid, _, _ in cids.append(cid); reached.fulfill() }
        let (connector, port) = try await startConnector()
        // The only backoff this file waits out. A quarter second rather than the production
        // one, and deliberately not shorter: the reconnect below is dominated by the listener
        // rebinding the same port, and dialling into the middle of that at 50ms intervals
        // buys nothing but a race with `releaseListenerOnQueue`. The expectation allows 20s.
        connector.retryDelays = [0.25]

        let answered = expectation(description: "both answered")
        answered.expectedFulfillmentCount = 2
        var results: [String: Result<TimelinePage, FleetRequestError>] = [:]
        connector.request(fetch(.before(10))) { results["before"] = $0; answered.fulfill() }
        await fulfillment(of: [reached], timeout: 10)

        // Rebinding the same port drops every attachment on the way — the phone's socket
        // dies mid-fetch, exactly as it does when a Mac restarts under it.
        let reconnected = expectation(description: "reconnected")
        connector.onState = { if case .connected = $0 { reconnected.fulfill() } }
        let expected = page("after the reconnect")
        server.onRequest = { _, cid, _, reply in
            cids.append(cid)
            reply(.page(cid: cid, expected))
        }
        _ = try await server.start(keys: [key], port: port)
        await fulfillment(of: [reconnected], timeout: 20)

        connector.request(fetch(.after(20))) { results["after"] = $0; answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(cids, [1, 1], "the second connection must genuinely reuse the number")
        XCTAssertEqual(results, [
            "before": .failure(.disconnected), "after": .success(expected)
        ])
    }

    /// A page must not move the resume point. `FleetConnector.advance(to:)` and `adopt(_:)`
    /// are the only writers of `lastSeq`, and neither may be reached from a `.page`: a phone
    /// paging back through an hour of transcript would otherwise rewrite how much fleet
    /// history it believes it has seen, and resume from the wrong place on its next launch.
    func testAPageDoesNotMoveTheResumePoint() async throws {
        // Offsets deliberately ABOVE the seeded resume point. `advance(to:)` ignores a seq
        // that is not a real advance, so a page whose `end` sat below 500 would leave this
        // green even if the `.page` arm called it — the mutation has to be able to move the
        // number for its absence to mean anything.
        let page = page("hi", start: 700, end: 800)
        server.onRequest = { _, cid, _, reply in reply(.page(cid: cid, page)) }
        let store = InMemoryPairedMacStore()
        let (connector, _) = try await startConnector(lastSeq: 500, store: store)

        let answered = expectation(description: "answered")
        connector.request(fetch()) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(store.load()?.lastSeq, 500, "a history fetch is not fleet history")
    }
}
