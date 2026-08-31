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

    /// Captures every batch `SessionStore.emit` hands to `record(_:)`, one array per call — not
    /// what the events *say*, only how many calls and how big each one was. That is exactly
    /// what distinguishes the batching fix from the bug it replaced: the bug and the fix agree
    /// on which events eventually get recorded, and disagree only on whether they arrive as one
    /// call or several.
    private final class SpyReplicator: FleetRecording {
        var records: [[FleetEvent]] = []
        func record(_ events: [FleetEvent]) { records.append(events) }
        func reset() {}
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

        let spy = SpyReplicator()
        store.planGates = service
        store.replicator = spy
        store.appIsActive = { false }

        // One tick, both gates open at once.
        store.applyRegistry([
            pidA: row(sessionA, pid: pidA, activity: .busy),
            pidB: row(sessionB, pid: pidB, activity: .busy),
        ])
        for _ in 0..<100 where spy.records.isEmpty { await Task.yield() }

        XCTAssertEqual(spy.records.count, 1, "two gates changing in one tick must batch into one record")
        let ids = Set(spy.records.first?.compactMap { event -> UUID? in
            guard case .planGateChanged(let id, _) = event else { return nil }
            return id
        } ?? [])
        XCTAssertEqual(ids, [sessionA.id, sessionB.id], "the one record must carry both sessions")
    }
}
