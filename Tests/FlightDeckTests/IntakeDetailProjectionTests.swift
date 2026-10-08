import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// Records what the service asked of the runner, instead of spawning `fd-abduco` — copied from
/// `IntakeServiceLiveTests`, whose copy is private to its file.
@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    var running: Set<UUID> = []
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { running.contains(id) }
    func reap(_ id: UUID) {}
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
}

/// `br`/`bv` answer nothing; no test here reaches them.
private final class SilentProcessRunner: FlywheelProcessRunner, @unchecked Sendable {
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) { ("", 127) }
}

/// A triage harness that never answers — no test here starts a turn, and one must never spawn.
private final class InertHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        (Data(), "", 1)
    }
}

/// The intake screen's content as the phone fetches it (spec §6.2), built by a real
/// `IntakeService` over a temp root and a fake runner — so no real runner or harness spawns.
@MainActor
final class IntakeDetailProjectionTests: XCTestCase {
    private var root: URL!
    private var runner: FakeRunnerController!
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeDetailProjectionTests-\(UUID())", isDirectory: true)
        runner = FakeRunnerController()
        runner.socketDirectory = root
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures (from IntakeServiceLiveTests)

    private func makeService() async -> IntakeService {
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { [unowned self] in self.clockNow },
                                readFile: { try? Data(contentsOf: $0) },
                                announce: { _ in })
        await svc.launchRecovery?.value
        for i in svc.intakes { await svc.convergenceFold(for: i.id)?.value }
        return svc
    }

    @discardableResult
    private func seed(_ state: IntakeState) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = state
        i.recommended = .featurePlan
        if state == .needsAnswers { i.exchanges = [TriageExchange(questions: ["Which README?"])] }
        if state == .shaping || state == .awaitingChoice {
            i.chosenPreset = .featurePlan
            i.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        }
        try IntakeStore(root: root).save(i)
        return i
    }

    private func tapeStore(_ id: UUID) -> TapeStore {
        TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id))
    }

    private func updateTape(_ id: UUID, _ change: (inout Tape) -> Void) throws {
        var tape = tapeStore(id).loadTape()
        change(&tape)
        try tapeStore(id).saveTape(tape)
    }

    /// `modified` pins the files' mtime: the service re-reads a seat file only when its mtime
    /// moves, and two writes inside one test can otherwise land on the same one.
    private func writeSeat(_ id: UUID, run: String, activity: SeatActivity?, record: RunRecord?,
                           modified: Date? = nil) throws {
        let dir = tapeStore(id).runDirectory(run)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [URL] = []
        if let activity {
            let url = dir.appendingPathComponent("activity.json")
            try IntakeJSON.encoder.encode(activity).write(to: url)
            files.append(url)
        }
        if let record {
            let url = dir.appendingPathComponent("run.json")
            try IntakeJSON.encoder.encode(record).write(to: url)
            files.append(url)
        }
        if let modified {
            for url in files { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
    }

    private func writeCheckpointFile(_ id: UUID, checkpoint: Int, _ name: String, _ text: String) throws {
        let dir = tapeStore(id).checkpointDirectory(checkpoint)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// A shaping intake with draft 0 in the air and one drafter reporting.
    private func seedRunningDraft() throws -> (Intake, SeatActivity) {
        let i = try seed(.shaping)
        try updateTape(i.id) { tape in
            tape.status = .running
            tape.roundInProgress = PlannedRound(stage: .draft, round: 0, major: true)
            tape.roundStartedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        }
        var activity = SeatActivity(agent: .claude, startedAt: Date(timeIntervalSinceReferenceDate: 5_001))
        activity.headline = "Reading the repo"
        activity.lastEventAt = Date(timeIntervalSinceReferenceDate: 5_010)
        try writeSeat(i.id, run: "draft-0-drafter-0", activity: activity, record: nil,
                      modified: Date(timeIntervalSince1970: 1_700_000_000))
        return (i, activity)
    }

    // MARK: detail

    func testAShapingDetailCarriesBoardAgentsAndRoundsWithNoClockInIt() async throws {
        let (i, activity) = try seedRunningDraft()
        let svc = await makeService()
        svc.pollTapes()

        let a = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc,
                                                             servedAt: Date(timeIntervalSinceReferenceDate: 6_000)))
        let b = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: a.project, service: svc,
                                                             servedAt: Date(timeIntervalSinceReferenceDate: 9_000)))
        XCTAssertEqual(a.etag, b.etag, "nothing changed but the time: the etag must not move")
        XCTAssertEqual(a.board?.clockSince, Date(timeIntervalSinceReferenceDate: 5_000))
        XCTAssertEqual(a.board?.clockCaption, "IN THE AIR")
        XCTAssertNil(a.board?.slots.first { $0.state == "live" }?.duration, "a live slot's duration is the phone's clock")
        let agent = try XCTUnwrap(a.agents.first { $0.id == "draft-0-drafter-0" })
        XCTAssertEqual(agent.headline, "Reading the repo")
        XCTAssertEqual(agent.lastEventAt, activity.lastEventAt)
        XCTAssertNil(agent.duration)
    }

    func testTheEtagMovesWhenAnAgentReportsSomethingNew() async throws {
        let (i, activity) = try seedRunningDraft()
        let svc = await makeService()
        svc.pollTapes()
        let before = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))

        var next = activity
        next.headline = "Writing the draft"
        next.lastEventAt = Date(timeIntervalSinceReferenceDate: 5_030)
        try writeSeat(i.id, run: "draft-0-drafter-0", activity: next, record: nil,
                      modified: Date(timeIntervalSince1970: 1_700_000_100))
        svc.pollTapes()
        let after = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: before.project, service: svc, servedAt: Date()))

        XCTAssertEqual(after.agents.first { $0.id == "draft-0-drafter-0" }?.headline, "Writing the draft")
        XCTAssertNotEqual(before.etag, after.etag)
    }

    /// The phone's keys come from the Mac's `TransportRules`, never its own guess: a running
    /// round offers Pause and Stop only (Annotate is never sent — notes have their own gate), and
    /// `steer` is this Mac's licence for the phone to send `intake.*` at all.
    func testAShapingDetailCarriesControlsAndSteer() async throws {
        let (running, _) = try seedRunningDraft()
        let paused = try seed(.shaping)
        try updateTape(paused.id) { tape in
            tape.status = .paused
            tape.checkpoints = [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: self.clockNow),
                                Checkpoint(id: 2, stage: .synthesis, round: 0, major: true, createdAt: self.clockNow)]
        }
        let svc = await makeService()
        svc.pollTapes()
        let r = try XCTUnwrap(IntakeDetailProjection.detail(running.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(r.board?.controls?.enabled, ["pause", "stop"])
        XCTAssertEqual(r.steer, true)

        let p = try XCTUnwrap(IntakeDetailProjection.detail(paused.id, project: UUID(), service: svc, servedAt: Date()))
        let controls = try XCTUnwrap(p.board?.controls)
        XCTAssertEqual(controls.enabled, ["step", "nextMajor", "toReview", "extend", "trim"])
        XCTAssertEqual(controls.extendStage, "refine")
        XCTAssertEqual(controls.trimStage, "refine")
        XCTAssertEqual(controls.cycleName, "Refine")
        let refineSlots = try XCTUnwrap(p.board?.slots.filter { $0.group == "REFINE" }.count)
        XCTAssertGreaterThan(refineSlots, 0)
        XCTAssertEqual(controls.cyclePlanned, refineSlots)
    }

    func testTheEtagIsStableWithControls() async throws {
        let (i, _) = try seedRunningDraft()
        let svc = await makeService()
        svc.pollTapes()
        let a = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc,
                                                             servedAt: Date(timeIntervalSinceReferenceDate: 6_000)))
        let b = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: a.project, service: svc,
                                                             servedAt: Date(timeIntervalSinceReferenceDate: 9_000)))
        XCTAssertNotNil(a.board?.controls)
        XCTAssertEqual(a.etag, b.etag, "controls carry no clock: only servedAt differs, so the etag must not move")
    }

    func testNeedsAnswersCarriesOpenAndAnsweredRounds() async throws {
        var i = try seed(.needsAnswers)
        i.exchanges = [TriageExchange(questions: ["Both?"], answers: ["Both"]), TriageExchange(questions: ["Who?", "Where?"])]
        try IntakeStore(root: root).save(i)
        let svc = await makeService()
        let d = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(d.questions?.open, ["Who?", "Where?"])
        XCTAssertEqual(d.questions?.answered, [WireExchange(questions: ["Both?"], answers: ["Both"])])
    }

    func testAFailureTailIsCappedAtFourKilobytes() async throws {
        var i = try seed(.failed)
        i.failure = "codex exited 1"
        i.rawFailureOutput = String(repeating: "x", count: 10_000) + "THE END"
        try IntakeStore(root: root).save(i)
        let svc = await makeService()
        let d = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(d.failure?.reason, "codex exited 1")
        XCTAssertEqual(d.failure?.output?.utf8.count, IntakeDetailProjection.failureOutputLimit)
        XCTAssertTrue(d.failure?.output?.hasSuffix("THE END") == true, "the TAIL is kept")
    }

    /// A cut landing inside a multi-byte character must not blank the tail: it moves forward to
    /// the next character, so the tail is a few bytes short of the limit, never empty.
    func testAFailureTailCutMidCharacterKeepsWholeCharacters() {
        let text = String(repeating: "é", count: 3_000) // 2 bytes each: an odd limit cuts one
        let tail = IntakeDetailProjection.tail(text, limit: 4_095)
        XCTAssertEqual(tail.utf8.count, 4_094)
        XCTAssertTrue(tail.allSatisfy { $0 == "é" })
        XCTAssertEqual(IntakeDetailProjection.tail("short", limit: 4_096), "short")
    }

    func testAnUnknownIntakeIsNil() async {
        let svc = await makeService()
        XCTAssertNil(IntakeDetailProjection.detail(UUID(), project: UUID(), service: svc, servedAt: Date()))
    }

    // MARK: plan

    func testThePlanLocatesNotesAndDiffsAgainstThePreviousPlan() async throws {
        let i = try seed(.shaping)
        let note = PlanNote(kind: .question, note: "why?", anchor: NoteAnchor(checkpoint: 2, quote: "Second step"))
        try updateTape(i.id) { tape in
            tape.checkpoints = [
                Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date(timeIntervalSinceReferenceDate: 100)),
                Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true,
                           createdAt: Date(timeIntervalSinceReferenceDate: 200)),
            ]
            tape.status = .paused
            tape.pendingNotes = [note]
        }
        try writeCheckpointFile(i.id, checkpoint: 1, "plan.md", "# P\n\n## 1. Scope\n\nFirst step.\n\nOld step.")
        try writeCheckpointFile(i.id, checkpoint: 2, "plan.md", "# P\n\n## 1. Scope\n\nFirst step.\n\nSecond step.")
        let svc = await makeService()
        svc.pollTapes()

        let plan = try XCTUnwrap(IntakePlanProjection.plan(i.id, checkpoint: nil, changes: true, service: svc))
        XCTAssertEqual(plan.checkpoint, 2, "no checkpoint asked for: the plan head")
        XCTAssertEqual(plan.roundName, "Synthesis")
        XCTAssertEqual(plan.outline.map(\.heading), ["1. Scope"])
        let blocks = PlanBlocks.split(plan.markdown)
        XCTAssertEqual(plan.added?.map { blocks.blocks[$0].text }, ["Second step."])
        XCTAssertEqual(plan.removed?.map(\.text), ["Old step."])
        let located = try XCTUnwrap(plan.notes.first { $0.id == note.id })
        XCTAssertEqual(located.blockIndex.map { blocks.blocks[$0].text }, "Second step.")
        XCTAssertFalse(located.consumed)
        XCTAssertEqual(plan.editsVersion, "", "no human edit on this checkpoint")

        let first = try XCTUnwrap(IntakePlanProjection.plan(i.id, checkpoint: 1, changes: false, service: svc))
        XCTAssertNil(first.added)
        XCTAssertTrue(first.markdown.contains("Old step."))
        XCTAssertNil(IntakePlanProjection.plan(i.id, checkpoint: 9, changes: false, service: svc))
    }
}
