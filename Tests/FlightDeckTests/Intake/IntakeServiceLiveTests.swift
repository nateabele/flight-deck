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
/// that found nothing changed read nothing.
@MainActor
private final class ReadLog {
    private(set) var paths: [String] = []
    func count(_ suffix: String) -> Int { paths.filter { $0.hasSuffix(suffix) }.count }
    func count(containing part: String) -> Int { paths.filter { $0.contains(part) }.count }
    func reset() { paths = [] }
    nonisolated func read(_ url: URL) -> Data? {
        MainActor.assumeIsolated { paths.append(url.path) }
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
                             countRecovery: Bool = false) async -> IntakeService {
        let reads = self.reads!
        let svc = IntakeService(store: IntakeStore(root: root), headless: headless, processRunner: processRunner,
                                triageSettings: TriageSettings(harness: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { [unowned self] in self.clockNow },
                                readFile: { reads.read($0) })
        // Launch recovery runs one tick of its own; let it land, and (unless the test is about
        // that first read) start the counts from zero after it.
        await svc.launchRecovery?.value
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
        svc.pollTapes()
        XCTAssertEqual(reads.count(containing: "/checkpoints/"), firstReads, "no new checkpoint, no recompute")

        try store.writeCheckpoint(Checkpoint(id: 3, stage: .refine, round: 3, major: true, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n\nround 3\n".utf8)], into: &tape)
        svc.pollTapes()
        XCTAssertGreaterThan(reads.count(containing: "/checkpoints/"), firstReads)
        XCTAssertEqual(svc.convergence[i.id]?.first?.points.count, 3)
    }

    // MARK: flap policy

    func testFlapPolicyIsStablePerIntake() async throws {
        let svc = await makeService()
        let a = UUID(), b = UUID()
        XCTAssertTrue(svc.flapPolicy(for: a) === svc.flapPolicy(for: a))
        XCTAssertFalse(svc.flapPolicy(for: a) === svc.flapPolicy(for: b))
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
}
