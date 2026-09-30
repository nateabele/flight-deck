import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// The `intake.*` commands through the real `FleetService` arm over a real socket, with a
/// shaping intake seeded on disk.
@MainActor
final class IntakeSteerCommandServiceTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient!
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeSteerCommandService-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func send(_ command: FleetCommand) async throws -> ServerFrame {
        let answered = expectation(description: "answered")
        var reply: ServerFrame?
        var sent = 0
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            if let cid = frame.correlationID, cid == sent { reply = frame; answered.fulfill() }
        }
        client.onReady = { [weak self] in sent = self?.client.send(command) ?? 0 }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        client.disconnect()
        return try XCTUnwrap(reply)
    }

    func testTheServiceAppliesRefusesAndRoutesTheFourCommands() async throws {
        // A running tape with a fresh heartbeat and a daemon control that answers "live" for
        // everything: the store's real runner controller never spawns or reaps anything.
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, daemonControl: LiveDaemonControl(), intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        let repo = store.repos[0]
        var i = Intake(projectPath: repo.url.standardizedFileURL.path, intent: "Plan the thing")
        i.state = .shaping
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        // Saved BEFORE the first touch of `store.intakeService`, which loads what is on disk.
        try IntakeStore(root: root).save(i)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        var tape = tapes.loadTape()
        tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .refine, round: 1, major: false)
        tape.heartbeat = Date()
        try tapes.saveTape(tape)
        harness = FleetTestHarness(store: store)
        try await harness.start()

        let pause = try await send(.intakeTape(id: i.id, token: UUID(), command: "pause", stage: nil))
        guard case .ack = pause else { return XCTFail("a running shaping intake must accept pause, got \(pause)") }

        let unknown = try await send(.intakeTape(id: UUID(), token: UUID(), command: "pause", stage: nil))
        guard case .err(_, let code) = unknown else { return XCTFail("expected err, got \(unknown)") }
        XCTAssertEqual(code, "unknown_intake")

        let note = try await send(.intakeNote(id: i.id, token: UUID(), noteID: UUID(), kind: "comment",
                                              text: "why?", checkpoint: nil, block: nil, quote: nil))
        guard case .ack = note else { return XCTFail("a plan-wide note must be accepted, got \(note)") }

        let badMode = try await send(.intakeDefaultPlay(id: i.id, token: UUID(), mode: "bogus"))
        guard case .err(_, let modeCode) = badMode else { return XCTFail("expected err, got \(badMode)") }
        XCTAssertEqual(modeCode, "unknown_mode")

        let gone = try await send(.intakeRemoveNote(id: i.id, token: UUID(), noteID: UUID()))
        guard case .err(_, let removeCode) = gone else { return XCTFail("expected err, got \(gone)") }
        XCTAssertEqual(removeCode, "note_consumed")
    }
}

/// Every daemon answers and nothing is ever signalled (copied from `IntakeFleetEmissionTests`,
/// whose copy is private to its file).
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
