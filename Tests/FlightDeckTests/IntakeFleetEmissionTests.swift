import Network
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

@MainActor
final class IntakeFleetEmissionTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeFleetEmission-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> (SessionStore, PreferencesStore, Repo) {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        return (store, prefs, store.repos[0])
    }

    private func enable(_ prefs: PreferencesStore, _ repo: Repo, _ on: Bool) {
        var settings = prefs.projectSettings(repo.url.path)
        settings.flywheelEnabled = on ? true : nil
        prefs.setProjectSettings(repo.url.path, settings)
    }

    /// Review focus 4: the toggle lives in preferences, not the store, so it only reaches the
    /// wire through the refresh — and the drift oracle reads the same cache the refresh writes.
    func testTogglingFlightControlEmitsAndNeverDrifts() {
        let (store, prefs, repo) = makeStore()
        let replicator = attachedReplicator(to: store)   // XCTFails on drift
        var seen: [FleetEvent] = []
        replicator.onEvents = { seen += $0.map(\.event) }

        store.refreshIntakeSummaries()
        XCTAssertEqual(seen, [], "off, and never told otherwise: nothing to say")

        enable(prefs, repo, true)
        store.refreshIntakeSummaries()
        XCTAssertEqual(seen.last, .projectIntakes(project: repo.id, intakes: []))
        XCTAssertEqual(FleetProjection.snapshot(of: store).projects[0].intakes, [])

        let count = seen.count
        store.refreshIntakeSummaries()   // nothing changed
        XCTAssertEqual(seen.count, count)

        enable(prefs, repo, false)
        store.refreshIntakeSummaries()
        XCTAssertEqual(seen.last, .projectIntakes(project: repo.id, intakes: nil))
        XCTAssertNil(FleetProjection.snapshot(of: store).projects[0].intakes)
    }

    func testANewIntakeReachesTheWire() throws {
        let (store, prefs, repo) = makeStore()
        _ = attachedReplicator(to: store)
        enable(prefs, repo, true)
        var i = Intake(projectPath: repo.url.standardizedFileURL.path, intent: "Plan the thing")
        i.state = .needsAnswers
        i.exchanges = [TriageExchange(questions: ["Which README?"])]
        // Saved BEFORE the first touch of `store.intakeService`, which loads what is on disk
        // when it is built — the refresh below is that first touch.
        try IntakeStore(root: root).save(i)
        store.refreshIntakeSummaries()
        let listed = try XCTUnwrap(FleetProjection.snapshot(of: store).projects[0].intakes)
        XCTAssertEqual(listed.map(\.id), [i.id])
        XCTAssertTrue(listed[0].needsAttention)
        XCTAssertEqual(listed[0].questionCount, 1)
    }

    /// The store's own change signal drives the refresh once `startIntakeSummaries` runs — on
    /// the NEXT main-queue turn, because `objectWillChange` fires before the change lands.
    func testAStoreChangeRefreshesOnTheNextTurn() async {
        let (store, prefs, repo) = makeStore()
        let replicator = attachedReplicator(to: store)
        var seen: [FleetEvent] = []
        replicator.onEvents = { seen += $0.map(\.event) }
        store.startIntakeSummaries()
        XCTAssertEqual(seen, [])

        enable(prefs, repo, true)   // preferences forward into the store's objectWillChange
        let landed = expectation(description: "refreshed")
        DispatchQueue.main.async { DispatchQueue.main.async { landed.fulfill() } }
        await fulfillment(of: [landed], timeout: 5)
        XCTAssertEqual(seen, [.projectIntakes(project: repo.id, intakes: [])])
    }

    /// Spec §6.1: "an agent finishing" moves the summary. A seat's `run.json` is published only
    /// on its `SeatFeed` channel — never through the store — so without the feed's own hook the
    /// phone's "k of n agents" waited for an unrelated change or the 60 s tick.
    func testAnAgentFinishingReachesTheWireWithinTwoTurns() async throws {
        // The store's intake service drives a REAL runner controller. A running tape with no
        // live runner would make it spawn one; this control answers "live" for every socket and
        // the tape's heartbeat is fresh, so `isRunning` holds and nothing is ever launched.
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, daemonControl: LiveDaemonControl(), intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        let repo = store.repos[0]
        enable(prefs, repo, true)

        let round = PlannedRound(stage: .refine, round: 1, major: false)
        var i = Intake(projectPath: repo.url.standardizedFileURL.path, intent: "Plan the thing")
        i.state = .shaping
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        var tape = tapes.loadTape()
        tape.status = .running
        tape.roundInProgress = round
        tape.heartbeat = Date()
        try tapes.saveTape(tape)
        let started = Date()
        func writeSeat(_ run: String, finished: Bool) throws {
            let dir = tapes.runDirectory(run)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try IntakeJSON.encoder.encode(SeatActivity(agent: .codex, startedAt: started))
                .write(to: dir.appendingPathComponent("activity.json"))
            try IntakeJSON.encoder.encode(RunRecord(started: started, finished: finished ? Date() : nil, exitCode: finished ? 0 : nil))
                .write(to: dir.appendingPathComponent("run.json"))
        }
        try writeSeat("refine-1-reviewer", finished: false)
        try writeSeat("refine-1-integrator", finished: false)

        let replicator = attachedReplicator(to: store)
        var seen: [FleetEvent] = []
        replicator.onEvents = { seen += $0.map(\.event) }
        store.startIntakeSummaries()
        await store.intakeService.launchRecovery?.value
        await drainTwoTurns()
        guard case .projectIntakes(_, let before?)? = seen.last else { return XCTFail("no summary: \(seen)") }
        XCTAssertEqual(before.first?.agentsTotal, 2)
        XCTAssertEqual(before.first?.agentsDone, 0)

        // The runner's own write: the reviewer exits. Only its `run.json` moves.
        let dir = tapes.runDirectory("refine-1-reviewer")
        try IntakeJSON.encoder.encode(RunRecord(started: started, finished: Date(), exitCode: 0))
            .write(to: dir.appendingPathComponent("run.json"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: dir.appendingPathComponent("run.json").path)
        let count = seen.count
        store.intakeService.pollTapes()
        await drainTwoTurns()
        XCTAssertGreaterThan(seen.count, count, "an agent finishing must record a summary event")
        guard case .projectIntakes(_, let after?)? = seen.last else { return XCTFail("no summary: \(seen)") }
        XCTAssertEqual(after.first?.agentsDone, 1)
        XCTAssertEqual(after.first?.agentsTotal, 2)
    }

    private func drainTwoTurns() async {
        let drained = expectation(description: "two main-queue turns")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        await fulfillment(of: [drained], timeout: 5)
    }

    func testOnlyCapablePeersGetIntakeEvents() {
        XCTAssertEqual(FleetService.requiredCapability(for: .projectIntakes(project: UUID(), intakes: [])),
                       FleetCapability.flightControl)
        XCTAssertNil(FleetService.requiredCapability(for: .projectCollapsed(id: UUID(), isCollapsed: true)))
    }

    /// Review focus 2, the replay half: a resume must not hand an old phone the event the live
    /// broadcast withholds from it.
    func testTheHelloReplayDropsIntakeEventsForAnOldPhone() {
        let frames: [ServerFrame] = [
            .event(seq: 1, .projectCollapsed(id: UUID(), isCollapsed: true)),
            .event(seq: 2, .projectIntakes(project: UUID(), intakes: [])),
            .snapshot(seq: 2, fleet: .empty, reason: .initial),
        ]
        XCTAssertEqual(FleetService.deliverable(frames, caps: []).count, 2)
        XCTAssertEqual(FleetService.deliverable(frames, caps: [FleetCapability.flightControl]).count, 3)
    }
}

/// Review focus 2, the live half, over a real loopback socket (the `PhoneLogPlumbingTests`
/// shape): an old phone throws on an event tag it does not know and drops its socket, so
/// `broadcast(_:requiring:)` must never send it one — and must still reach a phone that can.
@MainActor
final class FleetBroadcastCapabilityTests: XCTestCase {
    private var server: FleetSocketServer!
    private var clients: [FleetClient] = []
    private let key = FleetDeviceKey.mint()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        clients.forEach { $0.disconnect() }
        clients = []
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testARequiringBroadcastReachesOnlyCapablePeers() async throws {
        let attached = expectation(description: "both attached")
        attached.expectedFulfillmentCount = 2
        server.onHello = { _, _ in attached.fulfill(); return [] }
        let port = try await server.start(keys: [key], port: nil)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        var oldEvents: [FleetEvent] = [], newEvents: [FleetEvent] = []
        var oldDropped = false
        let old = FleetClient(key: key, deviceName: "old", caps: [])
        old.onFrame = { if case .event(_, let e) = $0 { oldEvents.append(e) } }
        old.onDisconnect = { _ in oldDropped = true }
        let new = FleetClient(key: key, deviceName: "new", caps: [FleetCapability.flightControl])
        let heard = expectation(description: "capable peer heard it")
        new.onFrame = { if case .event(_, let e) = $0 { newEvents.append(e); heard.fulfill() } }
        clients = [old, new]
        old.connect(to: endpoint, lastSeq: 0)
        new.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [attached], timeout: 10)

        let event = FleetEvent.projectIntakes(project: UUID(), intakes: [])
        server.broadcast(.event(seq: 1, event), requiring: FleetCapability.flightControl)
        await fulfillment(of: [heard], timeout: 10)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 5)

        XCTAssertEqual(newEvents, [event])
        XCTAssertEqual(oldEvents, [])
        XCTAssertFalse(oldDropped, "the old phone's socket must stay up")
        XCTAssertEqual(server.attachedCount, 2)
    }
}

/// Every daemon answers and nothing is ever signalled — so a store's real intake runner
/// controller treats a heartbeating tape's runner as running and never spawns or reaps one.
private final class LiveDaemonControl: DaemonControlling {
    func isLive(_ id: UUID) -> Bool { true }
    func isLive(socketPath: String) -> Bool { true }
    func daemonPID(_ id: UUID) -> pid_t? { nil }
    func daemonPID(socketPath: String) -> pid_t? { nil }
    func terminate(_ id: UUID) {}
    func terminate(socketPath: String) {}
    func peerPID(socketPath: String) -> pid_t? { nil }
    func terminate(pid: pid_t, socketPath: String) {}
    func stop(_ id: UUID) {}
    func cont(_ id: UUID) {}
}
