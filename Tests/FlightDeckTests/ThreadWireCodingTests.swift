import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// Ask threads on the fleet wire (P1 Task 0): the ops, the reply, the projection fields and the
/// capability flag. Until threads ship every op is refused with `threads_unavailable` and the
/// flag stays off, so a phone never offers what this Mac can't do.
@MainActor
final class ThreadWireCodingTests: XCTestCase {
    private let intake = UUID()
    private let thread = UUID()
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadWire-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private var commands: [(FleetCommand, String)] {
        let token = UUID()
        return [
            (.intakeThreadSend(id: intake, token: token, threadID: nil,
                               anchor: WireThreadAnchor(checkpoint: 3, block: 7, quote: "the job"), text: "Why?"),
             "intake.thread.send"),
            (.intakeThreadSend(id: intake, token: token, threadID: thread, anchor: nil, text: "And then?"),
             "intake.thread.send"),
            (.intakeThreadResolve(id: intake, token: token, threadID: thread), "intake.thread.resolve"),
            (.intakeDiffDecide(id: intake, token: token, threadID: thread, diffID: UUID(), accept: true), "intake.diff.decide"),
        ]
    }

    // MARK: - Ops

    func testEveryThreadCommandRoundTripsUnderItsDottedOp() throws {
        for (command, op) in commands {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: data), command)
            let obj = try object(command)
            XCTAssertEqual(obj["op"] as? String, op)
            XCTAssertEqual(obj["id"] as? String, intake.uuidString, "the intake rides `id`, like the sibling intake ops")
            XCTAssertNotNil(obj["token"])
        }
    }

    /// Opening a thread sends no `threadID` and, about the whole plan, no anchor: both absent,
    /// never null.
    func testANewWholePlanThreadOmitsThreadAndAnchor() throws {
        let obj = try object(FleetCommand.intakeThreadSend(id: intake, token: UUID(), threadID: nil, anchor: nil, text: "t"))
        XCTAssertEqual(Set(obj.keys), ["op", "id", "token", "text"])
    }

    /// A read, so a request (`req`, answered on its `cid`) like `intake.plan`, not a command.
    func testThreadGetIsARequestAnsweredWithAPage() throws {
        for request in [FleetRequest.intakeThreadGet(id: intake, threadID: thread, since: 4),
                        .intakeThreadGet(id: intake, threadID: thread, since: nil)] {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), request)
            XCTAssertEqual(try object(request)["op"] as? String, "intake.thread.get")
        }
        let frame = ServerFrame.intakeThread(cid: 9, Self.page)
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
        XCTAssertEqual(frame.correlationID, 9)
    }

    // MARK: - Projection

    static let summary = WireThreadSummary(
        id: UUID(), title: "Why Unassigned?",
        anchor: WireThreadAnchor(checkpoint: 3, block: 7, quote: "the job", section: "## Scope"),
        status: "needsYou", counts: WireThreadCounts(turns: 2, pendingDiffs: 1, openQuestions: 1),
        excerpt: "Because the dispatcher…")

    static let pendingDiff = WirePendingDiff(id: UUID(), thread: UUID(), checkpoint: 3, quote: "the job stays Unassigned",
                                             old: "the job stays Unassigned", new: "the job stays with its dispatcher",
                                             state: "pending")

    static let page = WireThreadPage(
        thread: summary,
        turns: [WireThreadTurn(seq: 1, messageID: "m1", you: "Why?", answers: nil, reply: "See [cite:d1].",
                               decision: "Keep it.", questions: [WireStructuredQuestion(id: "q1", text: "Q?", kind: "text")],
                               diffs: [pendingDiff.id], errors: [], checkpoint: 3,
                               startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_800_000_010))],
        diffs: [pendingDiff])

    func testProjectionShapesRoundTrip() throws {
        for value in [Self.page] { XCTAssertEqual(try JSONDecoder().decode(WireThreadPage.self, from: JSONEncoder().encode(value)), value) }
        XCTAssertEqual(try JSONDecoder().decode(WireThreadSummary.self, from: JSONEncoder().encode(Self.summary)), Self.summary)
        XCTAssertEqual(try JSONDecoder().decode(WirePendingDiff.self, from: JSONEncoder().encode(Self.pendingDiff)), Self.pendingDiff)
    }

    /// A status a later Mac invents still decodes: it is a string on the wire for that reason.
    func testAnUnknownStatusStringStillDecodes() throws {
        var summary = Self.summary
        summary.status = "someFutureStatus"
        XCTAssertEqual(try JSONDecoder().decode(WireThreadSummary.self, from: JSONEncoder().encode(summary)).status,
                       "someFutureStatus")
    }

    /// An old Mac's detail has no `threads` flag: the phone reads nil and offers no Ask.
    func testAnOldMacsDetailAndPlanHaveNoThreads() throws {
        let detail = WireIntakeDetail(
            etag: "e", project: UUID(),
            summary: WireIntakeSummary(id: UUID(), title: "T", state: "shaping", needsAttention: false,
                                       createdAt: Date(timeIntervalSince1970: 1)),
            intent: "i", servedAt: Date(timeIntervalSince1970: 2), structuredQuestions: true)
        var obj = try object(detail)
        XCTAssertNil(obj["threads"], "nil is absent, so the bytes an old phone reads are unchanged")
        obj.removeValue(forKey: "threads")
        let decoded = try JSONDecoder().decode(WireIntakeDetail.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(decoded.threads)

        let plan = WireIntakePlan(checkpoint: 1, roundName: "Draft", editsVersion: "", markdown: "# P")
        let planObj = try object(plan)
        XCTAssertNil(planObj["threads"])
        XCTAssertNil(planObj["pendingDiffs"])
        let old = ##"{"checkpoint":1,"roundName":"Draft","editsVersion":"","markdown":"# P","outline":[],"notes":[]}"##
        let oldPlan = try JSONDecoder().decode(WireIntakePlan.self, from: Data(old.utf8))
        XCTAssertNil(oldPlan.threads)
        XCTAssertNil(oldPlan.pendingDiffs)

        var withThreads = plan
        withThreads.threads = [Self.summary]
        withThreads.pendingDiffs = [Self.pendingDiff]
        XCTAssertEqual(try JSONDecoder().decode(WireIntakePlan.self, from: JSONEncoder().encode(withThreads)), withThreads)
    }

    // MARK: - Scope

    /// An intake is a project's, not the asking agent's: fleet-wide, like the sibling intake ops.
    /// The get is a read and is always allowed, like `intake.plan`.
    func testThreadWritesAreFleetWideAndTheGetIsARead() {
        let me = UUID()
        for (command, _) in commands {
            XCTAssertFalse(ControlScope.permits(command, level: .ownSession, caller: .session(me)), "\(command)")
            XCTAssertTrue(ControlScope.permits(command, level: .full, caller: .session(me)), "\(command)")
        }
        XCTAssertTrue(ControlScope.permits(FleetRequest.intakeThreadGet(id: intake, threadID: thread, since: nil),
                                           level: .readOnly, caller: .session(me)))
    }

    // MARK: - Stubs

    func testEveryThreadEntryPointIsRefusedUntilThreadsShip() async throws {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = .shaping
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: FakeRunnerController(),
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                readFile: { try? Data(contentsOf: $0) }, announce: { _ in })
        await svc.launchRecovery?.value
        let unavailable = IntakeService.threadsUnavailable
        XCTAssertEqual(unavailable, "threads_unavailable")
        XCTAssertFalse(svc.threadsAvailable)
        XCTAssertNil(svc.threadReader(i.id))

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
        XCTAssertEqual(svc.phoneThreadResolve(i.id, token: UUID(), threadID: thread), unavailable)
        XCTAssertEqual(svc.phoneDiffDecide(i.id, token: UUID(), threadID: thread, diffID: UUID(), accept: false), unavailable)
        XCTAssertEqual(svc.phoneThreadGet(i.id, threadID: thread, since: nil), .failure(ThreadRefusal(code: unavailable)))

        // Nothing was queued for a runner to act on.
        let store = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        XCTAssertTrue(store.commands(after: 0).isEmpty)

        // And the phone is never told it may ask.
        let detail = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertNil(detail.threads)
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
