import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// The Mac's ask-thread ops (spec §5, §6) as `IntakeService` applies them: each APPENDS to the
/// thread log (or, for an accepted diff, the tape's log too) and starts the intake's ThreadRunner;
/// ThreadRunner and IntakeRunner stay the single writers of `threads/` and the plan. The phone is
/// told it may ask. The wire bytes are `ThreadWireCodingTests`; the phone's ops
/// `PhoneThreadCommandTests`.
@MainActor
final class IntakeThreadServiceTests: XCTestCase {
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

    private static let plan = "# P\n\n## Scope\n\nWe ship on Friday.\n"
    private let thread = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var harness: FleetTestHarness!
    private var client: FleetClient!
    private var threadRunner: FakeRunnerController!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadService-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        threadRunner = FakeRunnerController(prefix: "threads-")
        threadRunner.socketDirectory = root
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        harness = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A shaping intake with one checkpoint whose plan is `plan`.
    private func shapingIntake(projectPath: String = "/p") throws -> Intake {
        var i = Intake(projectPath: projectPath, intent: "Plan the thing")
        i.state = .shaping
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        var tape = tapes.loadTape()
        tape.status = .paused
        tape.checkpoints = [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: date)]
        try tapes.saveTape(tape)
        try FileManager.default.createDirectory(at: tapes.checkpointDirectory(1), withIntermediateDirectories: true)
        try Data(Self.plan.utf8).write(to: tapes.checkpointDirectory(1).appendingPathComponent("plan.md"))
        return i
    }

    private func makeService(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) },
                             trashItem: @escaping (URL) throws -> Void = { _ in },
                             terminate: @escaping (Int32) -> Void = { _ in }) async -> IntakeService {
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: FakeRunnerController(prefix: "intake-"),
                                threadRunner: threadRunner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: now,
                                readFile: { try? Data(contentsOf: $0) }, announce: { _ in }, trashItem: trashItem,
                                terminateThreadRunner: terminate)
        await svc.launchRecovery?.value
        return svc
    }

    private func directory(_ id: UUID) -> URL { IntakeStore(root: root).directory(for: id) }
    private func threadCommands(_ id: UUID) -> [ThreadCommand] {
        ThreadCommandStore(intakeDirectory: directory(id)).commands(after: 0).map(\.command)
    }
    private func tapeCommands(_ id: UUID) -> [TapeCommand] {
        TapeStore(intakeDirectory: directory(id)).commands(after: 0).map(\.command)
    }

    /// Writes a thread (and its diffs) the way ThreadRunner would, so the service reads them back.
    private func writeThread(_ id: UUID, _ record: ThreadRecord, diffs: [ThreadDiff] = []) throws {
        let store = ThreadStore(intakeDirectory: directory(id))
        let dir = store.directory(record.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("diffs"), withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(record).write(to: dir.appendingPathComponent("thread.json"))
        for d in diffs {
            try IntakeJSON.encoder.encode(d).write(to: dir.appendingPathComponent("diffs/\(d.id.uuidString).json"))
        }
    }

    private func record(_ id: ThreadID, status: ThreadStatus = .open) -> ThreadRecord {
        ThreadRecord(id: id, title: "t", anchor: .wholePlan, status: status, agent: .codex, model: "m", effort: "high",
                     followsCheckpoint: 1, createdAt: date)
    }

    private func diff(_ thread: ThreadID, state: DiffState = .pending, checkpoint: Int = 1) -> ThreadDiff {
        ThreadDiff(thread: thread, turn: 1, checkpoint: checkpoint,
                   anchor: NoteAnchor(checkpoint: checkpoint, quote: "We ship on Friday."),
                   old: "We ship on Friday.", new: "We ship on Monday.", state: state)
    }

    // MARK: - Agent defaults and menu (Stream C, D8)

    func testTheThreadBindingDefaultsToTheIntakesIntegrator() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let integrator = try XCTUnwrap(i.roundConfig).integrator
        let defaults = svc.threadBinding(for: i.id).defaults()
        XCTAssertEqual(defaults, ThreadDefaults(agent: integrator.agent, model: integrator.model, effort: integrator.effort))
    }

    func testTheThreadMenuListsEveryRunnableAgentOnce() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let menu = svc.threadBinding(for: i.id).menu()
        XCTAssertFalse(menu.isEmpty)
        XCTAssertEqual(Set(menu.map(\.agent)), Set(svc.availableModels().choices.keys))
        XCTAssertEqual(Set(menu.map(\.id)).count, menu.count)
        let unbound = IntakeThreadBinding(intakeID: UUID(), reader: EmptyThreadStore(), service: nil)
        XCTAssertTrue(unbound.menu().isEmpty)
        XCTAssertEqual(unbound.defaults(), ThreadDefaults())
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

    /// Least privilege: a runner's token reaches no thread op, its own intake's included, at
    /// any level (`out_of_scope`). ThreadRunner writes `threads/` itself; it never asks the socket.
    func testAnIntakeRunnerCallerReachesNoThreadOp() {
        let own = UUID()
        let runner = ControlCaller.intakeRunner(own)
        for level in ControlScopeLevel.allCases {
            for (command, _) in Self.commands(intake: own, thread: thread) + Self.commands(intake: UUID(), thread: thread) {
                XCTAssertFalse(ControlScope.permits(command, level: level, caller: runner), "\(level) \(command)")
            }
            XCTAssertFalse(ControlScope.permits(FleetRequest.intakeThreadGet(id: own, threadID: thread, since: nil),
                                                level: level, caller: runner), "\(level)")
        }
    }

    // MARK: - The Mac's ops

    /// ✦ Ask: the open and its first message land in the thread log, in that order, the intake's
    /// ThreadRunner is started at once, and the phone is told it may ask.
    func testAskOpensTheThreadWithItsFirstMessageAndStartsTheThreadRunner() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let anchor = ThreadAnchor(note: NoteAnchor(checkpoint: 1, quote: "We ship on Friday.", section: "Scope"))
        let opened = svc.openThread(i.id, anchor: anchor, title: "", text: "  Why Friday?\nAnd not Monday? ", agent: .claude,
                                    model: "opus", effort: "high")
        let t = try opened.get()
        let logged = threadCommands(i.id)
        XCTAssertEqual(logged.count, 2)
        XCTAssertEqual(logged.first, .open(t, anchor, title: "Why Friday?", agent: .claude, model: "opus", effort: "high"))
        guard case .message(t, "Why Friday?\nAnd not Monday?", let messageID, nil, nil, nil) = logged.last
        else { return XCTFail("\(logged)") }
        XCTAssertFalse(messageID.isEmpty)
        XCTAssertEqual(threadRunner.started, [i.id])
        XCTAssertTrue(tapeCommands(i.id).isEmpty, "nothing reaches the tape until a diff is accepted")

        // A reply before ThreadRunner folds the open still lands (the thread is queued), and a
        // live runner is not started twice.
        threadRunner.running.insert(i.id)
        XCTAssertNil(svc.sendThreadMessage(i.id, thread: t, text: "One more thing"))
        XCTAssertEqual(threadRunner.started, [i.id])
        XCTAssertEqual(threadCommands(i.id).count, 3)

        // Through the binding the panel uses: an accepted send reads as accepted (nil), never as
        // the binding's "no service" refusal.
        withExtendedLifetime(svc) {
            let binding = svc.threadBinding(for: i.id)
            XCTAssertNil(binding.send(t, text: "Through the binding"))
            XCTAssertNil(binding.setAutoAccept(t, true))
            XCTAssertNil(binding.resolve(t))
        }
        XCTAssertEqual(threadCommands(i.id).count, 6)

        XCTAssertNotNil(svc.threadReader(i.id))
        let detail = try XCTUnwrap(IntakeDetailProjection.detail(i.id, project: UUID(), service: svc, servedAt: Date()))
        XCTAssertEqual(detail.threads, true)
    }

    func testRefusalsQueueNothing() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let resolved = ThreadID()
        try writeThread(i.id, record(resolved, status: .resolved))
        XCTAssertEqual(svc.sendThreadMessage(i.id, thread: ThreadID(), text: "x")?.code, "unknown_thread")
        XCTAssertEqual(svc.sendThreadMessage(i.id, thread: resolved, text: "x")?.code, "thread_resolved")
        XCTAssertEqual(svc.sendThreadMessage(i.id, thread: resolved, text: "  ")?.code, "empty_message")
        XCTAssertEqual(svc.openThread(i.id, anchor: .wholePlan, title: "", text: " ", agent: .codex, model: "m", effort: "e"),
                       .failure(ThreadRefusal(code: "empty_message")))
        XCTAssertEqual(svc.resolveThread(i.id, thread: ThreadID())?.code, "unknown_thread")
        XCTAssertEqual(svc.decideDiff(i.id, thread: resolved, diff: UUID(), accept: true)?.code, "unknown_diff")
        XCTAssertEqual(svc.reproposeDiff(i.id, thread: resolved, diff: UUID())?.code, "thread_resolved")
        XCTAssertTrue(threadCommands(i.id).isEmpty)
        XCTAssertTrue(threadRunner.started.isEmpty)

        // Reopening a resolved thread is what lets it take turns again.
        XCTAssertNil(svc.reopenThread(i.id, thread: resolved))
        XCTAssertEqual(threadCommands(i.id), [.reopen(resolved)])
    }

    /// ✓ on the Mac: the tape's `applyThreadDiff` first (composed on the head), then the thread's
    /// `decideDiff`. ✗ writes only the decision. A second ✓ adds no second edit.
    func testAcceptWritesTheEditThenTheDecisionAndRejectOnlyTheDecision() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID(), d = diff(t), other = diff(t)
        try writeThread(i.id, record(t), diffs: [d, other])

        XCTAssertNil(svc.decideDiff(i.id, thread: t, diff: d.id, accept: true))
        XCTAssertEqual(tapeCommands(i.id), [.applyThreadDiff(thread: t, diff: d.id, checkpoint: 1,
                                                             markdown: "# P\n\n## Scope\n\nWe ship on Monday.\n")])
        XCTAssertEqual(threadCommands(i.id), [.decideDiff(t, diff: d.id, accept: true)])
        XCTAssertNil(svc.decideDiff(i.id, thread: t, diff: d.id, accept: true))
        XCTAssertEqual(tapeCommands(i.id).count, 1, "a retry adds no second edit")

        XCTAssertNil(svc.decideDiff(i.id, thread: t, diff: other.id, accept: false))
        XCTAssertEqual(tapeCommands(i.id).count, 1)
        XCTAssertEqual(threadCommands(i.id).last, .decideDiff(t, diff: other.id, accept: false))
        XCTAssertEqual(threadRunner.started.first, i.id)
    }

    /// Edit, then Accept edited (ruling): the human's text is the `applyThreadDiff` markdown and
    /// the decision is an accept, whatever `accept` says.
    func testAnEditedAcceptCarriesTheHumansTextAsAnAccept() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID(), d = diff(t)
        try writeThread(i.id, record(t), diffs: [d])
        let edited = "# P\n\n## Scope\n\nWe ship on Tuesday, after the review.\n"
        // The binding holds the service weakly, as the views' does: keep it alive across the call.
        withExtendedLifetime(svc) {
            XCTAssertNil(svc.threadBinding(for: i.id).decideDiff(t, diff: d.id, accept: false, editedMarkdown: edited))
        }
        XCTAssertEqual(tapeCommands(i.id), [.applyThreadDiff(thread: t, diff: d.id, checkpoint: 1, markdown: edited)])
        XCTAssertEqual(threadCommands(i.id), [.decideDiff(t, diff: d.id, accept: true)])
    }

    /// A stale diff is refused, a decided one answers the same decision with no error and the
    /// other with `diff_decided`, and nothing is written for either.
    func testStaleAndDecidedDiffs() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID(), stale = diff(t, state: .stale), done = diff(t, state: .accepted)
        try writeThread(i.id, record(t), diffs: [stale, done])
        XCTAssertEqual(svc.decideDiff(i.id, thread: t, diff: stale.id, accept: true)?.code, "diff_stale")
        XCTAssertNil(svc.decideDiff(i.id, thread: t, diff: done.id, accept: true))
        XCTAssertEqual(svc.decideDiff(i.id, thread: t, diff: done.id, accept: false)?.code, "diff_decided")
        XCTAssertTrue(tapeCommands(i.id).isEmpty)
        XCTAssertTrue(threadCommands(i.id).isEmpty)
    }

    // MARK: - An accepted diff in the editor (A-I3, B-C1)

    /// The editor's router, wired the way `PlanSection` wires it: the live tape, the service's
    /// files and sends, and the plan queued on the tape.
    private func editorRouter(_ svc: IntakeService, _ id: UUID) -> PlanEditRouter {
        let router = svc.editRouter(id)
        router.env = PlanEditRouter.Env(tape: { svc.tapes[id] ?? .empty },
                                        loadFile: { svc.checkpointFile(id, checkpoint: $0, $1) },
                                        send: { svc.send(id, $0) },
                                        queued: { svc.queuedPlan(id, checkpoint: $0) })
        return router
    }

    /// What IntakeRunner does with the queued plan commands: each one, in order, becomes the
    /// checkpoint's `plan.user.md`, and the tape acks it.
    private func fold(_ id: UUID) throws {
        let tapes = TapeStore(intakeDirectory: directory(id))
        var tape = tapes.loadTape()
        for envelope in tapes.commands(after: tape.ackedCommandSeq) {
            switch envelope.command {
            case .editPlan(let checkpoint, let markdown):
                try tapes.writeUserEdits(checkpoint: checkpoint, markdown: markdown)
            case .applyThreadDiff(let thread, let diff, let checkpoint, let markdown):
                try tapes.writeUserEdits(checkpoint: checkpoint, markdown: markdown)
                try tapes.recordThreadEdit(checkpoint: checkpoint, ThreadEditSource(thread: thread, diff: diff))
            default: break
            }
            tape.ackedCommandSeq = envelope.seq
        }
        try tapes.saveTape(tape)
    }

    private func headPlan(_ id: UUID) -> String? {
        TapeStore(intakeDirectory: directory(id)).effectivePlan(checkpoint: 1)
    }

    /// The review's scenario: ✓, then the human types in the plan the editor loaded before the
    /// ✓, then IntakeRunner folds both. The hand edit is composed on the accept, so the accepted
    /// words survive — for a second commit of the same typing too, and after the fold.
    func testAHandEditAfterAnAcceptKeepsTheAcceptedWords() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID(), d = diff(t)
        try writeThread(i.id, record(t), diffs: [d])
        svc.pollTapes()
        let router = editorRouter(svc, i.id)
        let loaded = Self.plan

        XCTAssertNil(svc.decideDiff(i.id, thread: t, diff: d.id, accept: true))
        router.commit(Self.plan + "\nA hand note.\n", typedOn: 1, loaded: loaded, editable: true)
        await router.settle()
        try fold(i.id)
        svc.pollTapes()
        var plan = try XCTUnwrap(headPlan(i.id))
        XCTAssertTrue(plan.contains("We ship on Monday."), plan)
        XCTAssertTrue(plan.contains("A hand note."), plan)

        // More typing on the same load (the editor held the merge behind the banner).
        router.commit(Self.plan + "\nA hand note, and more.\n", typedOn: 1, loaded: loaded, editable: true)
        await router.settle()
        try fold(i.id)
        plan = try XCTUnwrap(headPlan(i.id))
        XCTAssertTrue(plan.contains("We ship on Monday."), plan)
        XCTAssertTrue(plan.contains("A hand note, and more."), plan)
    }

    /// The same from an accept the app didn't make — the phone's ✓ or ThreadRunner's
    /// auto-accept append `applyThreadDiff` straight to the tape's log.
    func testAHandEditAfterAnAcceptFromElsewhereKeepsTheAcceptedWords() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID(), d = diff(t)
        try writeThread(i.id, record(t), diffs: [d])
        svc.pollTapes()
        let router = editorRouter(svc, i.id)
        router.commit(Self.plan + "\nTyped first.\n", typedOn: 1, loaded: Self.plan, editable: true)

        XCTAssertEqual(try ThreadAccept.append(d, editedMarkdown: nil, to: TapeStore(intakeDirectory: directory(i.id))), .appended)
        router.commit(Self.plan + "\nTyped first, then more.\n", typedOn: 1, loaded: Self.plan, editable: true)
        await router.settle()
        try fold(i.id)
        let plan = try XCTUnwrap(headPlan(i.id))
        XCTAssertTrue(plan.contains("We ship on Monday."), plan)
        XCTAssertTrue(plan.contains("Typed first, then more."), plan)
    }

    /// Right after ✓ the editor reloads (its key moves) and loads the accepted plan — even over
    /// the router's own earlier send, which the accept was composed on and supersedes. A ✓ from
    /// the phone or auto-accept moves the key on the next tick.
    func testTheEditorShowsAnAcceptAtOnce() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID(), d = diff(t)
        try writeThread(i.id, record(t), diffs: [d])
        svc.pollTapes()
        let router = editorRouter(svc, i.id)
        let typed = Self.plan + "\nA hand note.\n"
        router.commit(typed, typedOn: 1, loaded: Self.plan, editable: true)
        func key() -> ShapingModel.ViewerKey {
            ShapingModel.viewerKey(selected: nil, mode: .plan, tape: svc.tapes[i.id] ?? .empty, accepted: svc.threadEditStamp(i.id))
        }
        func shown() -> String? {
            PlanSectionBody.planToShow(checkpoint: 1, tape: svc.tapes[i.id] ?? .empty,
                                       loadFile: { svc.checkpointFile(i.id, checkpoint: $0, $1) },
                                       queued: { svc.queuedPlan(i.id, checkpoint: $0) }, sent: router.sent)
        }
        let before = key()
        XCTAssertEqual(shown(), typed)

        XCTAssertNil(svc.decideDiff(i.id, thread: t, diff: d.id, accept: true))
        let accepted = typed.replacingOccurrences(of: "Friday", with: "Monday")
        XCTAssertNotEqual(key(), before, "the ✓ alone reloads the editor")
        XCTAssertEqual(shown(), accepted)

        try fold(i.id)
        svc.pollTapes()
        XCTAssertNil(svc.threadEditStamp(i.id), "folded: nothing queued")
        XCTAssertEqual(shown(), accepted, "the plan on disk, not the older send")

        // Another diff, accepted from outside the app: the next tick moves the key.
        let other = ThreadDiff(thread: t, turn: 2, checkpoint: 1, anchor: NoteAnchor(checkpoint: 1, quote: "A hand note."),
                               old: "A hand note.", new: "A hand note, reworded.")
        try writeThread(i.id, record(t), diffs: [other])
        let quiet = key()
        XCTAssertEqual(try ThreadAccept.append(other, editedMarkdown: nil, to: TapeStore(intakeDirectory: directory(i.id))), .appended)
        svc.pollTapes()
        XCTAssertNotEqual(key(), quiet)
        XCTAssertEqual(shown(), accepted.replacingOccurrences(of: "A hand note.", with: "A hand note, reworded."))
    }

    // MARK: - One message per draft (A-7)

    /// A double press sends one message: the draft's id is its messageID, and the same id again
    /// queues nothing. Without an id (an older caller), the same text still waiting unfolded in
    /// the log is the same press.
    func testADoublePressRunsOneTurn() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        let t = ThreadID()
        try writeThread(i.id, record(t))
        let draft = UUID().uuidString
        XCTAssertNil(svc.sendThreadMessage(i.id, thread: t, text: "Why?", messageID: draft))
        XCTAssertNil(svc.sendThreadMessage(i.id, thread: t, text: "Why?", messageID: draft))
        XCTAssertNil(svc.sendThreadMessage(i.id, thread: t, text: "And then?"))
        XCTAssertNil(svc.sendThreadMessage(i.id, thread: t, text: "And then?"))
        let answers = [StructuredAnswer(questionID: "q1", selected: ["a"])]
        XCTAssertNil(svc.answerThread(i.id, thread: t, answers: answers))
        XCTAssertNil(svc.answerThread(i.id, thread: t, answers: answers))
        let logged = threadCommands(i.id)
        XCTAssertEqual(logged.count, 3, "\(logged)")
        guard case .message(t, "Why?", draft, nil, nil, nil) = logged.first else { return XCTFail("\(logged)") }
    }

    // MARK: - Trash and Discard stop ThreadRunner (A-I1)

    private func beat(_ id: UUID, pid: Int32, at date: Date) throws {
        let threads = ThreadStore(intakeDirectory: directory(id))
        try FileManager.default.createDirectory(at: threads.threadsDirectory, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(ThreadRunnerHeartbeat(pid: pid, heartbeat: date)).write(to: threads.heartbeatURL)
    }

    /// Trash with a ThreadRunner beating: a `stop` goes to the thread log and the folder waits;
    /// once the heartbeat stops, the next tick trashes it.
    func testTrashStopsALiveThreadRunnerBeforeMovingTheFolder() async throws {
        let i = try shapingIntake()
        var trashed: [URL] = []
        let svc = await makeService(trashItem: { trashed.append($0) })
        try beat(i.id, pid: 4242, at: date)
        XCTAssertTrue(svc.moveToTrash(i.id, inProject: "/p"))
        XCTAssertEqual(threadCommands(i.id), [.stop])
        XCTAssertTrue(trashed.isEmpty, "the folder waits for the runner")

        svc.pollTapes()
        XCTAssertTrue(trashed.isEmpty, "still beating")
        try FileManager.default.removeItem(at: ThreadStore(intakeDirectory: directory(i.id)).heartbeatURL)
        svc.pollTapes()
        XCTAssertEqual(trashed, [directory(i.id)])
    }

    /// A runner that keeps beating past the grace gets SIGTERM, then the folder goes anyway.
    func testAThreadRunnerThatIgnoresTheStopIsTerminated() async throws {
        let i = try shapingIntake()
        var clock = date
        var trashed: [URL] = [], killed: [Int32] = []
        let svc = await makeService(now: { clock }, trashItem: { trashed.append($0) }, terminate: { killed.append($0) })
        try beat(i.id, pid: 4242, at: clock)
        XCTAssertTrue(svc.moveToTrash(i.id, inProject: "/p"))
        clock = clock.addingTimeInterval(IntakeService.threadStopGrace + 1)
        try beat(i.id, pid: 4242, at: clock)
        svc.pollTapes()
        XCTAssertEqual(killed, [4242])
        XCTAssertTrue(trashed.isEmpty)
        clock = clock.addingTimeInterval(IntakeService.threadStopGrace + 1)
        try beat(i.id, pid: 4242, at: clock)
        svc.pollTapes()
        XCTAssertEqual(trashed, [directory(i.id)], "two graces, then the folder goes")
    }

    /// Discard keeps the folder, so the `stop` is how the runner learns of it.
    func testDiscardStopsALiveThreadRunner() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        try beat(i.id, pid: 4242, at: date)
        XCTAssertTrue(svc.discard(i.id))
        XCTAssertEqual(threadCommands(i.id), [.stop])
    }

    // MARK: - ThreadRunner liveness

    /// A ThreadRunner that died with work left (a command after the cursor) is brought back by the
    /// tick; once there is no work, its leftover daemon is collected.
    func testTheTickBringsBackAThreadRunnerWithWorkAndReapsAnIdleOne() async throws {
        let i = try shapingIntake()
        let svc = await makeService()
        try ThreadCommandStore(intakeDirectory: directory(i.id)).append(.resolve(ThreadID()))
        svc.pollTapes()
        XCTAssertEqual(threadRunner.started, [i.id])
        svc.pollTapes()
        XCTAssertEqual(threadRunner.started, [i.id, i.id], "still not running, still work: started again")

        // The runner folded it (cursor past it) and exited, leaving its daemon's socket behind.
        let threads = ThreadStore(intakeDirectory: directory(i.id))
        try Data("1\n".utf8).write(to: threads.cursorURL)
        FileManager.default.createFile(atPath: threadRunner.socketPath(for: i.id), contents: nil)
        svc.pollTapes()
        XCTAssertEqual(threadRunner.started.count, 2)
        XCTAssertEqual(threadRunner.reaped, [i.id])
    }

    // MARK: - Wire

    /// The real `FleetService` arm over a real socket reaches the real op: a resolve of a thread
    /// that doesn't exist is refused as such, not as unavailable.
    func testAThreadOpThroughFleetServiceReachesTheOp() async throws {
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
        // A refusal on purpose: an accepted op would start a real ThreadRunner from this host.
        let command = FleetCommand.intakeThreadResolve(id: i.id, token: UUID(), threadID: UUID())
        client.onReady = { [weak self] in sent = self?.client.send(command) ?? 0 }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        guard case .err(_, let code, _) = try XCTUnwrap(reply) else { return XCTFail("expected err, got \(String(describing: reply))") }
        XCTAssertEqual(code, "unknown_thread")
    }
}

@MainActor
private final class FakeRunnerController: IntakeRunnerControlling {
    let prefix: String
    var socketDirectory: URL = FileManager.default.temporaryDirectory
    var running: Set<UUID> = []
    private(set) var started: [UUID] = []
    private(set) var reaped: [UUID] = []
    init(prefix: String) { self.prefix = prefix }
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { started.append(id); return .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { running.contains(id) }
    func reap(_ id: UUID) {
        reaped.append(id)
        try? FileManager.default.removeItem(atPath: socketPath(for: id))
    }
    func socketPath(for id: UUID) -> String {
        socketDirectory.appendingPathComponent("\(prefix)\(id.uuidString.lowercased()).sock").path
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
