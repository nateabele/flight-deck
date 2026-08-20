import Network
import XCTest
import FleetKit

@MainActor
final class FleetConnectorTests: XCTestCase {
    private var servers: [FleetSocketServer] = []
    private var connector: FleetConnector?

    override func tearDown() {
        connector?.stop()
        servers.forEach { $0.stop() }
        servers = []
        connector = nil
        super.tearDown()
    }

    private let sessionID = UUID()
    // Stable, like `sessionID`: `fleet(_:)` is called more than once per test (once to seed
    // the server, once more to build the expected value for an assertion), and a fresh UUID
    // on every call would make `WireProject`'s synthesized `Equatable` fail on `id` alone,
    // no matter how faithfully the connector applied the frame.
    private let projectID = UUID()

    private func fleet(_ title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: projectID, name: "fd", path: "/w/fd", sessions: [
                WireSession(id: sessionID, title: title, agent: "claude")
            ])
        ])
    }

    @discardableResult
    private func startServer(
        key: FleetDeviceKey, fleet: FleetSnapshot
    ) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onCommand = { _, cid, _ in .ack(cid: cid) }
        servers.append(server)
        return try await server.start(keys: [key], port: nil)
    }

    private func connector(
        key: FleetDeviceKey, endpoints: [String], store: PairedMacStoring = InMemoryPairedMacStore()
    ) -> FleetConnector {
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: endpoints
        )
        store.save(mac)
        // Bonjour is disabled in these tests — the browser is injected, and here it never
        // reports anything, so what is under test is purely the remembered-endpoint race.
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        return connector
    }

    func testTheFirstReachableCandidateWins() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))

        let connected = expectation(description: "connected")
        var seen: FleetSnapshot?
        // Two dead candidates ahead of the live one — the ordinary case for a phone that
        // has moved networks, and the reason this is a race rather than a fallback chain.
        let connector = connector(key: key, endpoints: [
            "192.0.2.1:9", "198.51.100.7:9", "127.0.0.1:\(port.rawValue)"
        ])
        connector.onFleet = { seen = $0; connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(seen, fleet("one"))
    }

    func testTheStateReachesConnectedAndNamesTheMac() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let connected = expectation(description: "state")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        connector.onState = { if case .connected("Mac") = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
    }

    /// The endpoint that worked is remembered first, so the next launch connects on its
    /// first attempt instead of racing three dead addresses again.
    func testTheWinningEndpointIsPromotedForNextTime() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let store = InMemoryPairedMacStore()
        let winner = "127.0.0.1:\(port.rawValue)"
        let connected = expectation(description: "connected")
        let connector = connector(key: key, endpoints: ["192.0.2.1:9", winner], store: store)
        connector.onFleet = { _ in connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(store.load()?.endpoints.first, winner)
    }

    /// The regression this guards, and why it is staged so carefully: a race's timeout used
    /// to outlive the race that scheduled it. When every candidate failed fast, the retry was
    /// already pending by the time the dead race's timer fired — and it scheduled a SECOND
    /// retry. Two races then ran against each other, the later tearing down whatever the
    /// earlier had connected. The visible effect is a connection that drops seconds after
    /// coming up, for no reason on the wire, which reads as a flaky network.
    ///
    /// The first race must FAIL for this to be exercised at all: if it connects, the existing
    /// `winner == nil` guard suppresses the timer and the test proves nothing. So the server
    /// is down for the first race and back on the same port — the same instance, so
    /// `start()`'s own release-then-rebind handles the port coming free — before the second.
    func testAStaleRaceTimeoutDoesNotRetireTheRaceThatReplacedIt() async throws {
        let key = FleetDeviceKey.mint()
        let expected = fleet("one")
        let server = FleetSocketServer()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: expected, reason: .initial)] }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)
        server.stop()

        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        // The timeout has to land inside the backoff window — after the first race has
        // already failed and scheduled its retry, and before that retry runs.
        connector.raceTimeout = 1
        connector.retryDelays = [1.5]

        var states: [FleetConnector.State] = []
        let connected = expectation(description: "connected")
        connector.onState = { states.append($0) }
        connector.onFleet = { _ in connected.fulfill() }
        connector.start()

        try await Task.sleep(for: .milliseconds(600))
        _ = try await server.start(keys: [key], port: port)
        await fulfillment(of: [connected], timeout: 20)

        // Long enough for the stale timeout, and any retry it wrongly scheduled, to fire.
        try await Task.sleep(for: .seconds(3))

        let firstConnected = states.firstIndex {
            if case .connected = $0 { return true } else { return false }
        }
        let after = states[((firstConnected ?? states.count - 1) + 1)...]
        XCTAssertTrue(
            after.allSatisfy { if case .connected = $0 { return true } else { return false } },
            "a live connection must not be retired by a timer from an earlier race: \(states)"
        )
    }

    /// A narrower probe than the test above, aimed at the half-fix this task was amended
    /// away from: bumping `generation` only in `race()`, not also in `scheduleRetry()`. That
    /// half-fix already stops a stale timer from retiring a LIVE connection — the test above
    /// still passes under it — which is exactly why it does not discriminate this bug. What
    /// it does not stop: a race whose sole candidate fails fast enough to trigger
    /// `noteDisconnect`'s own `scheduleRetry()` call leaves that race's `raceTimeout` timer
    /// stale but still pending. Under the half-fix that stale timer's captured generation
    /// still matches `self.generation` when it fires mid-backoff, so it calls
    /// `scheduleRetry()` a SECOND time — accelerating the backoff and reporting a spurious
    /// extra `.lost`, without an intervening `.searching`.
    ///
    /// `127.0.0.1:1` is used rather than the `192.0.2.1` blackhole other tests use: a
    /// blackholed address never fails on its own inside this test's window (see
    /// `testNoReachableCandidateEndsInLostRatherThanSearchingForever`, which is bound by
    /// `raceTimeout` alone), so `noteDisconnect` would never fire first and the race timer
    /// would never go stale — nothing to reproduce. A closed loopback port refuses instantly,
    /// which is what leaves `raceTimeout`'s timer stranded while `scheduleRetry()`'s own
    /// (shorter) retry timer is already running.
    ///
    /// Under the half-fix the trace is `[.searching, .lost(0.5), .lost(5.0), .searching, …]`
    /// — backoff jumping straight from 0.5 to 5.0 within what should be a single race. Under
    /// the full fix there is at most one `.lost` between any two `.searching` states.
    func testAStaleRaceTimeoutDuringBackoffDoesNotDoubleTheRetry() async throws {
        let connector = connector(key: .mint(), endpoints: ["127.0.0.1:1"])
        connector.raceTimeout = 0.2
        connector.retryDelays = [0.5, 5.0]

        var states: [FleetConnector.State] = []
        connector.onState = { states.append($0) }
        connector.start()

        try await Task.sleep(for: .seconds(2))
        connector.stop()

        var lostSinceSearching = 0
        for state in states {
            switch state {
            case .searching:
                lostSinceSearching = 0
            case .lost:
                lostSinceSearching += 1
            default:
                break
            }
            XCTAssertLessThanOrEqual(
                lostSinceSearching, 1,
                "a stale race timeout during backoff must not schedule a second retry: \(states)"
            )
        }
    }

    func testTheAppliedSequenceIsRememberedSoARelaunchResumes() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let store = InMemoryPairedMacStore()
        let connected = expectation(description: "connected")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store)
        connector.onFleet = { _ in connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(store.load()?.lastSeq, 1)
    }

    /// The Mac's own sequence counter (`FleetReplicator.seq`) restarts at 0 on every process
    /// launch. A phone reconnecting after that restart is, from its own point of view, asking
    /// to resume from a `lastSeq` that is now ahead of anything the Mac can offer — the server
    /// answers with a snapshot rather than a replay, and that snapshot's `seq` is LOWER than
    /// what this phone already has stored. `lastSeq` must adopt it anyway: frames on one
    /// connection are ordered, so whatever seq the snapshot being applied right now carries
    /// IS the truth for this connection. Guarding this the way `.event` is guarded would pin
    /// `lastSeq` at the stale, pre-restart value forever — the display stays correct because
    /// `fleet.apply` runs regardless and events are idempotent, but every future reconnect
    /// would re-download the whole snapshot instead of resuming, a permanent and invisible
    /// regression.
    func testASnapshotWithALowerSeqThanStoredIsAdoptedAnyway() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let store = InMemoryPairedMacStore()
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"], lastSeq: 500
        )
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        let connected = expectation(description: "connected")
        connector.onFleet = { _ in connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(store.load()?.lastSeq, 1)
    }

    func testLiveEventsAreAppliedToTheHeldSnapshot() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let renamed = expectation(description: "renamed")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        connector.onFleet = { snapshot in
            if snapshot.projects.first?.sessions.first?.title == "two" { renamed.fulfill() }
        }
        connector.start()
        // Give the race a moment to settle before broadcasting; the server holds nothing
        // for a client that has not attached.
        let attached = expectation(description: "attached")
        servers[0].onAttachedCountChanged = { if $0 == 1 { attached.fulfill() } }
        await fulfillment(of: [attached], timeout: 20)
        servers[0].broadcast(.event(seq: 2, .renamed(id: sessionID, title: "two", origin: .user)))
        await fulfillment(of: [renamed], timeout: 20)
    }

    /// A Mac that goes away must produce a visible "lost" state, not a fleet frozen at
    /// whatever it last said. A stale fleet that looks live is the single most misleading
    /// thing this app could show.
    func testLosingTheMacIsReportedRatherThanLeavingAStaleFleetLookingLive() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let connected = expectation(description: "connected")
        let lost = expectation(description: "lost")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        connector.retryDelays = [0.2]
        connector.onState = { state in
            switch state {
            case .connected: connected.fulfill()
            case .lost: lost.fulfill()
            default: break
            }
        }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        servers[0].stop()
        await fulfillment(of: [lost], timeout: 20)
    }

    func testNoReachableCandidateEndsInLostRatherThanSearchingForever() async throws {
        let connector = connector(key: .mint(), endpoints: ["192.0.2.1:9"])
        connector.retryDelays = [0.2]
        let lost = expectation(description: "lost")
        connector.onState = { if case .lost = $0 { lost.fulfill() } }
        connector.start()
        await fulfillment(of: [lost], timeout: 30)
    }
}
