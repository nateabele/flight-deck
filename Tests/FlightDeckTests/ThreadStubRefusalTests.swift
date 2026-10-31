import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// What the Mac does with ask threads before they ship (P1 Task 0): every entry point refuses
/// with `threads_unavailable` and queues nothing, the phone is never told it may ask, and the
/// thread ops are scoped like the sibling intake ops. The wire bytes are `ThreadWireCodingTests`.
@MainActor
final class ThreadStubRefusalTests: XCTestCase {
    /// One of each thread command. Copied from `ThreadWireCodingTests`, which moved to the
    /// window-free FleetKitTests bundle; this app-hosted bundle can no longer reach it.
    private static func commands(intake: UUID, thread: UUID) -> [(FleetCommand, String)] {
        let token = UUID()
        return [
            (.intakeThreadSend(id: intake, token: token, threadID: nil,
                               anchor: WireThreadAnchor(checkpoint: 3, block: 7, quote: "the job"), text: "Why?"),
             "intake.thread.send"),
            (.intakeThreadSend(id: intake, token: token, threadID: thread, anchor: nil, text: "And then?"),
             "intake.thread.send"),
            (.intakeThreadAnswer(id: intake, token: token, threadID: thread,
                                 answers: [WireStructuredAnswer(questionID: "q1", selected: ["a"], other: "and b")]),
             "intake.thread.answer"),
            (.intakeThreadResolve(id: intake, token: token, threadID: thread), "intake.thread.resolve"),
            (.intakeDiffDecide(id: intake, token: token, threadID: thread, diffID: UUID(), accept: true), "intake.diff.decide"),
        ]
    }

    private let thread = UUID()
    private var root: URL!
    private var harness: FleetTestHarness!
    private var client: FleetClient!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadStubs-\(UUID())", isDirectory: true)
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

    /// An intake is a project's, not the asking agent's: fleet-wide, like the sibling intake ops.
    /// The get is a read and is always allowed, like `intake.plan`.
    func testThreadWritesAreFleetWideAndTheGetIsARead() {
        let me = UUID()
        for (command, _) in Self.commands(intake: UUID(), thread: thread) {
            XCTAssertFalse(ControlScope.permits(command, level: .ownSession, caller: .session(me)), "\(command)")
            XCTAssertTrue(ControlScope.permits(command, level: .full, caller: .session(me)), "\(command)")
        }
        XCTAssertTrue(ControlScope.permits(FleetRequest.intakeThreadGet(id: UUID(), threadID: thread, since: nil),
                                           level: .readOnly, caller: .session(me)))
    }

    /// A runner's token names one intake, and that is all it reaches: commands and reads about its
    /// own intake pass at every level, and anything else gets `out_of_scope`.
    func testAnIntakeRunnerCallerReachesOnlyItsOwnIntake() {
        let own = UUID()
        let runner = ControlCaller.intakeRunner(own)
        for level in ControlScopeLevel.allCases {
            for (command, _) in Self.commands(intake: own, thread: thread) {
                XCTAssertTrue(ControlScope.permits(command, level: level, caller: runner), "\(level) \(command)")
            }
            for (command, _) in Self.commands(intake: UUID(), thread: thread) {
                XCTAssertFalse(ControlScope.permits(command, level: level, caller: runner), "\(level) \(command)")
            }
            XCTAssertFalse(ControlScope.permits(FleetCommand.viewing(session: nil), level: level, caller: runner))
            XCTAssertTrue(ControlScope.permits(FleetRequest.intakeThreadGet(id: own, threadID: thread, since: nil),
                                               level: level, caller: runner), "\(level)")
            XCTAssertFalse(ControlScope.permits(FleetRequest.intakeThreadGet(id: UUID(), threadID: thread, since: nil),
                                                level: level, caller: runner), "\(level)")
            XCTAssertFalse(ControlScope.permits(FleetRequest.hostList, level: level, caller: runner), "\(level)")
        }
    }

    // MARK: - Stubs

    func testEveryThreadEntryPointIsRefusedUntilThreadsShip() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let unavailable = IntakeService.threadsUnavailable
        XCTAssertEqual(unavailable, "threads_unavailable")
        XCTAssertFalse(svc.threadsAvailable)
        XCTAssertNil(svc.threadReader(i.id))
        XCTAssertEqual(svc.threadsDirectory(i.id).path, IntakeStore(root: root).directory(for: i.id).appendingPathComponent("threads").path)

        let t = ThreadID(thread)
        XCTAssertEqual(svc.openThread(i.id, anchor: .wholePlan, title: "T", text: "Why?", agent: .codex, model: "m",
                                      effort: "high"), .failure(ThreadRefusal(code: unavailable)))
        XCTAssertEqual(svc.sendThreadMessage(i.id, thread: t, text: "x")?.code, unavailable)
        XCTAssertEqual(svc.answerThread(i.id, thread: t, answers: [])?.code, unavailable)
        XCTAssertEqual(svc.setThreadAutoAccept(i.id, thread: t, true)?.code, unavailable)
        XCTAssertEqual(svc.setThreadAgent(i.id, thread: t, agent: .claude, model: "m", effort: "e")?.code, unavailable)
        XCTAssertEqual(svc.resolveThread(i.id, thread: t)?.code, unavailable)
        XCTAssertEqual(svc.reopenThread(i.id, thread: t)?.code, unavailable)
        XCTAssertEqual(svc.decideDiff(i.id, thread: t, diff: UUID(), accept: true)?.code, unavailable)
        XCTAssertEqual(svc.reproposeDiff(i.id, thread: t, diff: UUID())?.code, unavailable)

        XCTAssertEqual(svc.phoneThreadSend(i.id, token: UUID(), threadID: nil, anchor: nil, text: "x"), unavailable)
        XCTAssertEqual(svc.phoneThreadAnswer(i.id, token: UUID(), threadID: thread, answers: []), unavailable)
        XCTAssertEqual(svc.phoneThreadResolve(i.id, token: UUID(), threadID: thread), unavailable)
        XCTAssertEqual(svc.phoneDiffDecide(i.id, token: UUID(), threadID: thread, diffID: UUID(), accept: false), unavailable)
        XCTAssertEqual(svc.phoneThreadGet(i.id, threadID: thread, since: nil), .failure(ThreadRefusal(code: unavailable)))

        // The Mac UI's binding: an empty reader, and every send refused the same way.
        let binding = svc.threadBinding(for: i.id)
        XCTAssertEqual(binding.intakeID, i.id)
        XCTAssertTrue(binding.reader.threads().isEmpty)
        XCTAssertEqual(binding.open(anchor: .wholePlan, title: "T", text: "x", agent: .codex, model: "m", effort: "e"),
                       .failure(ThreadRefusal(code: unavailable)))
        XCTAssertEqual(binding.send(t, text: "x")?.code, unavailable)
        XCTAssertEqual(binding.decideDiff(t, diff: UUID(), accept: true)?.code, unavailable)

        // Nothing was queued for either runner to act on.
        let store = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        XCTAssertTrue(store.commands(after: 0).isEmpty)
        XCTAssertTrue(ThreadCommandStore(intakeDirectory: store.intakeDirectory).commands(after: 0).isEmpty)

        // And the phone is never told it may ask.
        let detail = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertNil(detail.threads)
    }

    /// The real `FleetService` arm over a real socket answers a thread op with the stub's code.
    func testAThreadOpThroughFleetServiceIsRefusedThreadsUnavailable() async throws {
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
        let command = FleetCommand.intakeThreadSend(id: i.id, token: UUID(), threadID: nil, anchor: nil, text: "Why?")
        client.onReady = { [weak self] in sent = self?.client.send(command) ?? 0 }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        guard case .err(_, let code, _) = try XCTUnwrap(reply) else { return XCTFail("expected err, got \(String(describing: reply))") }
        XCTAssertEqual(code, "threads_unavailable")
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
