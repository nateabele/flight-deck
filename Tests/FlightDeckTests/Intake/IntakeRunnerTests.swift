import XCTest
import Darwin
@testable import IntakeKit

/// `ScriptedHarnessRunner`'s script is synchronous, and the runner's tests need a round that
/// can be held open (to land a command mid-round) or cancelled — so this one awaits its script.
private final class AsyncScriptedRunner: CommandRunner, @unchecked Sendable {
    typealias Call = ScriptedHarnessRunner.Call
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var nextPID: Int32 = 5000
    let script: @Sendable (Call) async throws -> CommandResult

    init(_ script: @escaping @Sendable (Call) async throws -> CommandResult) { self.script = script }

    var calls: [Call] { lock.withLock { _calls } }
    func calls(_ role: String) -> [Call] { calls.filter { $0.executable != "br" && $0.role == role } }

    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, cwd: cwd, environment: environment,
                        processGroup: processGroup)
        let pid: Int32 = lock.withLock { _calls.append(call); nextPID += 1; return nextPID }
        if executable == "br" {
            let out = arguments.first == "list" ? #"{"issues":[{"id":"fd-1","title":"Existing","status":"open","labels":[]}]}"#
                : #"{"components":[{"edges":[]}]}"#
            return CommandResult(stdout: Data(out.utf8), stderr: "", exitCode: 0)
        }
        onSpawn?(pid)
        return try await script(call)
    }
}

/// Holds a harness call open until the test opens it; cancellation (⏹) ends the wait by throwing.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var _entered = 0
    var entered: Int { lock.withLock { _entered } }
    func open() { lock.withLock { isOpen = true } }
    func wait() async throws {
        lock.withLock { _entered += 1 }
        while !lock.withLock({ isOpen }) { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// True exactly once — for a hook that must act on its first call only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

private final class TapeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _tape: Tape?
    var tape: Tape? {
        get { lock.withLock { _tape } }
        set { lock.withLock { _tape = newValue } }
    }
}

private final class PIDCell: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    func set(_ p: Int32) { lock.withLock { pid = p } }
    var value: Int32? { lock.withLock { pid } }
}

final class IntakeRunnerTests: XCTestCase {
    let codexA = ModelChoice(harness: .codex, model: "A", effort: "high")
    let claudeB = ModelChoice(harness: .claude, model: "B", effort: "medium")
    static let draftPlan = "# Plan\n\n## Scope\nOne\n"
    var root: URL!
    var intake: Intake!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        intake = Intake(projectPath: project.path, intent: "Add dark mode")
        // Sketch's shape: draft, refine 1, refine 2 (major), encode.
        intake.roundConfig = RoundConfig(drafters: [Slot(codexA)], synthesizer: nil, reviewer: Slot(codexA),
                                         integrator: claudeB, encoder: codexA, polisher: nil, refinementCap: 2,
                                         polishCap: 0, freshEyesAndDedup: false, defaultPlay: .toReview, customized: false)
        try IntakeStore(root: intakes).save(intake)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    var project: URL { root.appendingPathComponent("project") }
    var intakes: URL { root.appendingPathComponent("intakes") }
    var store: TapeStore { TapeStore(intakeDirectory: IntakeStore(root: intakes).directory(for: intake.id)) }

    fileprivate func runner(_ commands: CommandRunner, id: UUID? = nil, poll: Duration = .milliseconds(20),
                            hooks: IntakeRunner.Hooks = .init()) -> IntakeRunner {
        IntakeRunner(root: intakes, intakeID: id ?? intake.id,
                     executor: RoundExecutor(runner: commands, graphReader: GraphReader(runner: commands, environment: [:])),
                     environment: ["PATH": "/usr/bin:/bin"], pollInterval: poll, now: Date.init, hooks: hooks)
    }

    /// A real `sleep 30` in its own process group, standing in for a harness child.
    func spawnSleeper() async throws -> (pid: Int32, task: Task<CommandResult, Error>) {
        let cell = PIDCell()
        let project = self.project
        let task = Task {
            try await SystemCommandRunner().run(executable: "sleep", arguments: ["30"], cwd: project,
                                                environment: ["PATH": "/usr/bin:/bin"], processGroup: true,
                                                onSpawn: { cell.set($0) })
        }
        try await eventually("a sleeper to spawn") { cell.value != nil }
        return (try XCTUnwrap(cell.value), task)
    }

    /// Answers every Sketch seat successfully. The integrator really edits `work/plan.md`, or the
    /// executor would (rightly) pause on an integrator that claimed edits it never made.
    fileprivate static func answer(_ call: ScriptedHarnessRunner.Call) -> CommandResult {
        switch call.role {
        case "drafter":
            return ok(call, "d", json(DraftOutput(plan: draftPlan)))
        case "reviewer":
            return ok(call, "rev", json(ReviewOutput(changes: [ProposedChange(section: "## Scope", rationale: "r", edit: "e")],
                                                     summary: "found 1")))
        case "integrator":
            let plan = call.cwd.appendingPathComponent("plan.md")
            let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
            try! (before + "\n## Added\nline\n").write(to: plan, atomically: true, encoding: .utf8)
            return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 0, disagree: 0, notes: "applied")))
        case "encoder":
            let cs = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 0),
                               ops: [.editBead(id: "fd-1", set: FieldSet(title: "Renamed"),
                                               pre: Precondition(status: "open", assignee: nil), delivery: nil)])
            return ok(call, "enc", json(ChangeSetOutput(changeSet: cs, summary: "encoded")))
        default:
            return failed("unexpected seat \(call.role)")
        }
    }

    fileprivate func scripted() -> AsyncScriptedRunner { AsyncScriptedRunner { Self.answer($0) } }

    func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Targets

    func testRunsSketchToReview() async throws {
        _ = try store.appendCommand(.toReview)
        let status = await runner(scripted()).run()

        XCTAssertEqual(status, .reachedReview)
        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .reachedReview)
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine, .refine, .encode])
        XCTAssertEqual(tape.checkpoints.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(tape.checkpoints.map(\.parent), [nil, 1, 2, 3])
        XCTAssertNil(tape.roundInProgress)
        XCTAssertNil(tape.runnerPID, "a runner that has exited must not look alive")
        XCTAssertEqual(tape.ackedCommandSeq, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.checkpointDirectory(1).appendingPathComponent("drafts/0.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.checkpointDirectory(4).appendingPathComponent("changeset.json").path))
    }

    func testStepStopsAfterOneRound() async throws {
        _ = try store.appendCommand(.step)
        let commands = scripted()
        let status = await runner(commands).run()

        XCTAssertEqual(status, .paused)
        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .paused)
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft])
        XCTAssertEqual(tape.target, .none, "a reached target is spent, so a restarted runner doesn't run another round")
        XCTAssertEqual(commands.calls("drafter").count, 1)
        XCTAssertTrue(commands.calls("reviewer").isEmpty)
    }

    func testNextMajorStopsAtMajor() async throws {
        _ = try store.appendCommand(.step)
        let status = await runner(scripted()).run()
        XCTAssertEqual(status, .paused)
        _ = try store.appendCommand(.nextMajor)
        let status2 = await runner(scripted()).run()
        XCTAssertEqual(status2, .paused)

        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine, .refine])
        XCTAssertEqual(tape.checkpoints.map(\.major), [true, false, true])
        XCTAssertEqual(tape.ackedCommandSeq, 2)
    }

    func testNewTapeWithNoTargetStaysIdle() async throws {
        let commands = scripted()
        let status = await runner(commands).run()
        XCTAssertEqual(status, .idle)
        XCTAssertEqual(store.loadTape().status, .idle)
        XCTAssertTrue(commands.calls.isEmpty)
    }

    func testMissingConfigFails() async throws {
        intake.roundConfig = nil
        try IntakeStore(root: intakes).save(intake)
        _ = try store.appendCommand(.toReview)
        let commands = scripted()

        let status = await runner(commands).run()

        XCTAssertEqual(status, .failed)
        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .failed)
        XCTAssertNotNil(tape.pauseDiagnosis)
        XCTAssertTrue(commands.calls.isEmpty)
        XCTAssertNil(try IntakeStore(root: intakes).load(id: intake.id).roundConfig, "the runner never writes intake.json")
    }

    /// No `intake.json` means nothing to run and nothing to own: the runner must not adopt,
    /// which would create the intake's directory (and a `tape.json`) for an intake that isn't there.
    func testMissingIntakeFailsWithoutTouchingDisk() async throws {
        let ghost = UUID()
        let commands = scripted()
        let status = await runner(commands, id: ghost).run()
        XCTAssertEqual(status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: IntakeStore(root: intakes).directory(for: ghost).path))
        XCTAssertTrue(commands.calls.isEmpty)
    }

    // MARK: - Exclusivity and exit

    /// Two runners on one intake (the app double-spawning, or a stale runner the app thought
    /// dead): the second finds `runner.lock` held and stands aside without writing the tape.
    func testSecondRunnerOnSameIntakeStandsAside() async throws {
        let gate = Gate()
        let commands = AsyncScriptedRunner { call in
            if call.role == "drafter" { try await gate.wait() }
            return Self.answer(call)
        }
        _ = try store.appendCommand(.step)
        let first = Task { await runner(commands).run() }
        try await eventually("the first runner's round to start") { gate.entered == 1 }

        let second = scripted()
        let secondStatus = await runner(second).run()
        XCTAssertEqual(secondStatus, .running, "reports the lock holder's status")
        XCTAssertTrue(second.calls.isEmpty, "never ran a round")
        let live = store.loadTape()
        XCTAssertEqual(live.runnerPID, getpid(), "the first runner still owns the tape")
        XCTAssertNotNil(live.heartbeat, "the second runner did not write its exit over the live one")
        XCTAssertEqual(live.roundInProgress, PlannedRound(stage: .draft, round: 0, major: true))

        gate.open()
        let status = await first.value
        XCTAssertEqual(status, .paused)
        XCTAssertEqual(store.loadTape().checkpoints.map(\.stage), [.draft])
        XCTAssertEqual(commands.calls("drafter").count, 1)
    }

    /// A ▶ appended after the runner's last command read but before its final save: the app saw a
    /// fresh heartbeat and didn't spawn, so unless the exiting runner notices it, it is stranded.
    func testCommandArrivingAtExitIsNotStranded() async throws {
        let once = Once()
        let tapeStore = store
        _ = try store.appendCommand(.step)
        let commands = scripted()
        let status = await runner(commands, hooks: .init(beforeFinalSave: {
            if once.fire() { _ = try? tapeStore.appendCommand(.step) }
        })).run()

        XCTAssertEqual(status, .paused)
        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine], "the ▶ that landed at exit ran a round")
        XCTAssertEqual(tape.ackedCommandSeq, 2)
        XCTAssertNil(tape.runnerPID)
        XCTAssertNil(tape.heartbeat)
    }

    /// Cancelling the task running `run()` (the CLI wrapper shutting down) must reach the
    /// round: its real child dies and the tape ends stopped, not left mid-round.
    func testCancellingRunKillsTheRoundsChild() async throws {
        let child = PIDCell()
        let real = SystemCommandRunner()
        let commands = AsyncScriptedRunner { call in
            try await real.run(executable: "sleep", arguments: ["30"], cwd: call.cwd, environment: ["PATH": "/usr/bin:/bin"],
                               processGroup: true, onSpawn: { child.set($0) })
        }
        _ = try store.appendCommand(.toReview)
        let run = Task { await runner(commands).run() }
        try await eventually("the drafter child to spawn") { child.value != nil }
        let pid = try XCTUnwrap(child.value)

        let cancelledAt = Date()
        run.cancel()
        let status = await run.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5, "run() returned promptly, not after the child's 30 s")
        XCTAssertEqual(status, .stopped)
        try await eventually("the drafter child to die", timeout: 3) { kill(pid, 0) != 0 }
        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .stopped)
        XCTAssertNil(tape.roundInProgress)
        XCTAssertNil(tape.runnerPID)
        XCTAssertTrue(tape.checkpoints.isEmpty)
    }

    // MARK: - Mid-round commands

    func testPauseStopsAfterCurrentRound() async throws {
        let gate = Gate()
        let commands = AsyncScriptedRunner { call in
            if call.role == "drafter" { try await gate.wait() }
            return Self.answer(call)
        }
        _ = try store.appendCommand(.toReview)
        let run = Task { await runner(commands).run() }
        try await eventually("the draft round to start") { gate.entered == 1 }

        let seq = try store.appendCommand(.pause)
        try await eventually("the watcher to ack ⏸") { self.store.loadTape().ackedCommandSeq == seq }
        XCTAssertEqual(store.loadTape().status, .running, "⏸ lets the round in flight finish")
        gate.open()

        let status = await run.value
        XCTAssertEqual(status, .paused)
        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft], "the round completed and nothing ran after it")
        XCTAssertEqual(tape.status, .paused)
        XCTAssertTrue(commands.calls("reviewer").isEmpty)
    }

    /// A real `sleep 30` through `SystemCommandRunner`'s process-group path stands in for the
    /// drafter: ⏹ must actually kill it, not just stop waiting for it.
    func testStopKillsChildrenAndDiscards() async throws {
        let child = PIDCell()
        let real = SystemCommandRunner()
        let commands = AsyncScriptedRunner { call in
            try await real.run(executable: "sleep", arguments: ["30"], cwd: call.cwd, environment: ["PATH": "/usr/bin:/bin"],
                               processGroup: true, onSpawn: { child.set($0) })
        }
        _ = try store.appendCommand(.toReview)
        let run = Task { await runner(commands).run() }
        try await eventually("the drafter child to spawn") { child.value != nil }
        let pid = try XCTUnwrap(child.value)
        XCTAssertEqual(kill(pid, 0), 0)

        _ = try store.appendCommand(.stop)
        let status = await run.value

        XCTAssertEqual(status, .stopped)
        try await eventually("the drafter child to die", timeout: 3) { kill(pid, 0) != 0 }
        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .stopped)
        XCTAssertTrue(tape.checkpoints.isEmpty, "a stopped round is discarded, never checkpointed")
        XCTAssertNil(tape.roundInProgress)
        XCTAssertNil(tape.runnerPID)
        XCTAssertEqual(tape.ackedCommandSeq, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointDirectory(1).path))
    }

    /// A harness killed by ⏹ can surface as a failed seat (a non-zero exit) rather than a
    /// cancellation, so the executor reports `.paused`. That is still the human's ⏹, not a failure.
    func testPausedRoundDuringStopFinishesStopped() async throws {
        let gate = Gate()
        let commands = AsyncScriptedRunner { _ in
            try? await gate.wait() // returns once cancelled, like a child that died of SIGTERM
            return failed("Terminated: 15")
        }
        _ = try store.appendCommand(.toReview)
        let run = Task { await runner(commands).run() }
        try await eventually("the draft round to start") { gate.entered == 1 }
        _ = try store.appendCommand(.stop)
        let status = await run.value

        XCTAssertEqual(status, .stopped)
        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .stopped)
        XCTAssertNil(tape.pauseDiagnosis, "a ⏹ is not a diagnosis")
        XCTAssertTrue(tape.checkpoints.isEmpty)
    }

    func testStopWhileIdleSetsStopped() async throws {
        _ = try store.appendCommand(.toReview)
        _ = try store.appendCommand(.stop)
        let commands = scripted()
        let status = await runner(commands).run()
        XCTAssertEqual(status, .stopped)
        XCTAssertEqual(store.loadTape().status, .stopped)
        XCTAssertTrue(commands.calls.isEmpty)
    }

    /// The contract the app's liveness check depends on: `heartbeat` keeps moving through a
    /// long round, well inside the 10 s the app allows before it calls the runner dead.
    func testHeartbeatRefreshesDuringLongRound() async throws {
        let gate = Gate()
        let commands = AsyncScriptedRunner { call in
            if call.role == "drafter" { try await gate.wait() }
            return Self.answer(call)
        }
        _ = try store.appendCommand(.step)
        let run = Task { await runner(commands).run() }
        try await eventually("the draft round to start") { gate.entered == 1 }

        let first = try XCTUnwrap(store.loadTape().heartbeat)
        try await eventually("the heartbeat to move") { (self.store.loadTape().heartbeat ?? first) > first }
        let live = store.loadTape()
        XCTAssertEqual(live.status, .running)
        XCTAssertEqual(live.runnerPID, getpid())
        XCTAssertEqual(live.roundInProgress, PlannedRound(stage: .draft, round: 0, major: true))
        gate.open()
        let status = await run.value
        XCTAssertEqual(status, .paused)
        XCTAssertNil(store.loadTape().heartbeat)
    }

    /// The app treats a live runner socket without a fresh heartbeat as suspect, so the runner's
    /// FIRST tape write — before recovery kills anything or a command is folded in — adopts the
    /// tape: `runnerPID` and a fresh `heartbeat`. The injected kill is the observation point:
    /// it runs inside recovery, before recovery (or anything after it) has saved.
    func testFirstWriteAdoptsTheTapeBeforeRecovery() async throws {
        let orphanPID = PIDCell()
        let orphan = Task {
            try await SystemCommandRunner().run(executable: "sleep", arguments: ["30"], cwd: project,
                                                environment: ["PATH": "/usr/bin:/bin"], processGroup: true,
                                                onSpawn: { orphanPID.set($0) })
        }
        try await eventually("the orphan to spawn") { orphanPID.value != nil }
        let pid = try XCTUnwrap(orphanPID.value)
        let runDir = store.runDirectory("draft-0-drafter-0")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(RunRecord(pid: pid, started: Date())).write(to: runDir.appendingPathComponent("run.json"))
        try store.saveTape(Tape(target: .nextMinor, status: .running, runnerPID: 999_999,
                                heartbeat: Date(timeIntervalSinceNow: -60),
                                roundInProgress: PlannedRound(stage: .draft, round: 0, major: true)))
        _ = try store.appendCommand(.annotate("pending"))

        final class Seen: @unchecked Sendable { var tape: Tape? }
        let seen = Seen()
        let tapeStore = store
        let gate = Gate()
        let commands = AsyncScriptedRunner { call in
            if call.role == "drafter" { try await gate.wait() }
            return Self.answer(call)
        }
        let poll = 0.05
        let started = Date()
        let run = Task {
            await IntakeRunner(root: intakes, intakeID: intake.id,
                               executor: RoundExecutor(runner: commands, graphReader: GraphReader(runner: commands, environment: [:])),
                               environment: ["PATH": "/usr/bin:/bin"], pollInterval: .milliseconds(50), now: Date.init,
                               hooks: .init(killGroup: { seen.tape = tapeStore.loadTape(); _ = killpg($0, SIGKILL) })).run()
        }
        try await eventually("the slow round to start") { gate.entered == 1 }

        let atRecovery = try XCTUnwrap(seen.tape, "recovery killed the orphan")
        XCTAssertEqual(atRecovery.runnerPID, getpid(), "adopted before recovery killed anything")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(atRecovery.heartbeat).timeIntervalSince(started), -0.001,
                                    "a fresh heartbeat, not the dead runner's")
        XCTAssertEqual(atRecovery.ackedCommandSeq, 0, "adopted before any command was applied")
        XCTAssertNotNil(atRecovery.roundInProgress, "recovery had not saved yet")
        _ = try? await orphan.value
        XCTAssertNotEqual(kill(pid, 0), 0)

        // Then, through a slow first round, the heartbeat never falls more than a poll behind.
        // One extra poll of slack absorbs scheduler jitter; it is still 100x inside the app's 10 s.
        for _ in 0..<10 {
            let age = Date().timeIntervalSince(try XCTUnwrap(store.loadTape().heartbeat))
            XCTAssertLessThan(age, 2 * poll, "heartbeat \(age)s old mid-round")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        gate.open()
        let status = await run.value
        XCTAssertEqual(status, .paused)
    }

    // MARK: - Recovery

    func testRestartRerunsUnfinishedRound() async throws {
        // The dead runner's drafter, still alive in its own process group.
        let orphanPID = PIDCell()
        let orphan = Task {
            try await SystemCommandRunner().run(executable: "sleep", arguments: ["30"], cwd: project,
                                                environment: ["PATH": "/usr/bin:/bin"], processGroup: true,
                                                onSpawn: { orphanPID.set($0) })
        }
        try await eventually("the orphan to spawn") { orphanPID.value != nil }
        let pid = try XCTUnwrap(orphanPID.value)
        let runDir = store.runDirectory("draft-0-drafter-0")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(RunRecord(pid: pid, started: Date())).write(to: runDir.appendingPathComponent("run.json"))
        try store.saveTape(Tape(target: .nextMinor, status: .running, runnerPID: 999_999,
                                heartbeat: Date(timeIntervalSinceNow: -60),
                                roundInProgress: PlannedRound(stage: .draft, round: 0, major: true)))
        // A live sentinel no recovery may touch, named by two run.json files recovery must skip:
        // one in the interrupted round that already finished (its pid is known dead — any live
        // process there now is someone else's), and one from another round entirely.
        let sentinel = try await spawnSleeper()
        defer { killpg(sentinel.pid, SIGKILL) }
        for (name, finished) in [("draft-0-drafter-1", Date() as Date?), ("refine-1-reviewer", nil)] {
            let dir = store.runDirectory(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try IntakeJSON.encoder.encode(RunRecord(pid: sentinel.pid, started: Date(), finished: finished))
                .write(to: dir.appendingPathComponent("run.json"))
        }

        let commands = scripted()
        let status = await runner(commands).run()

        XCTAssertEqual(status, .paused)
        XCTAssertEqual(kill(sentinel.pid, 0), 0, "recovery killed a finished run's pid or another round's")
        try await eventually("the orphan to be killed", timeout: 3) { kill(pid, 0) != 0 }
        _ = try? await orphan.value
        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft], "the interrupted round reran from scratch")
        XCTAssertEqual(tape.checkpoints.first?.record.note, "rerun after interruption")
        XCTAssertEqual(commands.calls("drafter").count, 1)
        XCTAssertNil(tape.roundInProgress)
    }

    // MARK: - Commands

    func testCommandsAreAckedOnce() async throws {
        _ = try store.appendCommand(.extend(.refine, by: 1))
        _ = try store.appendCommand(.step)
        let status = await runner(scripted()).run()
        XCTAssertEqual(status, .paused)
        XCTAssertEqual(store.loadTape().extraRefinement, 1)
        XCTAssertEqual(store.loadTape().ackedCommandSeq, 2)

        _ = try store.appendCommand(.step)
        let status2 = await runner(scripted()).run()
        XCTAssertEqual(status2, .paused)
        let tape = store.loadTape()
        XCTAssertEqual(tape.extraRefinement, 1, "a restarted runner must not replay an acked ＋")
        XCTAssertEqual(tape.ackedCommandSeq, 3)
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine])
    }

    func testAnnotationsReachNextReviewRound() async throws {
        _ = try store.appendCommand(.step)
        let status = await runner(scripted()).run()
        XCTAssertEqual(status, .paused)

        // "focus on auth" is pending when refine 1 starts; "late" lands while it runs, so it
        // belongs to refine 2, not to the round already in flight.
        let gate = Gate()
        let commands = AsyncScriptedRunner { call in
            if call.role == "reviewer" && call.prompt.contains("focus on auth") { try await gate.wait() }
            return Self.answer(call)
        }
        _ = try store.appendCommand(.annotate("focus on auth"))
        _ = try store.appendCommand(.nextMajor)
        let run = Task { await runner(commands).run() }
        try await eventually("refine 1's reviewer to start") { gate.entered == 1 }
        let seq = try store.appendCommand(.annotate("late"))
        try await eventually("the watcher to ack the annotation") { self.store.loadTape().ackedCommandSeq == seq }
        XCTAssertEqual(store.loadTape().pendingAnnotations, ["focus on auth", "late"])
        gate.open()
        let status2 = await run.value
        XCTAssertEqual(status2, .paused)

        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine, .refine])
        XCTAssertEqual(tape.checkpoints[1].record.annotations, ["focus on auth"])
        XCTAssertEqual(tape.checkpoints[2].record.annotations, ["late"])
        XCTAssertEqual(tape.pendingAnnotations, [], "consumed annotations are removed")
        let reviewers = commands.calls("reviewer")
        XCTAssertEqual(reviewers.count, 2)
        XCTAssertFalse(reviewers[1].prompt.contains("focus on auth"))
        XCTAssertTrue(reviewers[1].prompt.contains("late"))
    }

    func testExtendAddsRefineRound() async throws {
        _ = try store.appendCommand(.extend(.refine, by: 1))
        _ = try store.appendCommand(.toReview)
        let status = await runner(scripted()).run()
        XCTAssertEqual(status, .reachedReview)

        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft, .refine, .refine, .refine, .encode])
        XCTAssertEqual(tape.checkpoints.map(\.round), [0, 1, 2, 3, 0])
        XCTAssertEqual(tape.checkpoints.filter { $0.stage == .refine }.map(\.major), [false, false, true])
    }

    // MARK: - Failure

    func testFailedRoundSetsFailedWithDiagnosis() async throws {
        let commands = AsyncScriptedRunner { _ in failed("Error: 401 Unauthorized") }
        _ = try store.appendCommand(.toReview)
        let status = await runner(commands).run()
        XCTAssertEqual(status, .failed)

        let tape = store.loadTape()
        XCTAssertEqual(tape.status, .failed)
        XCTAssertEqual(tape.pauseDiagnosis?.category, .authExpired)
        XCTAssertTrue(tape.checkpoints.isEmpty)
        XCTAssertNil(tape.roundInProgress)
        XCTAssertNil(tape.runnerPID)

        // A stale failure is not retried by a runner relaunched without a fresh ▶.
        let again = scripted()
        let status2 = await runner(again).run()
        XCTAssertEqual(status2, .failed)
        XCTAssertTrue(again.calls.isEmpty)
        XCTAssertEqual(store.loadTape().pauseDiagnosis?.category, .authExpired)
    }

    /// The round's files land, then the one tape save that records the checkpoint fails. The
    /// tape must not list the checkpoint, and nothing that save would have carried (the
    /// consumed annotation, the spent target, the cleared `roundInProgress`) may leak into a
    /// later save — the files are an orphan a rerun overwrites, never a half-recorded round.
    func testCheckpointWriteIsAtomic() async throws {
        _ = try store.appendCommand(.step)
        let first = await runner(scripted()).run()
        XCTAssertEqual(first, .paused)
        _ = try store.appendCommand(.annotate("focus on auth"))
        _ = try store.appendCommand(.step)

        let once = Once()
        let atExit = TapeBox()
        let tapeStore = store
        let hooks = IntakeRunner.Hooks(
            beforeCheckpointSave: { if once.fire() { throw CocoaError(.fileWriteOutOfSpace) } },
            beforeFinalSave: { atExit.tape = tapeStore.loadTape() })
        let status = await runner(scripted(), hooks: hooks).run()
        XCTAssertEqual(status, .failed)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.checkpointDirectory(2).appendingPathComponent("plan.md").path),
                      "the failure came after the files were written")
        let beforeFinal = try XCTUnwrap(atExit.tape)
        XCTAssertEqual(beforeFinal.checkpoints.map(\.stage), [.draft])
        XCTAssertEqual(beforeFinal.roundInProgress, PlannedRound(stage: .refine, round: 1, major: false),
                       "on disk, the round is still in progress")
        XCTAssertEqual(beforeFinal.pendingAnnotations, ["focus on auth"])

        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.map(\.stage), [.draft])
        XCTAssertEqual(tape.pendingAnnotations, ["focus on auth"], "not consumed by a round that never landed")
        XCTAssertEqual(tape.target, .nextMinor, "not spent by a round that never landed")
        XCTAssertEqual(tape.status, .failed)
    }
}
