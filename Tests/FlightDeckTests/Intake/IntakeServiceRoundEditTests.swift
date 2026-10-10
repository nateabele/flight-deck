import XCTest
@testable import IntakeKit
@testable import FlightDeck

/// Records what the service asked of the runner, instead of spawning `fd-abduco`. `onEnsure`
/// runs at the moment the service starts a runner, so a test can read what a runner starting
/// right then would read from disk.
@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    private(set) var ensured: [UUID] = []
    var running: Set<UUID> = []
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    var onEnsure: ((UUID) -> Void)?
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> {
        ensured.append(id)
        onEnsure?(id)
        return .success(())
    }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { running.contains(id) }
    func reap(_ id: UUID) {}
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
}

/// Changing a shaping intake's agents between rounds: the service takes a config only while
/// nothing runs the tape, refuses one that changes what already ran, and a play pressed over an
/// unsaved edit saves it first, so the round it starts runs the agents the editor showed.
@MainActor
final class IntakeServiceRoundEditTests: XCTestCase {
    private var root: URL!
    private var runner: FakeRunnerController!
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeServiceRoundEditTests-\(UUID())", isDirectory: true)
        runner = FakeRunnerController()
        runner.socketDirectory = root
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeService() -> IntakeService {
        IntakeService(store: IntakeStore(root: root),
                      triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                      availableModels: .defaults, runner: runner,
                      inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
    }

    /// A Feature plan intake paused after its draft, with every field a save must keep.
    @discardableResult
    private func seedPaused(_ status: RunnerStatus = .paused, stages: [Stage] = [.draft], state: IntakeState = .shaping) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = state
        i.recommended = .featurePlan
        i.recommendationReason = "Two subsystems."
        i.exchanges = [TriageExchange(questions: ["Q?"], answers: ["A."])]
        i.chosenPreset = .featurePlan
        i.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        var tape = Tape(status: status)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for (n, stage) in stages.enumerated() {
            tape.checkpoints.append(Checkpoint(id: n + 1, stage: stage, round: stage == .refine ? n : 0, major: true, createdAt: at))
        }
        try tapeStore(i.id).saveTape(tape)
        // As read back, so a comparison with a later read is not thrown by date encoding.
        return try onDisk(i.id)
    }

    private func tapeStore(_ id: UUID) -> TapeStore {
        TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id))
    }

    private func onDisk(_ id: UUID) throws -> Intake { try IntakeStore(root: root).load(id: id) }

    private func withGrokReviewer(_ config: RoundConfig?) throws -> RoundConfig {
        var c = try XCTUnwrap(config)
        c.reviewer = Slot(grok)
        c.customized = true
        return c
    }

    // MARK: Accept / refuse by runner state

    func testASavedConfigWhilePausedLandsOnDiskAndKeepsEveryOtherField() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        XCTAssertEqual(svc.roundConfigEditing(seeded.id), .editable)
        let edited = try withGrokReviewer(seeded.roundConfig)

        XCTAssertNil(svc.saveRoundConfig(seeded.id, edited))

        var expected = seeded
        expected.roundConfig = edited
        XCTAssertEqual(try onDisk(seeded.id), expected, "only the config changed")
        XCTAssertEqual(svc.intakes.first { $0.id == seeded.id }?.roundConfig, edited)
    }

    func testAStoppedOrFailedTapeTakesASaveToo() throws {
        for status: RunnerStatus in [.stopped, .failed] {
            let seeded = try seedPaused(status)
            let svc = makeService()
            XCTAssertNil(svc.saveRoundConfig(seeded.id, try withGrokReviewer(seeded.roundConfig)), "\(status)")
        }
    }

    func testASaveWhileTheRunnerRunsIsRefusedWithTheReason() throws {
        let seeded = try seedPaused(.running)
        runner.running = [seeded.id]
        let svc = makeService()
        XCTAssertEqual(svc.roundConfigEditing(seeded.id), .readOnly)

        XCTAssertEqual(svc.saveRoundConfig(seeded.id, try withGrokReviewer(seeded.roundConfig)), "Pause to change agents.")
        XCTAssertEqual(try onDisk(seeded.id), seeded, "nothing was written")
    }

    /// A live runner on a tape whose last write still says paused — the runner just started
    /// and has not written yet — is still running.
    func testALiveRunnerOverAPausedTapeRefusesToo() throws {
        let seeded = try seedPaused(.paused)
        runner.running = [seeded.id]
        let svc = makeService()
        XCTAssertEqual(svc.saveRoundConfig(seeded.id, try withGrokReviewer(seeded.roundConfig)), "Pause to change agents.")
    }

    /// A play just pressed, its runner not yet heard from: the runner may already have read the
    /// config, so a save now would be one the round never sees.
    func testASaveWhileAPlayIsStartingIsRefused() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        svc.send(seeded.id, .step)
        XCTAssertEqual(svc.roundConfigEditing(seeded.id), .readOnly)
        XCTAssertEqual(svc.saveRoundConfig(seeded.id, try withGrokReviewer(seeded.roundConfig)), "Pause to change agents.")
    }

    func testAnAgentThatAlreadyRanCannotBeSaved() throws {
        let seeded = try seedPaused(stages: [.draft, .synthesis])
        let svc = makeService()
        var edited = try XCTUnwrap(seeded.roundConfig)
        edited.synthesizer = Slot(grok)
        XCTAssertEqual(svc.saveRoundConfig(seeded.id, edited), "The synthesizer already ran, so it can't change.")
        XCTAssertEqual(try onDisk(seeded.id), seeded)
    }

    func testOnlyAShapingIntakeTakesASaveThroughThisPath() throws {
        let seeded = try seedPaused(state: .review)
        let svc = makeService()
        XCTAssertNotNil(svc.saveRoundConfig(seeded.id, try withGrokReviewer(seeded.roundConfig)))
        XCTAssertEqual(try onDisk(seeded.id), seeded)
    }

    // MARK: Play over an unsaved edit

    /// Play commits the draft before it queues the command or starts the runner, so a runner
    /// starting at once reads the edited config.
    func testPlayingOverAnUnsavedEditSavesItFirst() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        let edited = try withGrokReviewer(seeded.roundConfig)
        svc.setRoundConfigDraft(seeded.id, edited)
        var readAtStart: RoundConfig?
        var commandsAtStart: [TapeCommand] = []
        runner.onEnsure = { [root] id in
            readAtStart = try? IntakeStore(root: root!).load(id: id).roundConfig
            commandsAtStart = TapeStore(intakeDirectory: IntakeStore(root: root!).directory(for: id)).commands(after: 0).map(\.command)
        }

        svc.send(seeded.id, .nextMajor)

        XCTAssertEqual(readAtStart, edited)
        XCTAssertEqual(commandsAtStart, [.nextMajor])
        XCTAssertNil(svc.roundConfigDrafts[seeded.id], "the draft is spent once saved")
    }

    /// A draft the service can't take blocks the play — it would otherwise run the agents the
    /// editor no longer shows — and says why.
    func testPlayOverADraftThatCannotBeSavedIsHeldBack() throws {
        let seeded = try seedPaused(stages: [.draft])
        let svc = makeService()
        var edited = try XCTUnwrap(seeded.roundConfig)
        edited.drafters[0] = Slot(grok)
        svc.setRoundConfigDraft(seeded.id, edited)

        svc.send(seeded.id, .step)

        XCTAssertTrue(tapeStore(seeded.id).commands(after: 0).isEmpty, "the play was not queued")
        XCTAssertTrue(runner.ensured.isEmpty)
        XCTAssertEqual(svc.roundConfigRefusals[seeded.id], "The drafter already ran, so it can't change.")
        XCTAssertEqual(svc.roundConfigDrafts[seeded.id], edited, "the edit is kept to fix or revert")
    }

    /// Only a play starts rounds, so only a play commits; a note or a pause leaves the draft be.
    func testANonPlayCommandLeavesTheDraftAlone() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        let edited = try withGrokReviewer(seeded.roundConfig)
        svc.setRoundConfigDraft(seeded.id, edited)
        svc.send(seeded.id, .pause)
        XCTAssertEqual(svc.roundConfigDrafts[seeded.id], edited)
        XCTAssertEqual(try onDisk(seeded.id).roundConfig, seeded.roundConfig)
    }

    func testDiscardingADraftLeavesTheSavedConfig() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        svc.setRoundConfigDraft(seeded.id, try withGrokReviewer(seeded.roundConfig))
        svc.setRoundConfigDraft(seeded.id, nil)
        svc.send(seeded.id, .step)
        XCTAssertEqual(try onDisk(seeded.id).roundConfig, seeded.roundConfig)
    }

    /// A draft equal to what is saved is no edit: holding it would mark the panel unsaved.
    func testADraftEqualToTheSavedConfigIsDropped() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        svc.setRoundConfigDraft(seeded.id, seeded.roundConfig)
        XCTAssertNil(svc.roundConfigDrafts[seeded.id])
    }

    func testADraftDiesWithShaping() throws {
        let seeded = try seedPaused()
        let svc = makeService()
        svc.setRoundConfigDraft(seeded.id, try withGrokReviewer(seeded.roundConfig))
        _ = svc.discard(seeded.id)
        XCTAssertNil(svc.roundConfigDrafts[seeded.id])
    }

    // MARK: End to end through the runner

    /// The runner reads `intake.roundConfig` once per start (`IntakeRunner.drive`), so a config
    /// saved while the tape is stopped is the one the next play's runner runs: draft with
    /// reviewer model A, stop, save reviewer model Z, step — and the refine round's reviewer
    /// call asks for Z.
    func testAConfigSavedWhileStoppedIsTheOneTheNextRunnerRuns() async throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let a = ModelChoice(agent: .codex, model: "A", effort: "high")
        var i = Intake(projectPath: project.path, intent: "Add dark mode")
        i.state = .shaping
        i.chosenPreset = .sketch
        i.roundConfig = RoundConfig(drafters: [Slot(a)], synthesizer: nil, reviewer: Slot(a),
                                    integrator: ModelChoice(agent: .claude, model: "B", effort: "medium"), encoder: a,
                                    polisher: nil, refinementCap: 2, polishCap: 0, freshEyesAndDedup: false,
                                    defaultPlay: .step, customized: false)
        try IntakeStore(root: root).save(i)
        let tapes = tapeStore(i.id)
        func runner(_ commands: ScriptedHarnessRunner) -> IntakeRunner {
            IntakeRunner(root: root, intakeID: i.id,
                         executor: RoundExecutor(runner: commands, graphReader: GraphReader(runner: commands, environment: [:])),
                         environment: ["PATH": "/usr/bin:/bin"], pollInterval: .milliseconds(20))
        }

        _ = try tapes.appendCommand(.step)
        let first = ScriptedHarnessRunner { Self.answer($0) }
        let drafted = await runner(first).run()
        XCTAssertEqual(drafted, .paused)
        _ = try tapes.appendCommand(.stop)
        let stopped = await runner(ScriptedHarnessRunner { Self.answer($0) }).run()
        XCTAssertEqual(stopped, .stopped)

        let svc = makeService()
        XCTAssertEqual(svc.roundConfigEditing(i.id), .editable)
        var edited = try XCTUnwrap(try onDisk(i.id).roundConfig)
        edited.reviewer = Slot(ModelChoice(agent: .codex, model: "Z", effort: "high"))
        edited.customized = true
        XCTAssertNil(svc.saveRoundConfig(i.id, edited))

        _ = try tapes.appendCommand(.step)
        let next = ScriptedHarnessRunner { Self.answer($0) }
        let stepped = await runner(next).run()
        XCTAssertEqual(stepped, .paused)
        XCTAssertEqual(tapes.loadTape().checkpoints.map(\.stage), [.draft, .refine])
        XCTAssertEqual(next.calls("reviewer").compactMap(\.model), ["Z"])
    }

    /// Answers each Sketch agent successfully; the integrator really edits `work/plan.md`, or
    /// the executor would pause on an integrator that claimed edits it never made.
    private nonisolated static func answer(_ call: ScriptedHarnessRunner.Call) -> CommandResult {
        switch call.role {
        case "drafter":
            return ok(call, "d", json(DraftOutput(plan: "# Plan\n\n## Scope\nOne\n")))
        case "reviewer":
            return ok(call, "rev", json(ReviewOutput(changes: [ProposedChange(section: "## Scope", rationale: "r", edit: "e")],
                                                     summary: "found 1")))
        case "integrator":
            let plan = call.cwd.appendingPathComponent("plan.md")
            let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
            try? (before + "\n## Added\nline\n").write(to: plan, atomically: true, encoding: .utf8)
            return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 0, disagree: 0, notes: "applied")))
        default:
            return failed("unexpected agent \(call.role)")
        }
    }
}
