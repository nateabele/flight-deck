import XCTest
import IntakeKit
@testable import FlightDeck

/// End to end from an agent's own file to a contested row: claude's transcript tail and codex's
/// rollout tail both surface the guard block, the store hands it to the swarm, and the swarm
/// relates it to the project's reservations.
@MainActor
final class OutputSignalWiringTests: XCTestCase {
    private var dir: URL!
    private let msg = "mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with reservation 'Sources/*.swift' held by GreenFox"
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("signals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func append(_ record: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: record); data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { try h.seekToEnd(); try h.write(contentsOf: data); try h.close() }
        else { try data.write(to: url) }
    }

    func testClaudesTranscriptTailReportsTheGuardBlock() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [AgentOutputSignal] = []
        let watcher = TranscriptWatcher(sessionID: UUID(), url: url, onTitle: { _ in },
                                        onSignals: { seen += $0 })
        watcher.drain()   // no file yet: the start is chosen at 0
        try append(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t", "is_error": true, "content": "Exit code 1\n" + msg]]]], to: url)
        watcher.drain()
        XCTAssertEqual(seen.count, 1)
        guard case .guardBlock(let block)? = seen.first else { return XCTFail("expected a guard block") }
        XCTAssertEqual(block.holder, "GreenFox")
    }

    func testCodexsRolloutTailReportsTheGuardBlock() throws {
        let url = dir.appendingPathComponent("r.jsonl")
        var events: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url, conversationID: UUID(), onEvent: { events.append($0) })
        watcher.drain()
        try append(["type": "event_msg", "payload": ["type": "exec_command_end", "stderr": msg]], to: url)
        watcher.drain()
        XCTAssertTrue(events.contains { if case .outputSignals(let s) = $0 { return s.count == 1 }; return false })
    }

    private func rigService(_ rig: SwarmRig) -> SwarmService {
        SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                     host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
    }

    func testTheStoreHandsSignalsToTheSwarmAndTheRowBecomesContested() throws {
        let rig = SwarmRig()
        let store = SessionStore(provider: nil, persistence: nil)
        let tab = store.newSession(in: URL(fileURLWithPath: SwarmFixtures.project, isDirectory: true),
                                   flywheelIdentity: FlywheelIdentity(agentName: "BlueLake", project: SwarmFixtures.project))
        var a = rig.agent("BlueLake", state: .working, task: "fx-1")
        a.session = tab.id
        rig.store.save([rig.record(state: .paused, agents: [a])])
        let service = rigService(rig)
        store.useSwarmService(service)
        // After `useSwarmService`, which (from Task 11e) points the lookup at Observe's projection.
        service.reservationsLookup = { _ in [HeldReservation(pattern: "Sources/*.swift", holder: "GreenFox", since: rig.now - 360)] }
        let block = try XCTUnwrap(AgentOutputScan.guardBlocks(in: msg).first)
        store.apply(.outputSignals([.guardBlock(block)]), to: a.session)
        XCTAssertEqual(service.signals[a.session]?.guardBlock, block)
        XCTAssertEqual(service.contest(for: a.session)?.holder, "GreenFox")
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.contested, true)
        XCTAssertTrue(service.summary(forProject: SwarmFixtures.project)?.text.contains("1 contested") == true)
        let lines = try XCTUnwrap(service.assignment(for: a.session, now: rig.now)).lines
        XCTAssertTrue(lines.contains("waits on Sources/Foo.swift, held by GreenFox · 6 min"))
        XCTAssertTrue(lines.contains("“\(msg)”"))
    }

    func testAnOrdinaryTabsSignalsAreDroppedAndNeverBuildTheService() {
        let store = SessionStore(provider: nil, persistence: nil)
        let tab = store.newSession(in: URL(fileURLWithPath: "/tmp/ordinary", isDirectory: true))
        XCTAssertNil(store.swarmServiceIfBuilt)
        store.apply(.outputSignals([.blocked("waiting on Sources/Foo.swift")]), to: tab.id)
        XCTAssertNil(store.swarmServiceIfBuilt, "a stray BLOCKED: line must not build the service")
    }

    func testAnOrdinaryTabsSignalsAreNotKeptByABuiltService() {
        let rig = SwarmRig()
        let store = SessionStore(provider: nil, persistence: nil)
        let service = rigService(rig)
        store.useSwarmService(service)
        let tab = store.newSession(in: URL(fileURLWithPath: "/tmp/ordinary", isDirectory: true))
        store.apply(.outputSignals([.blocked("waiting")]), to: tab.id)
        XCTAssertNil(service.signals[tab.id])
    }

    func testDeclaredBlockedNamesIdleAgentsThatSaidBlocked() {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        rig.host.agentsByProject[FlywheelObserveService.key(SwarmFixtures.project)] = [(a.session, "BlueLake")]
        let service = rigService(rig)
        service.recordSignals([.blocked("waiting on the API key")], session: a.session)
        XCTAssertEqual(service.declaredBlocked(project: SwarmFixtures.project), ["BlueLake"])
        rig.host.busy.insert(a.session)
        XCTAssertEqual(service.declaredBlocked(project: SwarmFixtures.project), [], "busy again: no longer blocked")
    }
}
