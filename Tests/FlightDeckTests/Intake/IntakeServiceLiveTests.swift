import XCTest
import IntakeKit
@testable import FlightDeck

/// Records what the service asked of the runner, instead of spawning `fd-abduco`.
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

/// `br`/`bv` replies by `"<exe> <arg0>"`, with an optional delay per key so a triage turn can be
/// held in its graph read while the test looks at it.
private final class ScriptedProcessRunner: FlywheelProcessRunner, @unchecked Sendable {
    var replies: [String: (String, Int32)]
    var slow: [String: UInt64] = [:]
    init(_ replies: [String: (String, Int32)]) { self.replies = replies }
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        let key = ([exe] + args.prefix(1)).joined(separator: " ")
        if let ns = slow[key] { try await Task.sleep(nanoseconds: ns) }
        return replies[key] ?? ("", 127)
    }
}

/// A triage harness that holds until cancelled or released — the turn only has to start.
private final class HeldHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.withLock { open = true } }
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        while !lock.withLock({ open }) { try await Task.sleep(nanoseconds: 1_000_000) }
        return (Data(), "", 1)
    }
}

/// Every file read the service routes through its `readFile` seam, so a test can prove a tick
/// that found nothing changed read nothing. Locked: the convergence fold reads off the main actor.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func count(_ suffix: String) -> Int { lock.withLock { paths.filter { $0.hasSuffix(suffix) }.count } }
    func count(containing part: String) -> Int { lock.withLock { paths.filter { $0.contains(part) }.count } }
    func reset() { lock.withLock { paths = [] } }
    func read(_ url: URL) -> Data? {
        lock.withLock { paths.append(url.path) }
        return try? Data(contentsOf: url)
    }
}

/// The live surfaces a planning run publishes (spec §3.1 "No dead moments", §6, §8): the
/// optimistic `pending` start, the round in progress's seat activity and run records, the
/// convergence series, and the per-intake flap policy — each derived on the shared tick.
@MainActor
final class IntakeServiceLiveTests: XCTestCase {
    private var root: URL!
    private var runner: FakeRunnerController!
    private var reads: ReadLog!
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)
    /// What the service asked VoiceOver to say (`IntakeService.announce`).
    private var announced: [String] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakeServiceLiveTests-\(UUID())", isDirectory: true)
        runner = FakeRunnerController()
        runner.socketDirectory = root
        reads = ReadLog()
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures

    private static func list() -> String {
        #"{"issues":[{"id":"b1","title":"T b1","status":"open"}]}"#
    }
    private static let brReplies: [String: (String, Int32)] =
        ["br list": (list(), 0), "br graph": (#"{"components":[]}"#, 0), "bv --robot-triage": ("{}", 0)]

    private func makeService(processRunner: ScriptedProcessRunner = ScriptedProcessRunner([:]),
                             headless: HeadlessRunner = HeldHeadlessRunner(),
                             countRecovery: Bool = false, awaitRecovery: Bool = true) async -> IntakeService {
        let reads = self.reads!
        let svc = IntakeService(store: IntakeStore(root: root), headless: headless, processRunner: processRunner,
                                triageSettings: TriageSettings(harness: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { [unowned self] in self.clockNow },
                                readFile: { reads.read($0) },
                                announce: { [unowned self] in self.announced.append($0) })
        // Launch recovery runs one tick of its own; let it land (and any convergence fold it
        // started), and unless the test is about that first read, count from zero after it.
        guard awaitRecovery else { return svc }
        await svc.launchRecovery?.value
        for i in svc.intakes { await svc.convergenceFold(for: i.id)?.value }
        if !countRecovery { reads.reset() }
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

    private func writeSeat(_ id: UUID, run: String, activity: SeatActivity?, record: RunRecord?) throws {
        let dir = tapeStore(id).runDirectory(run)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let activity { try IntakeJSON.encoder.encode(activity).write(to: dir.appendingPathComponent("activity.json")) }
        if let record { try IntakeJSON.encoder.encode(record).write(to: dir.appendingPathComponent("run.json")) }
    }

    /// Whole seconds: `setAttributes` keeps less precision than a stat returns, so an arbitrary
    /// mtime would itself read as a change when set again.
    private func setMTime(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    private static let refine1 = PlannedRound(stage: .refine, round: 1, major: false)

    // MARK: pending

    /// The pending state lands in the same main-actor turn as the action — no await in
    /// between — so the UI answers the click before any process has started.
    func testSendAnswersSetsPendingSynchronously() async throws {
        let asking = try seed(.needsAnswers)
        let choosing = try seed(.awaitingChoice)
        let shaping = try seed(.shaping)
        let svc = await makeService()

        svc.answer(asking.id, answers: ["The top one"])
        XCTAssertEqual(svc.pending[asking.id], PendingStart(kind: .triage, since: clockNow))

        let config = try XCTUnwrap(choosing.roundConfig)
        svc.beginShaping(choosing.id, preset: .featurePlan, config: config)
        XCTAssertEqual(svc.pending[choosing.id],
                       PendingStart(kind: .round(TapePlanner.next(after: .empty, config: config)), since: clockNow))
        XCTAssertEqual(svc.pending[choosing.id]?.kind, .round(PlannedRound(stage: .draft, round: 0, major: true)))

        // Only play commands promise a round; a pause or a note starts nothing.
        svc.send(shaping.id, .pause)
        XCTAssertNil(svc.pending[shaping.id])
        svc.send(shaping.id, .note(PlanNote(note: "tighten §2")))
        XCTAssertNil(svc.pending[shaping.id])
        for play in [TapeCommand.step, .nextMajor, .toReview] {
            clockNow += 1
            svc.send(shaping.id, play)
            XCTAssertEqual(svc.pending[shaping.id]?.since, clockNow, "\(play)")
        }
    }

    /// A round start clears on the first seat activity or runner heartbeat dated after the
    /// click; a stale heartbeat from an earlier runner doesn't count. With nothing for 15 s it
    /// turns into the quiet queued state — still pending, no longer "starting".
    func testPendingClearsOnFirstActivity() async throws {
        let a = try seed(.shaping), b = try seed(.shaping)
        for id in [a.id, b.id] {
            try updateTape(id) { $0.status = .paused; $0.heartbeat = self.clockNow.addingTimeInterval(-60) }
        }
        let svc = await makeService()
        let pressed = clockNow
        svc.send(a.id, .step)
        svc.send(b.id, .step)

        clockNow += 14
        svc.pollTapes()
        XCTAssertEqual(svc.pending[a.id]?.queued, false, "under 15 s is still starting")
        clockNow += 1
        svc.pollTapes()
        XCTAssertEqual(svc.pending[a.id], PendingStart(kind: .round(PlannedRound(stage: .draft, round: 0, major: true)),
                                                       since: pressed, queued: true))

        // a: the runner is up and has put a seat to work.
        try updateTape(a.id) {
            $0.status = .running
            $0.roundInProgress = PlannedRound(stage: .draft, round: 0, major: true)
        }
        svc.pollTapes()
        XCTAssertNotNil(svc.pending[a.id], "a round in progress with no seat yet is still pending")
        try writeSeat(a.id, run: "draft-0-drafter-1", activity: SeatActivity(harness: .codex, startedAt: clockNow), record: nil)
        svc.pollTapes()
        XCTAssertNil(svc.pending[a.id])

        // b: only a heartbeat, but a fresh one.
        try updateTape(b.id) { $0.heartbeat = self.clockNow }
        svc.pollTapes()
        XCTAssertNil(svc.pending[b.id])
    }

    /// A runner that adopts the play, runs the round and pauses — all between two ticks —
    /// leaves no heartbeat (its exit clears it) and no round in progress. The tape it rewrote
    /// after the click is the sign of life; without it the start stuck at "queued".
    func testPendingClearsWhenARunnerAdoptsAndFinishesBetweenTicks() async throws {
        let i = try seed(.shaping)
        try updateTape(i.id) { $0.status = .paused }
        try setMTime(tapeStore(i.id).tapeURL, clockNow.timeIntervalSince1970 - 60)
        let svc = await makeService()
        svc.send(i.id, .step)
        svc.pollTapes()
        XCTAssertNotNil(svc.pending[i.id], "the old paused tape is no sign of life")

        clockNow += 20
        svc.pollTapes()
        XCTAssertEqual(svc.pending[i.id]?.queued, true)

        // Between ticks: adopted, a checkpoint landed, paused again with no heartbeat.
        let store = tapeStore(i.id)
        var tape = store.loadTape()
        try store.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n".utf8)], into: &tape)
        tape.status = .paused
        tape.heartbeat = nil
        try store.saveTape(tape)
        try setMTime(store.tapeURL, clockNow.timeIntervalSince1970)
        svc.pollTapes()
        XCTAssertNil(svc.pending[i.id])

        // An idle tape rewritten after the click is not yet the runner working.
        svc.send(i.id, .step)
        try updateTape(i.id) { $0.status = .idle; $0.target = .nextMinor }
        try setMTime(store.tapeURL, clockNow.timeIntervalSince1970 + 1)
        svc.pollTapes()
        XCTAssertNotNil(svc.pending[i.id])
    }

    /// Pause and stop withdraw the play that was starting.
    func testStopAndPauseClearARoundsPendingStart() async throws {
        let i = try seed(.shaping)
        let svc = await makeService()
        svc.send(i.id, .nextMajor)
        XCTAssertNotNil(svc.pending[i.id])
        svc.send(i.id, .pause)
        XCTAssertNil(svc.pending[i.id])
        svc.send(i.id, .toReview)
        XCTAssertNotNil(svc.pending[i.id])
        svc.send(i.id, .stop)
        XCTAssertNil(svc.pending[i.id])
    }

    // MARK: announcements

    /// Spec §14: live regions announce state changes — a round landed, failed, reached review,
    /// needs you — and nothing else: never the first read of a tape (that is the app opening,
    /// not a change), never a heartbeat or a clock.
    func testAnnouncesOnlyTheStateChangesTheSpecNames() {
        func tape(_ checkpoints: [(Stage, Int)], _ status: RunnerStatus, running: PlannedRound? = nil) -> Tape {
            var t = Tape()
            t.checkpoints = checkpoints.enumerated().map { n, c in
                Checkpoint(id: n + 1, stage: c.0, round: c.1, major: false, createdAt: .distantPast)
            }
            t.status = status
            t.roundInProgress = running
            return t
        }
        let one = tape([(.draft, 0)], .running, running: Self.refine1)
        XCTAssertNil(IntakeService.announcement(from: nil, to: one), "the first read is not a change")
        var beat = one
        beat.heartbeat = .distantFuture
        XCTAssertNil(IntakeService.announcement(from: one, to: beat), "a heartbeat is not a state change")
        XCTAssertEqual(IntakeService.announcement(from: one, to: tape([(.draft, 0), (.refine, 1)], .running)), "Refine 1 landed")
        XCTAssertEqual(IntakeService.announcement(from: one, to: tape([(.draft, 0)], .failed, running: Self.refine1)),
                       "Refine 1 failed")
        XCTAssertNil(IntakeService.announcement(from: one, to: tape([(.draft, 0), (.encode, 0)], .reachedReview)),
                     "the last round landing is said once, as the intake's move to review")

        XCTAssertEqual(IntakeService.announcement(from: .triaging, to: .needsAnswers), "Triage has questions for you")
        XCTAssertEqual(IntakeService.announcement(from: .shaping, to: .review), "The plan is ready for review")
        XCTAssertEqual(IntakeService.announcement(from: .triaging, to: .failed), "The intake failed")
        XCTAssertNil(IntakeService.announcement(from: .needsAnswers, to: .triaging))
        XCTAssertNil(IntakeService.announcement(from: .review, to: .review), "a save that changes nothing says nothing")
        XCTAssertNil(IntakeService.announcement(from: nil, to: .triaging))
    }

    /// Wired through the tick: a checkpoint landing on the tape is announced once.
    func testARoundLandingOnTheTapeIsAnnounced() async throws {
        let shaping = try seed(.shaping)
        try updateTape(shaping.id) {
            $0.status = .running
            $0.roundInProgress = Self.refine1
            $0.checkpoints = [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: self.clockNow)]
        }
        let svc = await makeService()
        svc.pollTapes()
        XCTAssertEqual(announced, [])

        try updateTape(shaping.id) {
            $0.checkpoints.append(Checkpoint(id: 2, stage: .refine, round: 1, major: false, createdAt: self.clockNow))
            $0.roundInProgress = nil
        }
        svc.pollTapes()
        svc.pollTapes()
        XCTAssertEqual(announced, ["Refine 1 landed"])
    }

    /// Stop discards the round in flight — paid work — so it goes through a confirmation, from
    /// the bar's key and ⌘. alike (both press `PlanningActions`). Pause, which loses nothing,
    /// still acts at once.
    func testStopAsksFirstAndPauseDoesNot() async throws {
        let shaping = try seed(.shaping)
        try updateTape(shaping.id) { $0.status = .running; $0.roundInProgress = Self.refine1 }
        let svc = await makeService()
        svc.pollTapes()
        let intake = try XCTUnwrap(svc.intakes.first { $0.id == shaping.id })
        let tape = tapeStore(shaping.id).loadTape()
        var asked = 0
        let actions = PlanningActions.shaping(shaping.id, service: svc, model: ShapingModel(intake: intake, tape: tape),
                                              annotate: {}, confirmStop: { asked += 1 })

        actions.perform(.stop)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(tapeStore(shaping.id).commands(after: 0).map(\.command), [], "nothing is stopped until confirmed")

        actions.perform(.pause)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(tapeStore(shaping.id).commands(after: 0).map(\.command), [.pause])
    }

    /// The confirmation names what Stop throws away: the round in flight, by name — or says
    /// nothing is lost when no round is running.
    func testStopConfirmationNamesTheRoundInFlight() {
        var tape = Tape()
        tape.roundInProgress = Self.refine1
        XCTAssertEqual(PlanningActions.stopMessage(tape: tape),
                       "Refine 1's work so far is discarded. Every round that already landed stays in the plan.")
        tape.roundInProgress = nil
        XCTAssertEqual(PlanningActions.stopMessage(tape: tape),
                       "No round is running, so nothing is discarded. Every round that already landed stays in the plan.")
    }

    /// Every way into a fresh triage turn answers the click at once — not only Send Answers.
    /// Continue with Single task (`.encodeNow`) and Retry once left `pending` unset, so while
    /// the turn read the graph the card drew the PREVIOUS turn's finished activity with its
    /// clock stopped: a finished, frozen seat right after the click.
    func testEveryTriageRestartSetsPendingAndDropsTheOldActivity() async throws {
        let failed = try seed(.needsAnswers)
        let choosing = try seed(.awaitingChoice)
        let br = ScriptedProcessRunner(Self.brReplies)
        let headless = HeldHeadlessRunner()
        headless.release()
        let svc = await makeService(processRunner: br, headless: headless)

        // A turn that reaches the harness and fails leaves its finished activity published.
        svc.answer(failed.id, answers: ["x"])
        await svc.task(for: failed.id)?.value
        XCTAssertEqual(svc.intakes.first { $0.id == failed.id }?.state, .failed)
        XCTAssertEqual(svc.triageActivity(failed.id)?.finished, true)

        br.slow["br list"] = 300_000_000
        clockNow += 5
        svc.retry(failed.id)
        XCTAssertEqual(svc.pending[failed.id], PendingStart(kind: .triage, since: clockNow))
        XCTAssertNil(svc.triageActivity(failed.id), "the failed turn's finished seat is not this turn's")

        svc.choose(choosing.id, preset: .bead)
        XCTAssertEqual(svc.pending[choosing.id], PendingStart(kind: .triage, since: clockNow))

        // Both survive the turn's own `.triaging` save.
        for _ in 0..<2000 where svc.intakes.first(where: { $0.id == choosing.id })?.state != .triaging {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(svc.pending[failed.id])
        XCTAssertNotNil(svc.pending[choosing.id])
    }

    /// Triage's pending clears on `triage/activity.json` from THIS turn, never on the previous
    /// turn's file still on disk, and a turn that fails before any activity drops it too.
    func testTriagePendingClearsOnThisTurnsActivityOnly() async throws {
        clockNow = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let asking = try seed(.needsAnswers)
        let file = IntakeStore(root: root).directory(for: asking.id).appendingPathComponent("triage/activity.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var old = SeatActivity(harness: .codex, startedAt: clockNow.addingTimeInterval(-600))
        old.finished = true
        try IntakeJSON.encoder.encode(old).write(to: file)

        let br = ScriptedProcessRunner(Self.brReplies)
        br.slow["br list"] = 300_000_000
        let headless = HeldHeadlessRunner()
        let svc = await makeService(processRunner: br, headless: headless)
        svc.answer(asking.id, answers: ["The top one"])
        for _ in 0..<2000 where svc.intakes.first(where: { $0.id == asking.id })?.state != .triaging {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        svc.pollTapes()
        XCTAssertEqual(svc.triageActivity(asking.id), old, "the old turn's file is read…")
        XCTAssertNotNil(svc.pending[asking.id], "…but is not this turn's activity")

        // The turn reaches the harness, whose publisher writes this turn's first activity.
        for _ in 0..<4000 {
            if let data = try? Data(contentsOf: file),
               let now = try? IntakeJSON.decoder.decode(SeatActivity.self, from: data), !now.finished { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        svc.pollTapes()
        XCTAssertNil(svc.pending[asking.id])

        headless.release()
        await svc.task(for: asking.id)?.value
        XCTAssertEqual(svc.intakes.first { $0.id == asking.id }?.state, .failed)

        // A failure with no activity at all still drops the pending start.
        let other = try seed(.needsAnswers)
        let failing = await makeService(processRunner: ScriptedProcessRunner([:]))
        failing.answer(other.id, answers: ["x"])
        XCTAssertNotNil(failing.pending[other.id])
        await failing.task(for: other.id)?.value
        XCTAssertEqual(failing.intakes.first { $0.id == other.id }?.state, .failed)
        XCTAssertNil(failing.pending[other.id])
    }

    // MARK: seat activity

    /// `runs/*/activity.json` and `run.json` are read only while the tape has a round in
    /// progress, and only that round's seats.
    func testSeatActivitiesLoadForRoundInProgressOnly() async throws {
        let i = try seed(.shaping)
        try updateTape(i.id) { $0.status = .paused }
        let started = clockNow
        try writeSeat(i.id, run: "draft-0-drafter-1", activity: SeatActivity(harness: .codex, startedAt: started),
                      record: RunRecord(pid: 1, started: started, finished: started, exitCode: 0))
        try writeSeat(i.id, run: "refine-1-reviewer", activity: SeatActivity(harness: .claude, startedAt: started),
                      record: RunRecord(pid: 2, started: started))
        try writeSeat(i.id, run: "refine-10-reviewer", activity: SeatActivity(harness: .codex, startedAt: started), record: nil)
        let svc = await makeService()

        svc.pollTapes()
        XCTAssertNil(svc.seatActivities[i.id])
        XCTAssertNil(svc.runRecords[i.id])
        XCTAssertEqual(reads.count(containing: "/runs/"), 0, "no round in progress reads no seat file")

        try updateTape(i.id) { $0.status = .running; $0.roundInProgress = Self.refine1 }
        svc.pollTapes()
        XCTAssertEqual(svc.seatActivities[i.id]?.keys.sorted(), ["refine-1-reviewer"])
        XCTAssertEqual(svc.seatActivities[i.id]?["refine-1-reviewer"]?.harness, .claude)
        XCTAssertEqual(svc.runRecords[i.id], ["refine-1-reviewer": RunRecord(pid: 2, started: started)])
        XCTAssertEqual(reads.count(containing: "/runs/draft-0-"), 0)
        XCTAssertEqual(reads.count(containing: "/runs/refine-10-"), 0)

        // The round lands: nothing is in progress, so nothing is shown or read.
        try updateTape(i.id) { $0.status = .paused; $0.roundInProgress = nil }
        reads.reset()
        svc.pollTapes()
        XCTAssertNil(svc.seatActivities[i.id])
        XCTAssertNil(svc.runRecords[i.id])
        XCTAssertEqual(reads.count(containing: "/runs/"), 0)
    }

    /// Each seat file is re-read only when its own mtime moves — an idle tick costs stats.
    func testActivityReloadIsMtimeGated() async throws {
        let i = try seed(.shaping)
        try updateTape(i.id) { $0.status = .running; $0.roundInProgress = Self.refine1 }
        try writeSeat(i.id, run: "refine-1-reviewer", activity: SeatActivity(harness: .codex, startedAt: clockNow),
                      record: RunRecord(started: clockNow))
        let dir = tapeStore(i.id).runDirectory("refine-1-reviewer")
        let activity = dir.appendingPathComponent("activity.json"), record = dir.appendingPathComponent("run.json")
        try setMTime(activity, 1_790_000_000)
        try setMTime(record, 1_790_000_000)
        // Launch recovery's tick is the first read of each file.
        let svc = await makeService(countRecovery: true)
        XCTAssertEqual(reads.count("activity.json"), 1)
        XCTAssertEqual(reads.count("run.json"), 1)
        for _ in 0..<3 { svc.pollTapes() }
        XCTAssertEqual(reads.count("activity.json"), 1, "an unchanged mtime costs a stat, not a read")
        XCTAssertEqual(reads.count("run.json"), 1)

        var moved = SeatActivity(harness: .codex, startedAt: clockNow)
        moved.headline = "Reading the board"
        try IntakeJSON.encoder.encode(moved).write(to: activity)
        try setMTime(activity, 1_790_000_001)
        svc.pollTapes()
        XCTAssertEqual(reads.count("activity.json"), 2)
        XCTAssertEqual(reads.count("run.json"), 1, "each file is gated on its own mtime")
        XCTAssertEqual(svc.seatActivities[i.id]?["refine-1-reviewer"]?.headline, "Reading the board")
    }

    /// A seat beat publishes on `seats` alone. On the service it redrew every observer of the
    /// service — the whole detail pane, the project view, and through `SessionStore`'s forward
    /// every view of the store — about once a second of a run, for values only the live card
    /// draws.
    func testSeatBeatPublishesOnlyOnTheSeatFeed() async throws {
        let i = try seed(.shaping)
        try updateTape(i.id) { $0.status = .running; $0.roundInProgress = Self.refine1 }
        try writeSeat(i.id, run: "refine-1-reviewer", activity: SeatActivity(harness: .codex, startedAt: clockNow),
                      record: RunRecord(started: clockNow))
        let activity = tapeStore(i.id).runDirectory("refine-1-reviewer").appendingPathComponent("activity.json")
        try setMTime(activity, 1_790_000_000)
        let svc = await makeService()
        var servicePublishes = 0, seatPublishes = 0
        let a = svc.objectWillChange.sink { servicePublishes += 1 }
        let b = svc.seats.objectWillChange.sink { seatPublishes += 1 }
        defer { a.cancel(); b.cancel() }

        var moved = SeatActivity(harness: .codex, startedAt: clockNow)
        moved.headline = "Reading the board"
        try IntakeJSON.encoder.encode(moved).write(to: activity)
        try setMTime(activity, 1_790_000_001)
        svc.pollTapes()
        XCTAssertEqual(svc.seatActivities[i.id]?["refine-1-reviewer"]?.headline, "Reading the board")
        XCTAssertEqual(svc.seats.files(i.id).activities["refine-1-reviewer"]?.headline, "Reading the board")
        XCTAssertGreaterThan(seatPublishes, 0)
        XCTAssertEqual(servicePublishes, 0, "a seat beat must not redraw the service's observers")
    }

    /// A retried round keeps its name, so the failed attempt's seats sit beside the new ones;
    /// anything that started before this attempt (less a second's grace) is not shown.
    func testSeatsFromAnEarlierAttemptAreHidden() async throws {
        let i = try seed(.shaping)
        let attempt = clockNow
        try updateTape(i.id) {
            $0.status = .running; $0.roundInProgress = Self.refine1; $0.roundStartedAt = attempt
        }
        try writeSeat(i.id, run: "refine-1-reviewer", activity: SeatActivity(harness: .codex, startedAt: attempt - 120),
                      record: RunRecord(pid: 1, started: attempt - 120, finished: attempt - 60, exitCode: 1))
        try writeSeat(i.id, run: "refine-1-reviewer-fallback", activity: SeatActivity(harness: .claude, startedAt: attempt + 2),
                      record: RunRecord(pid: 2, started: attempt + 2))
        try writeSeat(i.id, run: "refine-1-integrator", activity: SeatActivity(harness: .codex, startedAt: attempt - 0.5),
                      record: nil)
        let svc = await makeService()
        XCTAssertEqual(svc.seatActivities[i.id]?.keys.sorted(), ["refine-1-integrator", "refine-1-reviewer-fallback"])
        XCTAssertEqual(svc.runRecords[i.id]?.keys.sorted(), ["refine-1-reviewer-fallback"])
        // Their results follow the same rule: the stale attempt's result.json is not this seat's.
        let store = tapeStore(i.id)
        try IntakeJSON.encoder.encode(SeatResult(kind: .reviewer, changeCount: 9))
            .write(to: store.runDirectory("refine-1-reviewer").appendingPathComponent("result.json"))
        try IntakeJSON.encoder.encode(SeatResult(kind: .reviewer, changeCount: 3))
            .write(to: store.runDirectory("refine-1-reviewer-fallback").appendingPathComponent("result.json"))
        svc.pollTapes()
        XCTAssertEqual(svc.seatResults[i.id], ["refine-1-reviewer-fallback": SeatResult(kind: .reviewer, changeCount: 3)])
    }

    /// A seat's `result.json` is followed like its activity — same round-in-progress scope, same
    /// per-file mtime gate — so its row shows the outcome as soon as the seat writes it.
    func testSeatResultLoadsOnItsOwnMtime() async throws {
        let i = try seed(.shaping)
        try updateTape(i.id) { $0.status = .running; $0.roundInProgress = Self.refine1 }
        try writeSeat(i.id, run: "refine-1-reviewer", activity: SeatActivity(harness: .codex, startedAt: clockNow),
                      record: RunRecord(started: clockNow))
        let svc = await makeService()
        svc.pollTapes()
        XCTAssertNil(svc.seatResults[i.id], "no result.json until the seat's output parses")

        let file = tapeStore(i.id).runDirectory("refine-1-reviewer").appendingPathComponent("result.json")
        try IntakeJSON.encoder.encode(SeatResult(kind: .reviewer, changeCount: 4)).write(to: file)
        try setMTime(file, 1_790_000_000)
        svc.pollTapes()
        XCTAssertEqual(svc.seatResults[i.id], ["refine-1-reviewer": SeatResult(kind: .reviewer, changeCount: 4)])
        let before = reads.count("result.json")
        for _ in 0..<3 { svc.pollTapes() }
        XCTAssertEqual(reads.count("result.json"), before, "an unchanged mtime costs a stat, not a read")

        try updateTape(i.id) { $0.status = .paused; $0.roundInProgress = nil }
        svc.pollTapes()
        XCTAssertNil(svc.seatResults[i.id], "forgotten with the round's other seat files")
    }

    // MARK: convergence

    /// The series is folded from checkpoint files, so it is recomputed only when the tape's
    /// checkpoint count changes — not on every heartbeat that rewrites `tape.json`.
    func testConvergenceRecomputesOnNewCheckpointOnly() async throws {
        let i = try seed(.shaping)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        tape.status = .running
        for (n, round) in [1, 2].enumerated() {
            try store.writeCheckpoint(Checkpoint(id: n + 1, stage: .refine, round: round, major: false, createdAt: clockNow),
                                      files: ["plan.md": Data("# Plan\n\nround \(round)\n".utf8)], into: &tape)
        }
        // Launch recovery's tick is the first observation, and folds the series.
        let svc = await makeService(countRecovery: true)
        XCTAssertEqual(svc.convergence[i.id]?.map(\.stage), [.refine])
        XCTAssertEqual(svc.convergence[i.id]?.first?.points.count, 2)
        let firstReads = reads.count(containing: "/checkpoints/")
        XCTAssertGreaterThan(firstReads, 0)

        // A heartbeat: tape.json is rewritten, but no checkpoint landed.
        try updateTape(i.id) { $0.heartbeat = self.clockNow.addingTimeInterval(5) }
        let beforeBeat = svc.convergenceFold(for: i.id)
        svc.pollTapes()
        XCTAssertTrue(svc.convergenceFold(for: i.id) == beforeBeat, "no new checkpoint, no new fold")
        XCTAssertEqual(reads.count(containing: "/checkpoints/"), firstReads, "no new checkpoint, no recompute")

        try store.writeCheckpoint(Checkpoint(id: 3, stage: .refine, round: 3, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n\nround 3\n".utf8)], into: &tape)
        svc.pollTapes()
        await svc.convergenceFold(for: i.id)?.value
        XCTAssertGreaterThan(reads.count(containing: "/checkpoints/"), firstReads)
        XCTAssertEqual(svc.convergence[i.id]?.first?.points.count, 3)

        // The human edits the head plan: no checkpoint, but the base of the next round's churn
        // moved, so the series is refolded.
        let afterRound = reads.count(containing: "/checkpoints/")
        try Data("# Plan\n\nmine\n".utf8).write(to: store.userEditsURL(checkpoint: 3))
        svc.pollTapes()
        await svc.convergenceFold(for: i.id)?.value
        XCTAssertGreaterThan(reads.count(containing: "/checkpoints/"), afterRound, "a head plan edit refolds")
        let afterEdit = reads.count(containing: "/checkpoints/")
        svc.pollTapes()
        await svc.convergenceFold(for: i.id)?.value
        XCTAssertEqual(reads.count(containing: "/checkpoints/"), afterEdit, "an unchanged edit doesn't")
    }

    /// The fold runs off the main actor; one that finishes after a newer checkpoint landed is
    /// dropped, never published over the newer series.
    func testSupersededConvergenceFoldIsDropped() async throws {
        let i = try seed(.shaping)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        for round in [1, 2] {
            try store.writeCheckpoint(Checkpoint(id: round, stage: .refine, round: round, major: false, createdAt: clockNow),
                                      files: ["plan.md": Data("# Plan\n\nround \(round)\n".utf8)], into: &tape)
        }
        let svc = await makeService(awaitRecovery: false)
        svc.pollTapes()
        let stale = try XCTUnwrap(svc.convergenceFold(for: i.id))
        // Both ticks run before either fold can publish: publishing needs the main actor.
        try store.writeCheckpoint(Checkpoint(id: 3, stage: .refine, round: 3, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n\nround 3\n".utf8)], into: &tape)
        svc.pollTapes()
        let fresh = try XCTUnwrap(svc.convergenceFold(for: i.id))
        XCTAssertTrue(stale != fresh)
        await stale.value
        XCTAssertNil(svc.convergence[i.id], "the 2-checkpoint fold landed after the 3-checkpoint tick")
        await fresh.value
        await svc.launchRecovery?.value
        await svc.convergenceFold(for: i.id)?.value
        XCTAssertEqual(svc.convergence[i.id]?.first?.points.count, 3)
    }

    /// The fold's cost on a long tape: 30 refine checkpoints with ~20 KB plans. Loosely bounded
    /// (it runs detached, so this is about not being pathological, not about a frame budget);
    /// the measured numbers are printed for the report.
    func testConvergenceFoldTimingOnALongTape() async throws {
        let i = try seed(.shaping)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        for n in 1...30 {
            var plan = ""
            for section in 1...20 {
                plan += "# Section \(section)\n\n"
                for line in 1...20 { plan += "Line \(line) of section \(section), revised in round \(n - (line % 3 == 0 ? 0 : 1)).\n" }
            }
            try store.writeCheckpoint(Checkpoint(id: n, stage: .refine, round: n, major: n == 30, createdAt: clockNow),
                                      files: ["plan.md": Data(plan.utf8)], into: &tape)
        }
        let planBytes = try Data(contentsOf: store.checkpointDirectory(15).appendingPathComponent("plan.md")).count
        XCTAssertGreaterThan(planBytes, 15_000)
        let svc = await makeService(awaitRecovery: false)
        let tickStart = Date()
        svc.pollTapes()
        let tick = Date().timeIntervalSince(tickStart)
        await svc.convergenceFold(for: i.id)?.value
        let fold = Date().timeIntervalSince(tickStart)
        print("CONVERGENCE-TIMING plan=\(planBytes)B checkpoints=30 mainActorTick=\(Int(tick * 1000))ms foldTotal=\(Int(fold * 1000))ms")
        XCTAssertEqual(svc.convergence[i.id]?.first?.points.count, 30)
        XCTAssertLessThan(fold, 10)
    }

    // MARK: flap policy

    func testFlapPolicyIsStablePerIntake() async throws {
        let a = try seed(.shaping), b = try seed(.review)
        let svc = await makeService()
        XCTAssertTrue(svc.flapPolicy(for: a.id) === svc.flapPolicy(for: a.id))
        XCTAssertTrue(svc.flapPolicy(for: b.id) === svc.flapPolicy(for: b.id))
        XCTAssertFalse(svc.flapPolicy(for: a.id) === svc.flapPolicy(for: b.id))
    }

    /// Nothing is kept for an intake nothing will show: an unknown or discarded one gets a
    /// fresh policy every time.
    func testFlapPolicyForADiscardedOrMissingIntakeIsNotStored() async throws {
        let i = try seed(.shaping)
        let svc = await makeService()
        let missing = UUID()
        XCTAssertFalse(svc.flapPolicy(for: missing) === svc.flapPolicy(for: missing))
        let live = svc.flapPolicy(for: i.id)
        svc.discard(i.id)
        XCTAssertFalse(svc.flapPolicy(for: i.id) === live)
        XCTAssertFalse(svc.flapPolicy(for: i.id) === svc.flapPolicy(for: i.id))
    }

    /// A view that asks for the policy before launch recovery's first tick still gets it seeded
    /// from the tape on disk, and the tick that follows doesn't reseed what the view has since
    /// observed changing.
    func testFlapPolicyAskedBeforeLaunchRecoveryIsSeeded() async throws {
        let i = try seed(.shaping)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        tape.status = .paused
        try store.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n".utf8)], into: &tape)
        let svc = await makeService(awaitRecovery: false)
        let policy = svc.flapPolicy(for: i.id)
        XCTAssertFalse(policy.shouldFlap(surface: "board.now", text: "Draft", reduceMotion: false))
        XCTAssertFalse(policy.shouldFlap(surface: "card.refine-1", text: "Refine 1", reduceMotion: false))

        // Observed from here: a new head lands before recovery's tick, and still flaps after it.
        try store.writeCheckpoint(Checkpoint(id: 2, stage: .synthesis, round: 0, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan 2\n".utf8)], into: &tape)
        await svc.launchRecovery?.value
        XCTAssertTrue(svc.flapPolicy(for: i.id) === policy)
        XCTAssertTrue(policy.shouldFlap(surface: "board.now", text: "Synthesis", reduceMotion: false))
    }

    /// The maintainer's rule is keyed to data arriving, not a view mounting: every value the board shows
    /// when the service first observes a tape is seeded as already shown, so it never flaps just
    /// by scrolling into view. A value that changes afterwards still flaps once.
    func testFlapPolicySeedsTheBoardAtFirstObservation() async throws {
        let i = try seed(.shaping)
        let config = try XCTUnwrap(i.roundConfig)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        tape.status = .paused
        try store.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n".utf8)], into: &tape)
        let svc = await makeService()
        svc.pollTapes()

        let seen = BoardModel(intake: i, tape: tape, config: config, now: clockNow, selected: nil, preview: nil)
        let policy = svc.flapPolicy(for: i.id)
        XCTAssertFalse(seen.flapTexts.isEmpty)
        for (surface, text) in seen.flapTexts {
            XCTAssertTrue(policy.hasShown(surface: surface, text: text), surface)
            XCTAssertFalse(policy.shouldFlap(surface: surface, text: text, reduceMotion: false), surface)
        }
        XCTAssertTrue(policy.hasShown(surface: "board.now", text: "Draft"))
        XCTAssertTrue(policy.hasShown(surface: "card.refine-1", text: "Refine 1"))

        // Observed from here on: a new head is new text, and flaps.
        try store.writeCheckpoint(Checkpoint(id: 2, stage: .synthesis, round: 0, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan 2\n".utf8)], into: &tape)
        svc.pollTapes()
        XCTAssertTrue(policy.shouldFlap(surface: "board.now", text: "Synthesis", reduceMotion: false))
    }

    /// The CONVERGENCE word is folded off the main actor after the board is seeded, so it is
    /// seeded when the series first arrives: showing the intake must not flap a word that was
    /// already true before anyone looked. A word that changes while observed still flaps.
    func testConvergenceWordIsSeededOnceKnown() async throws {
        let i = try seed(.shaping)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        tape.status = .paused
        for round in [1, 2] {
            try store.writeCheckpoint(Checkpoint(id: round, stage: .refine, round: round, major: false, createdAt: clockNow,
                                                 record: RoundRecord(changeCount: round == 1 ? 40 : 10)),
                                      files: ["plan.md": Data("# Plan\n\nround \(round)\n".utf8)], into: &tape)
        }
        let svc = await makeService(awaitRecovery: false)
        // Asked for before the fold lands: the board is seeded, the word can't be yet.
        let policy = svc.flapPolicy(for: i.id)
        await svc.launchRecovery?.value
        await svc.convergenceFold(for: i.id)?.value
        let word = try XCTUnwrap(ConvergenceCellModel(cycles: svc.convergence[i.id] ?? [])).word
        XCTAssertEqual(word, "CONVERGING ↘")
        XCTAssertFalse(policy.shouldFlap(surface: "lcd.convergence", text: word, reduceMotion: false))

        // A round lands while observed and the verdict moves: the new word is news, and flaps.
        try store.writeCheckpoint(Checkpoint(id: 3, stage: .refine, round: 3, major: true, createdAt: clockNow,
                                             record: RoundRecord(changeCount: 30)),
                                  files: ["plan.md": Data("# Plan\n\nround 3\n".utf8)], into: &tape)
        svc.pollTapes()
        await svc.convergenceFold(for: i.id)?.value
        let next = try XCTUnwrap(ConvergenceCellModel(cycles: svc.convergence[i.id] ?? [])).word
        XCTAssertEqual(next, "DIVERGING ↗")
        XCTAssertTrue(policy.shouldFlap(surface: "lcd.convergence", text: next, reduceMotion: false))
    }

    /// A policy first asked for after the series is known seeds the word with the board.
    func testConvergenceWordIsSeededWithTheBoardWhenAlreadyKnown() async throws {
        let i = try seed(.shaping)
        let store = tapeStore(i.id)
        var tape = Tape.empty
        tape.status = .paused
        for round in [1, 2] {
            try store.writeCheckpoint(Checkpoint(id: round, stage: .refine, round: round, major: false, createdAt: clockNow,
                                                 record: RoundRecord(changeCount: round == 1 ? 40 : 10)),
                                      files: ["plan.md": Data("# Plan\n\nround \(round)\n".utf8)], into: &tape)
        }
        let svc = await makeService()
        let word = try XCTUnwrap(ConvergenceCellModel(cycles: svc.convergence[i.id] ?? [])).word
        XCTAssertFalse(svc.flapPolicy(for: i.id).shouldFlap(surface: "lcd.convergence", text: word, reduceMotion: false))
    }
}
