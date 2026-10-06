import Combine
import XCTest
import IntakeKit
@testable import FlightDeck

/// Records what the service asked of the runner, instead of spawning `fd-abduco`. `running`
/// is scriptable between ticks; `reap` records only calls made while the fake says the runner
/// is NOT running, since the real controller's `reap` is a no-op otherwise.
@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    private(set) var ensured: [UUID] = []
    private(set) var reaped: [UUID] = []
    var running: Set<UUID> = []
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    var startResult: Result<Void, RunnerStartError> = .success(())
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> {
        ensured.append(id)
        return startResult
    }
    /// The tape each liveness check was handed (nil: the caller had none).
    private(set) var runningChecks: [Tape?] = []
    func isRunning(_ id: UUID, tape: Tape?) -> Bool {
        runningChecks.append(tape)
        return running.contains(id)
    }
    func reap(_ id: UUID) { if !running.contains(id) { reaped.append(id) } }
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("intake-\(id.uuidString.lowercased()).sock").path
    }
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
        runner.socketDirectory = root
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

    private func saveTape(_ id: UUID, _ status: RunnerStatus, target: TapeTarget = .none) throws {
        var tape = tapeStore(id).loadTape()
        tape.status = status
        tape.target = target
        try tapeStore(id).saveTape(tape)
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

    func testSendPlayRelaunchesRunner() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        XCTAssertEqual(runner.ensured, [], "an untouched tape has no unfinished work to resume")

        svc.send(seeded.id, .step)
        XCTAssertEqual(runner.ensured, [seeded.id])
        // With a live runner, pause and stop are just read by it; a note waits for the next
        // round. None of them spawns.
        runner.running = [seeded.id]
        svc.send(seeded.id, .pause)
        svc.send(seeded.id, .stop)
        svc.send(seeded.id, .annotate("tighten scope"))
        XCTAssertEqual(runner.ensured, [seeded.id])
        runner.running = []
        svc.send(seeded.id, .toReview)
        XCTAssertEqual(runner.ensured, [seeded.id, seeded.id])
        XCTAssertEqual(commands(seeded.id), [.step, .pause, .stop, .annotate("tighten scope"), .toReview])
    }

    /// Left unread, a stop would be the first thing the NEXT play's runner saw — so that play
    /// did nothing. A runner is started to consume it instead.
    func testStopWithNoRunnerStartsOneToConsumeIt() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        svc.send(seeded.id, .stop)
        XCTAssertEqual(runner.ensured, [seeded.id])
        // Pause with no runner stays a plain append: the next play overrides it in order.
        svc.send(seeded.id, .pause)
        XCTAssertEqual(runner.ensured, [seeded.id])
        XCTAssertEqual(commands(seeded.id), [.stop, .pause])
    }

    /// A pause or stop is remembered with its sequence number until the runner acknowledges
    /// it — what "Pausing…"/"Stopping…" wait on — and a play sent after it supersedes it.
    func testHaltIsHeldUntilAcked() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        svc.send(seeded.id, .pause)
        XCTAssertEqual(svc.halts[seeded.id], HaltRequest(kind: .pause, seq: 1))
        svc.send(seeded.id, .stop)
        XCTAssertEqual(svc.halts[seeded.id], HaltRequest(kind: .stop, seq: 2))

        var tape = tapeStore(seeded.id).loadTape()
        tape.status = .running
        tape.ackedCommandSeq = 2
        try tapeStore(seeded.id).saveTape(tape)
        svc.pollTapes()
        XCTAssertNil(svc.halts[seeded.id], "acknowledged: nothing left to wait on")

        svc.send(seeded.id, .pause)
        svc.send(seeded.id, .step)
        XCTAssertNil(svc.halts[seeded.id], "a play after the pause supersedes it")
    }

    // MARK: optimistic tape

    /// What the runner writes: `mutate` applied to the tape on disk, with `tape.json`'s mtime
    /// moved on explicitly so the service's mtime gate can't skip the read.
    private func runnerWrites(_ id: UUID, _ mutate: (inout Tape) -> Void) throws {
        let store = tapeStore(id)
        var tape = store.loadTape()
        mutate(&tape)
        try store.saveTape(tape)
        writes += 1
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: TimeInterval(writes))],
                                              ofItemAtPath: store.tapeURL.path)
    }
    private var writes = 0

    /// The runner folding every queued command up to `seq`, exactly as `TapeKeeper.applyCommands` does.
    private func runnerConsumes(_ id: UUID, through seq: Int, config: RoundConfig?) throws {
        try runnerWrites(id) { tape in
            for envelope in tapeStore(id).commands(after: tape.ackedCommandSeq) where envelope.seq <= seq {
                TapePlanner.apply(envelope.command, to: &tape, config: config)
                tape.ackedCommandSeq = envelope.seq
            }
        }
    }

    private func refineRounds(_ svc: IntakeService, _ id: UUID) -> Int? {
        let i = intake(svc, id)
        guard let tape = svc.tapes[id], let config = i.roundConfig else { return nil }
        let board = BoardModel(intake: i, tape: tape, config: config, now: Date(), selected: nil, preview: nil)
        return board.groups.first { $0.name == "REFINE" }?.range.count
    }

    /// The maintainer: "the +/- buttons … don't seem to respond right away". The board is drawn from
    /// `tapes`, which only the runner's next write (up to its 1 s poll) and the service's next
    /// tick (500 ms) used to move — 0.4–1.3 s measured. A click must show in its own turn.
    func testExtendAndTrimShowOnTheBoardInTheSameTurn() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .paused)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        XCTAssertEqual(refineRounds(svc, seeded.id), 3)

        svc.send(seeded.id, .extend(.refine, by: 1))
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, 1)
        XCTAssertEqual(refineRounds(svc, seeded.id), 4, "the bracket grows before any tick or runner write")
        svc.send(seeded.id, .trim(.refine, by: 1))
        XCTAssertEqual(refineRounds(svc, seeded.id), 3)
        XCTAssertEqual(tapeStore(seeded.id).loadTape().extraRefinement, 0, "the app never writes the runner's tape")
    }

    /// A tape the runner wrote before reading the click (a heartbeat, a round landing) must not
    /// drag the board back to the old count: the command is re-applied until the tape acks it.
    func testATapeReadBeforeTheRunnerConsumesDoesNotRevertTheClick() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .running, target: .nextMajor)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        svc.send(seeded.id, .extend(.polish, by: 1))
        XCTAssertEqual(svc.tapes[seeded.id]?.extraPolish, 1)

        try runnerWrites(seeded.id) { $0.heartbeat = Date() }
        svc.pollTapes()
        XCTAssertEqual(svc.tapes[seeded.id]?.extraPolish, 1, "no flicker back to the old count")
        XCTAssertEqual(svc.tapes[seeded.id]?.heartbeat, nil, "a heartbeat alone still isn't republished")
    }

    /// + + + − each show at once, and whatever the runner has consumed so far is the base the
    /// rest are replayed on — so the board ends exactly where the runner does.
    func testRapidClicksEachShowAndConvergeOnTheRunner() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .paused)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        let config = intake(svc, seeded.id).roundConfig
        var shown: [Int?] = []
        for _ in 0..<3 {
            svc.send(seeded.id, .extend(.refine, by: 1))
            shown.append(svc.tapes[seeded.id]?.extraRefinement)
        }
        XCTAssertEqual(shown, [1, 2, 3])

        try runnerConsumes(seeded.id, through: 1, config: config)
        svc.pollTapes()
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, 3, "one consumed, two still replayed on top")
        svc.send(seeded.id, .trim(.refine, by: 1))
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, 2)

        try runnerConsumes(seeded.id, through: 4, config: config)
        svc.pollTapes()
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, 2)
        XCTAssertEqual(svc.tapes[seeded.id], tapeStore(seeded.id).loadTape(), "all consumed: the runner's tape, as is")
    }

    /// The runner folds a trim against ITS tape, which may have moved on (a round started) —
    /// its clamp is the truth, and the click's guess must not outlive the ack.
    func testAClampedTrimConvergesOnTheRunnerAndLeavesNoOverlay() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .running, target: .review)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        svc.send(seeded.id, .trim(.refine, by: 1))
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, -1, "shown at once")

        // Refine 3 was already in flight when the runner read it: nothing to take off.
        try runnerWrites(seeded.id) { tape in
            tape.roundInProgress = PlannedRound(stage: .refine, round: 3, major: true)
            tape.ackedCommandSeq = 1
        }
        svc.pollTapes()
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, 0, "the runner's clamp wins")

        // A later runner write changes the count on its own: shown as written, nothing replayed.
        try runnerWrites(seeded.id) { $0.extraRefinement = 2 }
        svc.pollTapes()
        XCTAssertEqual(svc.tapes[seeded.id]?.extraRefinement, 2, "no stale overlay left behind")
    }

    /// Play and pause move STOPS AT on a running tape (`BoardModel.mode(for: target)`), so they
    /// have the same lag — but the pause's "Pausing…" must still wait for the runner's ack.
    func testPlayAndPauseRetargetARunningTapeAtOnceButPausingStillWaits() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .running, target: .nextMinor)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        svc.send(seeded.id, .toReview)
        XCTAssertEqual(svc.tapes[seeded.id]?.target, .review)
        svc.send(seeded.id, .pause)
        XCTAssertEqual(svc.tapes[seeded.id]?.target, TapeTarget.none)
        let tape = try XCTUnwrap(svc.tapes[seeded.id])
        XCTAssertEqual(svc.halts[seeded.id]?.label(for: tape), "Pausing…", "the ack is the runner's alone to give")
        // Stop and notes are not folded ahead: the runner handles ⏹ itself, and the notes rail
        // keeps its own optimistic copy.
        svc.send(seeded.id, .annotate("n"))
        XCTAssertEqual(svc.tapes[seeded.id]?.pendingNotes, [])
    }

    /// Clicking a play button makes it the default (spec §4), kept on the intake's config so
    /// the dot is still under it after a relaunch.
    func testSetDefaultPlayPersists() throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        XCTAssertEqual(intake(svc, seeded.id).roundConfig?.defaultPlay, .nextMajor)
        svc.setDefaultPlay(seeded.id, .step)
        XCTAssertEqual(intake(svc, seeded.id).roundConfig?.defaultPlay, .step)
        XCTAssertEqual(try IntakeStore(root: root).load(id: seeded.id).roundConfig?.defaultPlay, .step)
        XCTAssertEqual(intake(svc, seeded.id).roundConfig?.customized, true, "an edit like any other in the Rounds editor")
        XCTAssertTrue(commands(seeded.id).isEmpty, "choosing a default runs nothing")
    }

    /// A runner that dies mid-run while the app stays open is brought back on the next tick,
    /// and one that is still alive is left alone.
    func testTickRespawnsARunnerThatDiedMidRun() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        try saveTape(seeded.id, .running, target: .nextMajor)
        clock.fire()
        XCTAssertEqual(runner.ensured, [], "a live runner is never respawned")

        runner.running = []
        clock.fire()
        XCTAssertEqual(runner.ensured, [seeded.id])
        XCTAssertEqual(intake(svc, seeded.id).state, .shaping)
    }

    /// A running tape's heartbeat changes every second; republishing for it re-rendered every
    /// observer of the service each second of a run. Liveness still sees the new heartbeat.
    func testHeartbeatOnlyChangeIsNotPublished() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        var tape = Tape(target: .nextMajor, status: .running, runnerPID: 42, heartbeat: Date(timeIntervalSince1970: 100))
        try tapeStore(seeded.id).saveTape(tape)
        clock.fire()
        XCTAssertEqual(svc.tapes[seeded.id], tape)

        var publishes = 0
        let sink = svc.objectWillChange.sink { publishes += 1 }
        defer { sink.cancel() }
        tape.heartbeat = Date(timeIntervalSince1970: 101)
        tape.runnerPID = 43
        try tapeStore(seeded.id).saveTape(tape)
        // tape.json's mtime has 1 s-or-finer resolution; make sure the tick sees a change.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: tapeStore(seeded.id).tapeURL.path)
        clock.fire()
        XCTAssertEqual(publishes, 0, "a heartbeat-only change must not publish")
        XCTAssertEqual(svc.tapes[seeded.id]?.heartbeat, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(runner.runningChecks.last??.heartbeat, Date(timeIntervalSince1970: 101),
                       "liveness is judged on the latest read, shared rather than re-decoded")

        tape.status = .paused
        try tapeStore(seeded.id).saveTape(tape)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: tapeStore(seeded.id).tapeURL.path)
        clock.fire()
        XCTAssertGreaterThan(publishes, 0)
        XCTAssertEqual(svc.tapes[seeded.id]?.status, .paused)
    }

    /// A ▶ queued on a paused tape whose runner never came up (a deferred spawn, a crash before
    /// it read the command) is pending work: it isn't waiting on the human, and the tick
    /// brings a runner back for it.
    func testPendingCommandsCountAsWorkNotAttention() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .paused)
        let svc = makeService()
        await svc.launchRecovery?.value
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
        XCTAssertEqual(runner.ensured, [])

        runner.startResult = .failure(.notReady)
        svc.send(seeded.id, .step)
        XCTAssertEqual(intake(svc, seeded.id).state, .shaping, "a deferred spawn is not a failure")
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 0)
        clock.fire()
        XCTAssertEqual(runner.ensured, [seeded.id, seeded.id], "the tick retries the deferred spawn")

        // Once a runner acks it, a paused tape is waiting on the human again.
        var tape = tapeStore(seeded.id).loadTape()
        tape.ackedCommandSeq = 1
        try tapeStore(seeded.id).saveTape(tape)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: tapeStore(seeded.id).tapeURL.path)
        clock.fire()
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
        XCTAssertEqual(runner.ensured.count, 2)
    }

    /// The sidebar asks `attentionCount` several times per redraw and the clock asks
    /// `resumeIfStalled` every tick, and each used to re-read and re-decode `commands.jsonl`:
    /// ~2.6% of a core on the main thread, measured 2026-10-05. An unchanged file (and an
    /// unchanged ack) cannot have a different answer. Proven by making the file unreadable
    /// without touching its size or mtime: a re-read would find no commands and flip the
    /// count back to 1.
    func testAnUnchangedCommandsFileIsNotReadAgain() async throws {
        let seeded = try seed(.shaping)
        try saveTape(seeded.id, .paused)
        let store = tapeStore(seeded.id)
        _ = try store.appendCommand(.step)
        var tape = store.loadTape()
        tape.ackedCommandSeq = 1          // the one command is acked: nothing pending
        try store.saveTape(tape)
        // A whole-second mtime, so putting it back below restores it exactly — `Date` cannot
        // carry the nanoseconds a fresh write leaves, and the memo keys on them.
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: store.commandsURL.path)
        let svc = makeService()
        await svc.launchRecovery?.value
        XCTAssertEqual(svc.tapes[seeded.id]?.status, .paused)
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1, "paused, nothing pending: waiting on you")

        // Rewrite the command's seq to one past the ack — same size, same inode, mtime put
        // back — so a re-read would see a pending command and drop the count to 0.
        let url = store.commandsURL
        let original = try Data(contentsOf: url)
        let edited = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "\"seq\":1", with: "\"seq\":2").utf8)
        XCTAssertNotEqual(edited, original)
        XCTAssertEqual(edited.count, original.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: edited)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)

        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1, "answered from memory, not re-read")
    }

    func testTapeChangesArePublishedOnTheClockTick() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        XCTAssertEqual(svc.tapes[seeded.id]?.status ?? .idle, .idle)

        var tape = Tape()
        tape.status = .running
        tape.target = .nextMajor
        try tapeStore(seeded.id).saveTape(tape)
        clock.fire()
        XCTAssertEqual(svc.tapes[seeded.id]?.status, .running)
    }

    func testReachedReviewMovesIntakeToReviewWithFinalChangeSet() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        try writeFinishedTape(seeded.id)
        clock.fire()
        // A second beat must not apply the finished tape again.
        clock.fire()

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .review)
        // The latest checkpoint WITH a change set (polish's B), not the plan-only head.
        XCTAssertEqual(i.changeSet, Self.changeSet("B"))
        XCTAssertEqual(try IntakeStore(root: root).load(id: seeded.id).state, .review)
        XCTAssertEqual(runner.reaped, [seeded.id])
        XCTAssertEqual(runner.ensured, [])
        // Release review validates against the graph that change set was validated against.
        let triageGraph = IntakeStore(root: root).directory(for: seeded.id)
            .appendingPathComponent("triage/graph.json")
        XCTAssertEqual(try IntakeJSON.decoder.decode(GraphSnapshot.self, from: Data(contentsOf: triageGraph)), Self.graph)
    }

    func testReachedReviewWithoutAChangeSetFailsInsteadOfAnEmptyReview() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        try writeFinishedTape(seeded.id, withChangeSets: false)
        clock.fire()

        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .failed)
        XCTAssertNil(i.changeSet)
        XCTAssertNotNil(i.failure)
    }

    func testShapingSurvivesRelaunchAndRespawnsRunner() async throws {
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
        XCTAssertEqual(runner.ensured, [], "recovery is deferred out of init (it may be inside a view body)")
        await svc.launchRecovery?.value
        for id in [running.id, queued.id, paused.id] {
            XCTAssertEqual(intake(svc, id).state, .shaping)
            XCTAssertEqual(try IntakeStore(root: root).load(id: id).state, .shaping)
        }
        XCTAssertEqual(Set(runner.ensured), [running.id, queued.id], "a paused tape waits for the user")
        XCTAssertEqual(runner.ensured.count, 2)
    }

    func testPausedTapeCountsForAttention() async throws {
        let paused = try seed(.shaping)
        var tape = Tape(); tape.status = .paused
        try tapeStore(paused.id).saveTape(tape)
        let running = try seed(.shaping)
        tape = Tape(); tape.status = .running; tape.target = .review
        try tapeStore(running.id).saveTape(tape)

        let svc = makeService()
        await svc.launchRecovery?.value
        XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1)
    }

    func testTapeThatStopsOrFailsLightsAttentionAfterATick() async throws {
        for terminal: RunnerStatus in [.stopped, .failed] {
            let seeded = try seed(.shaping)
            try saveTape(seeded.id, .running, target: .review)
            runner.running = [seeded.id]
            let svc = makeService()
            await svc.launchRecovery?.value
            XCTAssertEqual(svc.attentionCount(forProject: "/p"), 0, "\(terminal)")

            try saveTape(seeded.id, terminal, target: .none)
            clock.fire()
            XCTAssertEqual(svc.attentionCount(forProject: "/p"), 1, "\(terminal)")
            svc.discard(seeded.id)
        }
    }

    /// The runner is still live (fresh heartbeat) the instant it is discarded, so a one-shot
    /// reap was a no-op and leaked its daemon. The reap is retried every tick until it lands.
    func testDiscardWhileShapingStopsRunner() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        XCTAssertTrue(svc.discard(seeded.id))
        XCTAssertEqual(commands(seeded.id), [.stop])
        XCTAssertEqual(intake(svc, seeded.id).state, .discarded)

        clock.fire()
        XCTAssertEqual(runner.reaped, [], "still running: nothing to collect yet")
        runner.running = []
        clock.fire()
        XCTAssertEqual(runner.reaped, [seeded.id])
        clock.fire()
        XCTAssertEqual(runner.reaped, [seeded.id], "collected once, then forgotten")
        XCTAssertEqual(runner.ensured, [])
    }

    func testReachedReviewReapsOnlyOnceTheRunnerHasExited() async throws {
        let seeded = try seed(.shaping)
        let svc = makeService()
        await svc.launchRecovery?.value
        runner.running = [seeded.id]
        try writeFinishedTape(seeded.id)
        clock.fire()
        XCTAssertEqual(intake(svc, seeded.id).state, .review)
        XCTAssertEqual(runner.reaped, [])
        runner.running = []
        clock.fire()
        XCTAssertEqual(runner.reaped, [seeded.id])
    }

    /// A daemon left behind by an intake that stopped shaping while FD was not running (it
    /// reached review, or was discarded, just before a quit) is collected at launch. A shaping
    /// intake's socket is its live runner and is left alone.
    func testLaunchQueuesAReapForAnOrphanedRunnerSocket() async throws {
        let reviewed = try seed(.review, changeSet: Self.changeSet("A"))
        let shaping = try seed(.shaping)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for id in [reviewed.id, shaping.id] {
            FileManager.default.createFile(atPath: runner.socketPath(for: id), contents: nil)
        }
        let svc = makeService()
        await svc.launchRecovery?.value
        XCTAssertEqual(runner.reaped, [reviewed.id])
    }

    func testRetryResumesAFailedShapingRunWithoutRetriaging() async throws {
        var seeded = try seed(.shaping)
        seeded.state = .failed
        seeded.failure = "Could not start the planning runner: x"
        try IntakeStore(root: root).save(seeded)
        let svc = makeService()
        await svc.launchRecovery?.value

        svc.retry(seeded.id)
        let i = intake(svc, seeded.id)
        XCTAssertEqual(i.state, .shaping)
        XCTAssertNil(i.failure)
        XCTAssertEqual(i.recommended, .featurePlan, "nothing re-triaged")
        XCTAssertNil(svc.task(for: seeded.id), "no triage turn started")
        XCTAssertEqual(runner.ensured, [seeded.id])
    }

    /// A review holds a finished change set; shaping over it would replace what is being
    /// reviewed, so only Bead is accepted from `.review`.
    func testNonBeadChoiceFromReviewIsRejected() async throws {
        let seeded = try seed(.review, changeSet: Self.changeSet("A"))
        let svc = makeService()
        await svc.launchRecovery?.value
        svc.choose(seeded.id, preset: .featurePlan)
        XCTAssertEqual(intake(svc, seeded.id).state, .review)
        XCTAssertNil(intake(svc, seeded.id).chosenPreset)
        XCTAssertEqual(commands(seeded.id), [])
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
