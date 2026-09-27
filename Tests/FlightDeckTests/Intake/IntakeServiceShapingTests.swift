import XCTest
import IntakeKit
@testable import FlightDeck

/// Records what the service asked of the runner, instead of spawning `fd-abduco`.
@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    private(set) var ensured: [UUID] = []
    private(set) var reaped: [UUID] = []
    var startResult: Result<Void, RunnerStartError> = .success(())
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> {
        ensured.append(id)
        return startResult
    }
    func isRunning(_ id: UUID) -> Bool { false }
    func reap(_ id: UUID) { reaped.append(id) }
}

/// The app side of planning rounds (Task 11): starting a shaping run, queuing transport
/// commands, following `tape.json` on the shared clock, and landing a finished tape in
/// release review. Every intake is seeded on disk, so no triage turn ever runs.
@MainActor
final class IntakeServiceShapingTests: XCTestCase {
    private var root: URL!
    private var runner: FakeRunnerController!
    private var clock: WatchClock!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeServiceShapingTests-\(UUID())", isDirectory: true)
        runner = FakeRunnerController()
        clock = WatchClock(appIsActive: { false })
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures

    private func makeService() -> IntakeService {
        IntakeService(store: IntakeStore(root: root),
                      triageSettings: TriageSettings(harness: .codex, model: "m1", effort: "high"),
                      availableModels: .defaults, clock: clock, runner: runner,
                      inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
    }

    @discardableResult
    private func seed(_ state: IntakeState, changeSet: ChangeSet? = nil) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = state
        i.recommended = .featurePlan
        i.changeSet = changeSet
        if state == .shaping {
            i.chosenPreset = .featurePlan
            i.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
        }
        try IntakeStore(root: root).save(i)
        return i
    }

    private func tapeStore(_ id: UUID) -> TapeStore {
        TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id))
    }

    private func commands(_ id: UUID) -> [TapeCommand] {
        tapeStore(id).commands(after: 0).map(\.command)
    }

    private func intake(_ svc: IntakeService, _ id: UUID) -> Intake { svc.intakes.first { $0.id == id }! }

    private static let graph = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "T", status: "closed")])
    private static func changeSet(_ reason: String) -> ChangeSet {
        ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 1_800_000_000),
                  ops: [.reopen(id: "b1", reason: reason, pre: Precondition(status: "closed", assignee: nil))])
    }

    /// encode (changeset A) → polish (changeset B) → a plan-only round with no change set,
    /// then the runner's terminal `.reachedReview`.
    private func writeFinishedTape(_ id: UUID, withChangeSets: Bool = true) throws {
        let store = tapeStore(id)
        var tape = store.loadTape()
        let graphData = try IntakeJSON.encoder.encode(Self.graph)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.writeCheckpoint(Checkpoint(id: 1, stage: .encode, round: 0, major: true, createdAt: at),
                                  files: withChangeSets ? ["changeset.json": try Self.changeSet("A").encoded(), "graph.json": graphData]
                                                        : ["plan.md": Data("# plan".utf8)],
                                  into: &tape)
        try store.writeCheckpoint(Checkpoint(id: 2, stage: .polish, round: 1, major: false, createdAt: at),
                                  files: withChangeSets ? ["changeset.json": try Self.changeSet("B").encoded(), "graph.json": graphData]
                                                        : ["plan.md": Data("# plan 2".utf8)],
                                  into: &tape)
        try store.writeCheckpoint(Checkpoint(id: 3, stage: .freshEyes, round: 0, major: true, createdAt: at),
                                  files: ["plan.md": Data("# plan 3".utf8)], into: &tape)
        tape.status = .reachedReview
        try store.saveTape(tape)
    }

    // MARK: tests

    func testChooseFeaturePlanBeginsShapingWithDefaultCommand() throws {
        let seeded = try seed(.awaitingChoice)
        let svc = makeService()
        svc.choose(seeded.id, preset: .featurePlan)

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .shaping)
        XCTAssertEqual(i.chosenPreset, .featurePlan)
        XCTAssertEqual(i.roundConfig, PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(try IntakeStore(root: root).load(id: seeded.id).state, .shaping)
        // Feature plan's defaultPlay is `.nextMajor`.
        XCTAssertEqual(commands(seeded.id), [.nextMajor])
        XCTAssertEqual(runner.ensured, [seeded.id])
    }

    func testBeginShapingKeepsAnEditedConfigAndChooseDoesNotOverwriteIt() throws {
        let seeded = try seed(.awaitingChoice)
        let svc = makeService()
        var edited = PresetExpansion.config(for: .sketch, available: .defaults)!
        edited.refinementCap = 7
        edited.defaultPlay = .step
        edited.customized = true
        svc.beginShaping(seeded.id, preset: .sketch, config: edited)
        // A second path (the plain picker's choose) must not replace the edited config.
        svc.choose(seeded.id, preset: .sketch)

        XCTAssertEqual(intake(svc, seeded.id).roundConfig, edited)
        XCTAssertEqual(commands(seeded.id), [.step])
        XCTAssertEqual(runner.ensured, [seeded.id])
    }

    func testRunnerStartFailureFailsTheIntakeWithTheReason() throws {
        let seeded = try seed(.awaitingChoice)
        runner.startResult = .failure(.noBundledCLI)
        let svc = makeService()
        svc.choose(seeded.id, preset: .sketch)

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .failed)
        XCTAssertTrue(i.failure?.contains("flightdeck") ?? false, i.failure ?? "no failure")
    }

    func testParkedIntakeResumesThroughChoose() throws {
        let seeded = try seed(.parked)
        let svc = makeService()
        svc.choose(seeded.id, preset: .sketch)
        XCTAssertEqual(intake(svc, seeded.id).state, .shaping)
        XCTAssertEqual(commands(seeded.id), [.toReview])
    }

    func testSendPlayRelaunchesRunner() throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        XCTAssertEqual(runner.ensured, [], "an untouched tape has no unfinished work to resume")

        svc.send(seeded.id, .step)
        XCTAssertEqual(runner.ensured, [seeded.id])
        // A paused/stopped runner exits on its own, and a note waits for the next round —
        // none of them needs a runner.
        svc.send(seeded.id, .pause)
        svc.send(seeded.id, .stop)
        svc.send(seeded.id, .annotate("tighten scope"))
        XCTAssertEqual(runner.ensured, [seeded.id])
        svc.send(seeded.id, .toReview)
        XCTAssertEqual(runner.ensured, [seeded.id, seeded.id])
        XCTAssertEqual(commands(seeded.id), [.step, .pause, .stop, .annotate("tighten scope"), .toReview])
    }

    func testTapeChangesArePublishedOnTheClockTick() throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        XCTAssertEqual(svc.tapes[seeded.id]?.status ?? .idle, .idle)

        var tape = Tape()
        tape.status = .running
        tape.target = .nextMajor
        try tapeStore(seeded.id).saveTape(tape)
        clock.fire()
        XCTAssertEqual(svc.tapes[seeded.id]?.status, .running)
    }

    func testReachedReviewMovesIntakeToReviewWithFinalChangeSet() throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        try writeFinishedTape(seeded.id)
        clock.fire()

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .review)
        // The latest checkpoint WITH a change set (polish's B), not the plan-only head.
        XCTAssertEqual(i.changeSet, Self.changeSet("B"))
        XCTAssertEqual(try IntakeStore(root: root).load(id: seeded.id).state, .review)
        XCTAssertEqual(runner.reaped, [seeded.id])
        // Release review validates against the graph that change set was validated against.
        let triageGraph = IntakeStore(root: root).directory(for: seeded.id)
            .appendingPathComponent("triage/graph.json")
        XCTAssertEqual(try IntakeJSON.decoder.decode(GraphSnapshot.self, from: Data(contentsOf: triageGraph)), Self.graph)
    }

    func testReachedReviewWithoutAChangeSetFailsInsteadOfAnEmptyReview() throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        try writeFinishedTape(seeded.id, withChangeSets: false)
        clock.fire()

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .failed)
        XCTAssertNil(i.changeSet)
        XCTAssertNotNil(i.failure)
    }

    func testShapingSurvivesRelaunchAndRespawnsRunner() throws {
        let running = try seed(.shaping)
        var tape = Tape(); tape.status = .running; tape.target = .nextMajor
        try tapeStore(running.id).saveTape(tape)

        let queued = try seed(.shaping)
        tape = Tape(); tape.status = .idle; tape.target = .review
        try tapeStore(queued.id).saveTape(tape)

        let paused = try seed(.shaping)
        tape = Tape(); tape.status = .paused; tape.target = .none
        try tapeStore(paused.id).saveTape(tape)

        let svc = makeService()
        for id in [running.id, queued.id, paused.id] {
            XCTAssertEqual(intake(svc, id).state, .shaping)
            XCTAssertEqual(try IntakeStore(root: root).load(id: id).state, .shaping)
        }
        XCTAssertEqual(Set(runner.ensured), [running.id, queued.id], "a paused tape waits for the user")
        XCTAssertEqual(runner.ensured.count, 2)
    }

    func testPausedTapeCountsForAttention() throws {
        let paused = try seed(.shaping)
        var tape = Tape(); tape.status = .paused
        try tapeStore(paused.id).saveTape(tape)
        let running = try seed(.shaping)
        tape = Tape(); tape.status = .running; tape.target = .review
        try tapeStore(running.id).saveTape(tape)

        let svc = makeService()
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
    }

    func testDiscardWhileShapingStopsRunner() throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        XCTAssertTrue(svc.discard(seeded.id))

        XCTAssertEqual(commands(seeded.id), [.stop])
        XCTAssertEqual(runner.reaped, [seeded.id])
        XCTAssertEqual(intake(svc, seeded.id).state, .discarded)
        XCTAssertEqual(runner.ensured, [])
    }

    func testBeadChoiceUnchanged() throws {
        let seeded = try seed(.awaitingChoice, changeSet: Self.changeSet("A"))
        let svc = makeService()
        svc.choose(seeded.id, preset: .bead)

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .review)
        XCTAssertNil(i.chosenPreset)
        XCTAssertNil(i.roundConfig)
        XCTAssertEqual(commands(seeded.id), [])
        XCTAssertEqual(runner.ensured, [])
    }
}
