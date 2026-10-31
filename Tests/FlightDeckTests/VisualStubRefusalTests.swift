import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// What the Mac does with `intake.visual.fetch` before visuals ship (P2a V0): it is scoped like
/// the other intake reads, refused `visuals_unavailable` through the real `FleetService`, reads
/// nothing, and the phone is never told it may ask. The wire bytes are `VisualWireCodingTests`.
@MainActor
final class VisualStubRefusalTests: XCTestCase {
    private var root: URL!
    private var harness: FleetTestHarness!
    private var client: FleetClient!

    private let fetch = FleetRequest.intakeVisualFetch(id: UUID(), visualID: "pairing-handshake", revision: 1,
                                                       part: WireVisualPart.snapshot, offset: 0, limit: 1024)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VisualStubs-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func shapingIntake(projectPath: String = "/p") throws -> Intake {
        var i = Intake(projectPath: projectPath, intent: "Plan the thing")
        i.state = .shaping
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        return i
    }

    private func makeService() async -> IntakeService {
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: FakeRunnerController(),
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                readFile: { try? Data(contentsOf: $0) }, announce: { _ in })
        await svc.launchRecovery?.value
        return svc
    }

    // MARK: - Scope

    /// A read of a plan's own bytes, like `intake.plan`: allowed at every level, for any session.
    func testTheFetchIsARead() {
        let me = UUID()
        for level in ControlScopeLevel.allCases {
            XCTAssertTrue(ControlScope.permits(fetch, level: level, caller: .session(me)), "\(level)")
        }
        XCTAssertTrue(ControlScope.permits(fetch, level: .readOnly, caller: .human))
    }

    /// A runner reaches nothing until Stream B scopes it to its own intake — a read included.
    func testAnIntakeRunnerCallerIsRefusedTheFetch() {
        for level in ControlScopeLevel.allCases {
            XCTAssertFalse(ControlScope.permits(fetch, level: level, caller: .intakeRunner(UUID())), "\(level)")
        }
    }

    // MARK: - Stub

    func testTheStubRefusesAndReadsNothing() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        XCTAssertEqual(IntakeService.visualsUnavailable, "visuals_unavailable")
        XCTAssertFalse(svc.visualsAvailable)
        // And the phone is never told it may ask.
        let detail = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertNil(detail.visuals)
    }

    /// The store hook V1 reads through is always a disk store, so the editor's hooks never go
    /// stale (`DocumentPlan.==` ignores them): it serves nothing until `visuals/` exists, then
    /// the same value sees it.
    func testTheVisualReaderIsLazyAndSeesAFolderThatAppearsLater() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let reader = try XCTUnwrap(svc.visualReader(i.id) as? DiskVisualStore)
        let id = try XCTUnwrap(VisualID(rawValue: "flow"))
        XCTAssertTrue(reader.visuals().isEmpty)
        XCTAssertNil(reader.blockState(id))

        let tape = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        let rev = tape.revisionDirectory(id, r: 1)
        try FileManager.default.createDirectory(at: rev, withIntermediateDirectories: true)
        let manifest = VisualManifest(provider: "p", providerVersion: "1", kind: "k", title: "T", entry: "a.txt", madeOnCheckpoint: 1,
                                      madeBy: .you, files: [VisualFileEntry(path: "a.txt", size: 0, sha256: "")])
        try IntakeJSON.encoder.encode(manifest).write(to: rev.appendingPathComponent("manifest.json"))
        try Data("hi".utf8).write(to: rev.appendingPathComponent("a.txt"))
        XCTAssertEqual(reader.read(id, r: 1, name: "a.txt", offset: 0, limit: 10)?.data, Data("hi".utf8))
        XCTAssertNil(PlanEditHooks().visuals, "the hook defaults to nil for renders and tests")
    }

    /// The fetch's worker runs off the main thread, and today refuses `visuals_unavailable`.
    func testTheFetchWorkerRunsOffTheMainThreadAndRefuses() async {
        nonisolated(unsafe) var ranOnMain: Bool?
        let result = await VisualFetch.serve(EmptyVisualStore(), visualID: "flow", revision: 1, part: "snapshot",
                                             offset: 0, limit: 10, probe: { ranOnMain = Thread.isMainThread })
        XCTAssertEqual(ranOnMain, false)
        XCTAssertEqual(result, .failure(VisualRefusal(code: "visuals_unavailable")))
        let none = await VisualFetch.serve(nil, visualID: "flow", revision: 1, part: "snapshot", offset: 0, limit: 10)
        XCTAssertEqual(none, .failure(VisualRefusal(code: "visuals_unavailable")))
    }

    /// The real `FleetService` arm over a real socket answers the request with the stub's code,
    /// on the request's own cid.
    func testAFetchThroughFleetServiceIsRefusedVisualsUnavailable() async throws {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, daemonControl: LiveDaemonControl(), intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        let i = try shapingIntake(projectPath: store.repos[0].url.standardizedFileURL.path)
        harness = FleetTestHarness(store: store)
        try await harness.start()

        let answered = expectation(description: "answered")
        var reply: ServerFrame?
        var sent = 0
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            if let cid = frame.correlationID, cid == sent { reply = frame; answered.fulfill() }
        }
        let request = FleetRequest.intakeVisualFetch(id: i.id, visualID: "pairing-handshake", revision: 1,
                                                     part: WireVisualPart.snapshot, offset: 0, limit: 1024)
        client.onReady = { [weak self] in sent = self?.client.send(request) ?? 0 }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        guard case .err(_, let code, _) = try XCTUnwrap(reply) else { return XCTFail("expected err, got \(String(describing: reply))") }
        XCTAssertEqual(code, "visuals_unavailable")
    }
}

@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { false }
    func reap(_ id: UUID) {}
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
}

private final class SilentProcessRunner: FlywheelProcessRunner, @unchecked Sendable {
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) { ("", 127) }
}

private final class InertHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        (Data(), "", 1)
    }
}

/// Every daemon answers and nothing is ever signalled (copied from `IntakeSteerCommandServiceTests`,
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
