import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// The Mac's visual path once it is open (P2a V4): `intake.visual.fetch` is scoped like the other
/// intake reads and served through the real `FleetService`, the detail tells the phone it may
/// ask, and the plan projection lists each block's visual so the reader can lay it out before
/// its bytes arrive. The wire bytes are `VisualWireCodingTests`.
@MainActor
final class VisualIntegrationTests: XCTestCase {
    private var root: URL!
    private var harness: FleetTestHarness!
    private var client: FleetClient!

    private let fetch = FleetRequest.intakeVisualFetch(id: UUID(), visualID: "pairing-handshake", revision: 1,
                                                       part: WireVisualPart.snapshot, offset: 0, limit: 1024)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VisualIntegration-\(UUID())", isDirectory: true)
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

    /// A runner caller is refused every request, a read included (P1: runners get least privilege).
    func testAnIntakeRunnerCallerIsRefusedTheFetch() {
        for level in ControlScopeLevel.allCases {
            XCTAssertFalse(ControlScope.permits(fetch, level: level, caller: .intakeRunner(UUID())), "\(level)")
        }
    }

    // MARK: - Open

    func testTheGateIsOpenAndTheDetailSaysSo() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        XCTAssertTrue(VisualFetch.gateOpen)
        XCTAssertTrue(svc.visualsAvailable)
        let detail = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(detail.visuals, true)
    }

    // MARK: - Plan projection

    private func plan(_ id: UUID, markdown: String, checkpoint: Int = 1) throws {
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id))
        var tape = tapes.loadTape()
        try tapes.writeCheckpoint(Checkpoint(id: checkpoint, parent: checkpoint > 1 ? checkpoint - 1 : nil, stage: .refine,
                                             round: checkpoint, major: true, createdAt: Date()),
                                  files: ["plan.md": Data(markdown.utf8)], into: &tape)
    }
    private func tape(_ id: UUID) -> TapeStore { TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id)) }
    private let visualPlan = "# Plan\n\n## Pairing\n\n```fd-visual id=pairing\nPairing handshake\n```\n\n```fd-visual id=later pending\n```\n"

    /// Each block's visual, with what the phone needs before any bytes: the primary, the kinds,
    /// the states and sizes, the shape from the default snapshot, and every file it may fetch.
    func testThePlanListsEachVisualWithFilesSizesAndAspect() async throws {
        let i = try shapingIntake()
        try plan(i.id, markdown: visualPlan)
        try VisualDiskFixture.install(tape(i.id), id: "pairing", states: ["default", "error"], sizes: ["wide", "narrow"])
        let svc = await makeService()
        let wire = try XCTUnwrap(IntakePlanProjection.plan(i.id, checkpoint: nil, changes: false, service: svc))
        let refs = try XCTUnwrap(wire.visuals)
        XCTAssertEqual(refs.map(\.id), ["pairing"], "a pending placeholder has nothing to list yet")
        let ref = refs[0]
        XCTAssertEqual(ref.revision, 1)
        XCTAssertEqual(ref.kinds, ["sequence"])
        XCTAssertEqual(ref.states, ["default", "error"])
        XCTAssertEqual(ref.sizes, ["wide", "narrow"])
        XCTAssertEqual(ref.aspect ?? 0, 2.0, accuracy: 0.0001, "800 x 400, from the default snapshot's header")
        let manifest = try XCTUnwrap(DiskVisualStore(tape: tape(i.id)).revision(VisualID(rawValue: "pairing")!, r: 1)).manifest
        XCTAssertEqual(ref.files, manifest.files.map { WireVisualFile(path: $0.path, size: $0.size, sha256: $0.sha256) })
        XCTAssertTrue(ref.alternates.isEmpty)
    }

    /// A plan with no visual blocks carries no list, so its wire is what it always was.
    func testAPlanWithNoVisualsCarriesNoList() async throws {
        let i = try shapingIntake()
        try plan(i.id, markdown: "# Plan\n\nJust words.\n")
        let svc = await makeService()
        XCTAssertNil(try XCTUnwrap(IntakePlanProjection.plan(i.id, checkpoint: nil, changes: false, service: svc)).visuals)
    }

    /// An old checkpoint shows its visuals as it recorded them; the other representation is an
    /// alternate, in filmstrip order, with its kind.
    func testACheckpointShowsTheBlockStateItRecordedAndItsAlternates() async throws {
        let i = try shapingIntake()
        try plan(i.id, markdown: visualPlan)
        let t = tape(i.id)
        let id = try VisualDiskFixture.install(t, id: "pairing", r: 1, kind: "sequence")
        try VisualDiskFixture.install(t, id: "pairing", r: 2, kind: "component")
        let both = BlockState(representations: [RevisionRef(visualID: id, r: 1), RevisionRef(visualID: id, r: 2)],
                              primary: RevisionRef(visualID: id, r: 1))
        try IntakeJSON.encoder.encode(CheckpointBlockStates(states: [id: both])).write(to: t.checkpointVisualsURL(1))
        let svc = await makeService()
        let ref = try XCTUnwrap(IntakePlanProjection.plan(i.id, checkpoint: 1, changes: false, service: svc)?.visuals?.first)
        XCTAssertEqual(ref.revision, 1, "checkpoint 1 recorded r1 as primary; block.json now says r2")
        XCTAssertEqual(ref.kinds, ["sequence", "component"])
        XCTAssertEqual(ref.alternates.map(\.revision), [2])
        XCTAssertEqual(ref.alternates.map(\.kind), ["component"])
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

    /// The fetch's worker runs off the main thread; with no reader it is still unavailable.
    func testTheFetchWorkerRunsOffTheMainThread() async {
        nonisolated(unsafe) var ranOnMain: Bool?
        let result = await VisualFetch.serve(EmptyVisualStore(), visualID: "flow", revision: 1, part: "snapshot",
                                             offset: 0, limit: 10, probe: { ranOnMain = Thread.isMainThread })
        XCTAssertEqual(ranOnMain, false)
        XCTAssertEqual(result, .failure(VisualRefusal(code: "unknown_visual")))
        let none = await VisualFetch.serve(nil, visualID: "flow", revision: 1, part: "snapshot", offset: 0, limit: 10)
        XCTAssertEqual(none, .failure(VisualRefusal(code: "visuals_unavailable")))
    }

    /// The real `FleetService` arm over a real socket serves a listed file's bytes, on the
    /// request's own cid.
    func testAFetchThroughFleetServiceServesTheFile() async throws {
        let prefs = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence(),
                                 preferences: prefs, daemonControl: LiveDaemonControl(), intakesRoot: root)
        store.newSession(in: URL(fileURLWithPath: "/w/larkOS-\(UUID().uuidString.prefix(6))", isDirectory: true))
        let i = try shapingIntake(projectPath: store.repos[0].url.standardizedFileURL.path)
        let source = Data("sequenceDiagram\n  A->>B: hi\n".utf8)
        try VisualDiskFixture.install(tape(i.id), id: "pairing-handshake", files: ["diagram.mmd": source])
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
                                                     part: WireVisualPart.file("diagram.mmd"), offset: 0, limit: 1024)
        client.onReady = { [weak self] in sent = self?.client.send(request) ?? 0 }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        guard case .fileChunk(_, let chunk) = try XCTUnwrap(reply) else { return XCTFail("expected a chunk, got \(String(describing: reply))") }
        XCTAssertEqual(chunk.path, "diagram.mmd")
        XCTAssertEqual(chunk.data, source)
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
