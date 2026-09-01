import FleetKit
import XCTest
@testable import FlightDeck

/// `PlanGateServiceTests` covers the service in isolation; `ClaudeOpenPlanGateTests` covers the
/// transcript derivation the projection oracle uses. Neither exercises the thing that actually
/// ships a notification: `SessionStore.applyRegistry` driving `pollPlanGates()` →
/// `PlanGateService.refresh()` → `deliverPlanGateNotifications()`, through the same
/// `notifier`/`appIsActive` seams `SessionStatusStoreTests` uses for ordinary status
/// transitions. None of that wiring — `pollPlanGates`, `deliverPlanGateNotifications`,
/// `previousPlanGates`, `claudePID(of:)`, `allSessionIDs()` — had a single test before this
/// file, so the CRITICAL fix's `emit(.planGateChanged(...))` line and the notify/withdraw calls
/// around it were only ever reachable, never actually reached, by anything in the suite.
///
/// **Every test here goes through `attachedReplicator`**, like every other store test in this
/// feature, so the oracle-equals-mirror check runs over `planGate` rather than being argued
/// about. It could not, until `FleetProjection.snapshot(of:)` began defaulting `planGates` to
/// the store's own: an oracle built without it projected `planGate: nil` while the mirror
/// folded real gates, so attaching the harness here reported *false* drift and this file used a
/// bespoke spy instead — which meant `checkForDrift` had never once seen a `.planGateChanged`.
@MainActor
final class SessionStorePlanGateIntegrationTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    /// Same shape as `SessionStatusStoreTests.SpyNotifier` — copied rather than shared, since
    /// that one is private to its own file.
    private final class SpyNotifier: Notifying {
        var notified: [(UUID, String, String, String)] = []
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, subtitle: String, body: String) {
            notified.append((sessionID, title, subtitle, body))
        }
        func withdraw(sessionID: UUID) {
            withdrawn.append(sessionID)
        }
    }

    /// Stands in for Plannotator's HTTP API. Only `/api/plan` matters here — this file tests
    /// `SessionStore`'s wiring around `PlanGateService`, not the service's own HTTP handling,
    /// which `PlanGateServiceTests`'s `RecordingTransport` already covers in full.
    private actor RecordingTransport {
        let plan: String
        init(plan: String) { self.plan = plan }
        func handle(_ request: URLRequest) async -> (Data, Int)? {
            guard request.url?.path == "/api/plan" else { return (Data("{}".utf8), 200) }
            let body = (try? JSONSerialization.data(withJSONObject: ["plan": plan])) ?? Data()
            return (body, 200)
        }
    }

    /// A registry row for `session`, in the shape `applyRegistry` resolves against. Copied from
    /// `SessionStoreTests.row` rather than shared: that helper is file-private.
    private func row(
        _ session: Session, pid: pid_t, activity: SessionActivity
    ) -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: session.pinnedConversationID, activity: activity,
              waitingFor: nil, startedAt: 1, cwd: session.workingDirectory, procStart: "start-a")
    }

    /// One `applyRegistry` tick, end to end: a gate opening notifies once, an unchanged re-poll
    /// notifies no further, and the gate closing withdraws. The three outcomes the review asked
    /// this file to pin.
    func testOneApplyRegistryTickNotifiesOnceRepollsQuietlyAndWithdrawsOnClose() async throws {
        let store = SessionStore(provider: StubProvider())
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let claudePID: pid_t = 4242
        let plannotatorPID: pid_t = 9001
        let port = 54233

        // Anchor first, on its own tick, before `planGates` is wired — `PlanGateService`'s
        // `pid` closure below reads `store.claudePID(of:)`, and that has nothing to answer
        // until a registry row has resolved this session's anchor at least once.
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .busy)])
        XCTAssertEqual(store.claudePID(of: session.id), claudePID, "precondition: anchor resolved")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStorePlanGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let registryFile = dir.appendingPathComponent("\(plannotatorPID).json")
        let registryJSON = """
        {"pid":\(plannotatorPID),"port":\(port),"url":"http://localhost:\(port)",\
        "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
        """
        try Data(registryJSON.utf8).write(to: registryFile)

        let transport = RecordingTransport(plan: "# Plan")
        let service = PlanGateService(
            callID: { $0 == session.id ? "toolu_PLAN" : nil },
            pid: { store.claudePID(of: $0) },
            sessions: { store.allSessionIDs() }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { $0 == plannotatorPID ? claudePID : nil }
        service.makeClient = { port in
            PlanGateClient(port: port, transport: { request in await transport.handle(request) })
        }

        let spy = SpyNotifier()
        store.planGates = service
        store.notifier = spy
        // The policy only ever fires `.notify` while the app is inactive — see
        // `SessionNotificationPolicy.action` — so this must be false for the open tick below
        // to produce anything to assert.
        store.appIsActive = { false }
        // Attached AFTER `store.planGates`, so the oracle it builds its opening mirror from
        // reads the same service the folds below will be checked against.
        let replicator = attachedReplicator(to: store)

        // Tick 1: the gate opens.
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .busy)])
        for _ in 0..<100 where spy.notified.isEmpty { await Task.yield() }
        XCTAssertEqual(spy.notified.count, 1, "an opened gate with the app inactive must notify once")
        XCTAssertEqual(spy.notified.first?.0, session.id)

        // Tick 2: re-poll, gate unchanged. Nothing here to wait *for* — the assertion is an
        // absence — so this drains the run loop for a bounded stretch instead of a condition.
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .busy)])
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(spy.notified.count, 1, "an unchanged gate must not notify again")
        XCTAssertTrue(spy.withdrawn.isEmpty, "an unchanged gate must not withdraw")

        // Tick 3: the gate closes — the Plannotator hook resolved, or the process died.
        try FileManager.default.removeItem(at: registryFile)
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .busy)])
        for _ in 0..<100 where spy.withdrawn.isEmpty { await Task.yield() }
        XCTAssertEqual(spy.withdrawn.count, 1, "a closed gate must withdraw its banner")
        XCTAssertEqual(spy.withdrawn.first, session.id)
        XCTAssertEqual(spy.notified.count, 1, "closing must not re-notify")

        // And the wire said both things, in order — the half a phone hears. The drift check
        // inside `record` has run over every one of these folds; before the projection began
        // defaulting `planGates`, it could not.
        var opened: [String] = []
        var closed = 0
        for event in replicator.recorded {
            guard case .planGateChanged(let id, let gate) = event, id == session.id else {
                continue
            }
            if let gate { opened.append(gate.callID) } else { closed += 1 }
        }
        XCTAssertEqual(opened, ["toolu_PLAN"], "one event for the open, carrying the call")
        XCTAssertEqual(closed, 1, "and one for the close, carrying no gate")
    }

    /// **A status edge under a standing gate must leave the banner alone.** `deliverNotifications`
    /// used to pass `planGate: nil` on both sides of every `StatusTransition`, so a
    /// `waiting`→`busy` edge computed `wantsYou` `true`→`false` and withdrew — and if a plan
    /// gate was open at that moment, the banner it pulled was that gate's. Nothing could put it
    /// back: the gate itself had not moved, so `deliverPlanGateNotifications`'s
    /// `guard gate != previous` skips the session from then on, and the notification this whole
    /// feature exists to raise is gone until the plan is answered on the Mac.
    ///
    /// Reachability is low — claude reports `busy` for a gate's whole life, so the edge needs a
    /// session that was `waiting` for something else first — but the outcome is precisely the
    /// defect the feature is for, which is why it is pinned here rather than argued about.
    func testAStatusEdgeUnderAnOpenGateDoesNotWithdrawItsBanner() async throws {
        let store = SessionStore(provider: StubProvider())
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let claudePID: pid_t = 4245
        let plannotatorPID: pid_t = 9006
        let port = 54238

        // Anchored while `waiting`, before anything is watching: this is the status the edge
        // below leaves, and it has to be in `statuses` before the notifier is attached or the
        // anchor tick itself would notify.
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .waiting)])
        XCTAssertEqual(store.claudePID(of: session.id), claudePID, "precondition: anchor resolved")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStorePlanGateEdge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data("""
        {"pid":\(plannotatorPID),"port":\(port),"url":"http://localhost:\(port)",\
        "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
        """.utf8).write(to: dir.appendingPathComponent("\(plannotatorPID).json"))

        let transport = RecordingTransport(plan: "# Plan")
        let service = PlanGateService(
            callID: { $0 == session.id ? "toolu_PLAN" : nil },
            pid: { store.claudePID(of: $0) },
            sessions: { store.allSessionIDs() }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { $0 == plannotatorPID ? claudePID : nil }
        service.makeClient = { port in
            PlanGateClient(port: port, transport: { request in await transport.handle(request) })
        }

        let spy = SpyNotifier()
        store.planGates = service
        store.notifier = spy
        store.appIsActive = { false }
        _ = attachedReplicator(to: store)

        // The gate opens while the session is still `waiting`. No status edge here — the row
        // is the one already applied — so this notifies for the gate and nothing else.
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .waiting)])
        for _ in 0..<100 where spy.notified.isEmpty { await Task.yield() }
        XCTAssertEqual(spy.notified.count, 1, "precondition: the gate raised its banner")
        XCTAssertNotNil(service.gate(for: session.id), "precondition: the gate is open")

        // The edge: whatever the session was waiting for is answered and it goes back to work,
        // with the plan still unread. The banner belongs to the plan, not to the status.
        store.applyRegistry([claudePID: row(session, pid: claudePID, activity: .busy)])
        for _ in 0..<50 { await Task.yield() }

        XCTAssertTrue(spy.withdrawn.isEmpty,
                      "a plan is still waiting to be read, so its banner must stand")
        XCTAssertEqual(spy.notified.count, 1, "and the same standing gate must not re-notify")
        XCTAssertNotNil(service.gate(for: session.id), "the gate itself never moved")
    }

    /// Regression coverage for the batching fix: `refresh()` updates `PlanGateService.gates`
    /// for every session before `deliverPlanGateNotifications` runs a single loop over all of
    /// them, so two sessions' gates opening in the same tick must fold into **one** `record`
    /// call carrying both events — not two calls, where the first would see the oracle already
    /// projecting the second session's new gate while the mirror still held its old one.
    func testTwoGatesOpeningInOneTickProduceOneBatchedRecord() async throws {
        let store = SessionStore(provider: StubProvider())
        let sessionA = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let sessionB = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        let pidA: pid_t = 4243
        let pidB: pid_t = 4244
        let plannotatorPidA: pid_t = 9004
        let plannotatorPidB: pid_t = 9005
        let portA = 54236
        let portB = 54237

        store.applyRegistry([
            pidA: row(sessionA, pid: pidA, activity: .busy),
            pidB: row(sessionB, pid: pidB, activity: .busy),
        ])
        XCTAssertEqual(store.claudePID(of: sessionA.id), pidA, "precondition: anchor A resolved")
        XCTAssertEqual(store.claudePID(of: sessionB.id), pidB, "precondition: anchor B resolved")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStorePlanGateBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func registryEntry(pid: pid_t, port: Int) -> String {
            """
            {"pid":\(pid),"port":\(port),"url":"http://localhost:\(port)",\
            "mode":"plan","project":"flight-deck","startedAt":"2026-08-29T17:40:36.186Z"}
            """
        }
        try Data(registryEntry(pid: plannotatorPidA, port: portA).utf8)
            .write(to: dir.appendingPathComponent("\(plannotatorPidA).json"))
        try Data(registryEntry(pid: plannotatorPidB, port: portB).utf8)
            .write(to: dir.appendingPathComponent("\(plannotatorPidB).json"))

        let transport = RecordingTransport(plan: "# Plan")
        let service = PlanGateService(
            callID: { id in
                if id == sessionA.id { return "toolu_A" }
                if id == sessionB.id { return "toolu_B" }
                return nil
            },
            pid: { store.claudePID(of: $0) },
            sessions: { store.allSessionIDs() }
        )
        service.registryDirectory = dir
        service.isAlive = { _ in true }
        service.parentOf = { pid in
            if pid == plannotatorPidA { return pidA }
            if pid == plannotatorPidB { return pidB }
            return nil
        }
        service.makeClient = { port in
            PlanGateClient(port: port, transport: { request in await transport.handle(request) })
        }

        store.planGates = service
        store.appIsActive = { false }
        let replicator = attachedReplicator(to: store)
        // The real harness, with its batches counted through `onEvents` — one call per
        // `record(_:)`, which is exactly what distinguishes the batching fix from the bug it
        // replaced: the two agree on which events are eventually recorded and disagree only on
        // whether they arrive as one call or several. A bespoke `FleetRecording` spy could
        // count the same thing, but only by displacing the drift check that has to run over
        // these very folds.
        var batches: [[FleetEvent]] = []
        replicator.onEvents = { batch in batches.append(batch.map(\.event)) }

        // One tick, both gates open at once.
        store.applyRegistry([
            pidA: row(sessionA, pid: pidA, activity: .busy),
            pidB: row(sessionB, pid: pidB, activity: .busy),
        ])
        for _ in 0..<100 where batches.isEmpty { await Task.yield() }

        XCTAssertEqual(batches.count, 1, "two gates changing in one tick must batch into one record")
        let ids = Set(batches.first?.compactMap { event -> UUID? in
            guard case .planGateChanged(let id, _) = event else { return nil }
            return id
        } ?? [])
        XCTAssertEqual(ids, [sessionA.id, sessionB.id], "the one record must carry both sessions")
    }
}
