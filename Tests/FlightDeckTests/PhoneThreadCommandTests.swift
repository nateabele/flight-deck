import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

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

private final class SilentProcessRunner: FlywheelProcessRunner, @unchecked Sendable {
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) { ("", 127) }
}

private final class InertHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        (Data(), "", 1)
    }
}

/// The phone's thread ops as the Mac applies them: they APPEND commands (the Mac's single
/// writers stay single), are idempotent per token, name a new thread by its token, and write
/// the tape's edit before the thread's decision so a half-failed accept can't leave "accepted"
/// with no edit.
@MainActor
final class PhoneThreadCommandTests: XCTestCase {
    private var root: URL!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private static let plan = "# P\n\n## 1. Scope\n\nWe ship on Friday.\n\nLast words."

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneThreadCommandTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeService() async -> IntakeService {
        let runner = FakeRunnerController()
        runner.socketDirectory = root
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { [unowned self] in self.date },
                                readFile: { try? Data(contentsOf: $0) }, announce: { _ in })
        await svc.launchRecovery?.value
        svc.pollTapes()
        return svc
    }

    private func seed(_ state: IntakeState = .shaping) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = state
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        try IntakeStore(root: root).save(i)
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        var tape = tapes.loadTape()
        tape.status = .paused
        tape.checkpoints = [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: date)]
        try tapes.saveTape(tape)
        let dir = tapes.checkpointDirectory(1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.plan.utf8).write(to: dir.appendingPathComponent("plan.md"))
        return i
    }

    private func tapeCommands(_ id: UUID) -> [TapeCommand] {
        TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: id)).commands(after: 0).map(\.command)
    }
    private func threadCommands(_ id: UUID) -> [ThreadCommand] {
        ThreadCommandStore(intakeDirectory: IntakeStore(root: root).directory(for: id)).commands(after: 0).map(\.command)
    }

    private func record(_ id: ThreadID, status: ThreadStatus = .open) -> ThreadRecord {
        ThreadRecord(id: id, title: "t", anchor: .wholePlan, status: status, agent: .codex, model: "m", effort: "high",
                     followsCheckpoint: 1, createdAt: date)
    }

    private func diff(_ thread: ThreadID, state: DiffState = .pending, old: String = "We ship on Friday.") -> ThreadDiff {
        ThreadDiff(thread: thread, turn: 2, checkpoint: 1, anchor: NoteAnchor(checkpoint: 1, quote: old),
                   old: old, new: "We ship on Monday.", state: state)
    }

    // MARK: - send

    func testANewThreadIsNamedByItsTokenAndItsFirstMessageToo() async throws {
        let i = try seed(); let svc = await makeService(); let token = UUID()
        let refusal = svc.applyPhoneThreadSend(i.id, token: token, threadID: nil, anchor: nil, text: "Why Friday?",
                                               reader: FakeThreadReader())
        XCTAssertNil(refusal)
        let commands = threadCommands(i.id)
        XCTAssertEqual(commands.count, 2)
        guard case .open(let id, let anchor, let title, _, _, _) = commands[0] else { return XCTFail("\(commands)") }
        XCTAssertEqual(id, ThreadID.opened(byToken: token))
        XCTAssertEqual(anchor, .wholePlan)
        XCTAssertEqual(title, "Why Friday?")
        guard case .message(let on, let text, let messageID, _, _, _) = commands[1] else { return XCTFail("\(commands)") }
        XCTAssertEqual(on, id)
        XCTAssertEqual(text, "Why Friday?")
        XCTAssertEqual(messageID, ThreadCommand.firstMessageID(token: token))
    }

    func testARetryWithTheSameTokenAddsNothing() async throws {
        let i = try seed(); let svc = await makeService(); let token = UUID()
        for _ in 0..<2 {
            XCTAssertNil(svc.applyPhoneThreadSend(i.id, token: token, threadID: nil, anchor: nil, text: "Why?", reader: FakeThreadReader()))
        }
        XCTAssertEqual(threadCommands(i.id).count, 2)
    }

    /// The first append landed and the second did not (a crash between them): the retry, still
    /// under the same token, adds the message and not a second open.
    func testARetryAfterAHalfWrittenOpenAddsOnlyTheMessage() async throws {
        let i = try seed(); let svc = await makeService(); let token = UUID()
        let store = ThreadCommandStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        try store.append(.open(ThreadID.opened(byToken: token), .wholePlan, title: "Why?", agent: .codex, model: "m", effort: "high"))
        XCTAssertNil(svc.applyPhoneThreadSend(i.id, token: token, threadID: nil, anchor: nil, text: "Why?", reader: FakeThreadReader()))
        let commands = threadCommands(i.id)
        XCTAssertEqual(commands.count, 2)
        guard case .message = commands[1] else { return XCTFail("\(commands)") }
    }

    func testABlockAnchorBecomesTheSameAnchorAPhoneNoteGets() async throws {
        let i = try seed(); let svc = await makeService()
        let block = try XCTUnwrap(PlanBlocks.split(Self.plan).blocks.first { $0.text == "We ship on Friday." }?.index)
        XCTAssertNil(svc.applyPhoneThreadSend(i.id, token: UUID(), threadID: nil,
                                              anchor: WireThreadAnchor(checkpoint: 1, block: block, quote: "ship on Friday"),
                                              text: "Why?", reader: FakeThreadReader()))
        guard case .open(_, let anchor, _, _, _, _) = threadCommands(i.id)[0] else { return XCTFail() }
        XCTAssertEqual(anchor.note?.quote, "ship on Friday")
        XCTAssertEqual(anchor.note?.checkpoint, 1)
        XCTAssertEqual(anchor.note?.section, "## 1. Scope")
    }

    func testAReplyToAKnownThreadCarriesTheTokenAsItsMessageID() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID(), token = UUID()
        let reader = FakeThreadReader(records: [record(t)])
        XCTAssertNil(svc.applyPhoneThreadSend(i.id, token: token, threadID: t.raw, anchor: nil, text: "And Monday?", reader: reader))
        guard case .message(let on, _, let messageID, _, _, _) = threadCommands(i.id)[0] else { return XCTFail() }
        XCTAssertEqual(on, t)
        XCTAssertEqual(messageID, token.uuidString)
    }

    func testRefusals() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID()
        XCTAssertEqual(svc.applyPhoneThreadSend(i.id, token: UUID(), threadID: t.raw, anchor: nil, text: "hi", reader: FakeThreadReader()),
                       "unknown_thread")
        XCTAssertEqual(svc.applyPhoneThreadSend(i.id, token: UUID(), threadID: t.raw, anchor: nil, text: "hi",
                                                reader: FakeThreadReader(records: [record(t, status: .resolved)])), "thread_resolved")
        XCTAssertEqual(svc.applyPhoneThreadSend(i.id, token: UUID(), threadID: nil, anchor: nil, text: "  \n", reader: FakeThreadReader()),
                       "empty_message")
        XCTAssertEqual(svc.applyPhoneThreadSend(UUID(), token: UUID(), threadID: nil, anchor: nil, text: "hi", reader: FakeThreadReader()),
                       "unknown_intake")
        XCTAssertTrue(threadCommands(i.id).isEmpty)
    }

    /// A refusal does not burn the token, as for the sibling ops: a corrected retry still applies.
    func testARefusalDoesNotBurnTheToken() async throws {
        let i = try seed(); let svc = await makeService(); let token = UUID(), t = ThreadID()
        XCTAssertEqual(svc.applyPhoneThreadSend(i.id, token: token, threadID: t.raw, anchor: nil, text: "hi", reader: FakeThreadReader()),
                       "unknown_thread")
        XCTAssertNil(svc.applyPhoneThreadSend(i.id, token: token, threadID: t.raw, anchor: nil, text: "hi",
                                              reader: FakeThreadReader(records: [record(t)])))
    }

    // MARK: - resolve, answer

    func testResolveAppendsOnceAndAnswerNeedsAnOpenQuestion() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID(), token = UUID()
        let asking = ThreadTurn(seq: 1, messageID: "m", reply: "?", actions: [.askQuestion(
            StructuredQuestion(id: "q1", text: "Day?", kind: .single, options: [.init(id: "fri", label: "Fri")]))],
            checkpoint: 1, startedAt: date)
        let reader = FakeThreadReader(records: [record(t, status: .needsYou)], turnsByThread: [t: [asking]])
        for _ in 0..<2 { XCTAssertNil(svc.applyPhoneThreadResolve(i.id, token: token, threadID: t.raw, reader: reader)) }
        XCTAssertNil(svc.applyPhoneThreadAnswer(i.id, token: UUID(), threadID: t.raw,
                                                answers: [WireStructuredAnswer(questionID: "q1", selected: ["fri"])], reader: reader))
        let commands = threadCommands(i.id)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0], .resolve(t))
        guard case .answer(let on, let answers, _) = commands[1] else { return XCTFail() }
        XCTAssertEqual(on, t)
        XCTAssertEqual(answers, [StructuredAnswer(questionID: "q1", selected: ["fri"])])

        let quiet = FakeThreadReader(records: [record(t)], turnsByThread: [t: [ThreadTurn(seq: 1, messageID: "m", reply: "ok", checkpoint: 1, startedAt: date)]])
        XCTAssertEqual(svc.applyPhoneThreadAnswer(i.id, token: UUID(), threadID: t.raw, answers: [], reader: quiet), "stale_questions")
    }

    // MARK: - diffs

    func testAcceptWritesTheTapeEditFirstThenTheDecision() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID(); let d = diff(t)
        let reader = FakeThreadReader(records: [record(t)], diffsByThread: [t: [d]])
        XCTAssertNil(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: d.id, accept: true, reader: reader))
        guard case .applyThreadDiff(let thread, let diffID, let checkpoint, let markdown) = tapeCommands(i.id).last else { return XCTFail("\(tapeCommands(i.id))") }
        XCTAssertEqual(thread, t); XCTAssertEqual(diffID, d.id); XCTAssertEqual(checkpoint, 1)
        XCTAssertEqual(markdown, Self.plan.replacingOccurrences(of: "Friday", with: "Monday"))
        XCTAssertEqual(threadCommands(i.id), [.decideDiff(t, diff: d.id, accept: true)])
    }

    /// The thread's side fails (its directory path is a file): the tape's edit is already there,
    /// never the reverse, and the phone is told so it retries.
    func testAFailedSecondAppendLeavesTheEditNotAnAcceptWithoutOne() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID(); let d = diff(t)
        let dir = IntakeStore(root: root).directory(for: i.id)
        try Data().write(to: dir.appendingPathComponent("threads"))
        let reader = FakeThreadReader(records: [record(t)], diffsByThread: [t: [d]])
        let token = UUID()
        XCTAssertEqual(svc.applyPhoneDiffDecide(i.id, token: token, threadID: t.raw, diffID: d.id, accept: true, reader: reader), "write_failed")
        XCTAssertTrue(tapeCommands(i.id).contains { if case .applyThreadDiff = $0 { true } else { false } })
        // The retry, once the disk is healthy, adds the decision and no second edit.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("threads"))
        XCTAssertNil(svc.applyPhoneDiffDecide(i.id, token: token, threadID: t.raw, diffID: d.id, accept: true, reader: reader))
        XCTAssertEqual(tapeCommands(i.id).filter { if case .applyThreadDiff = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(threadCommands(i.id), [.decideDiff(t, diff: d.id, accept: true)])
    }

    func testRejectWritesOnlyTheDecision() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID(); let d = diff(t)
        let reader = FakeThreadReader(records: [record(t)], diffsByThread: [t: [d]])
        XCTAssertNil(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: d.id, accept: false, reader: reader))
        XCTAssertTrue(tapeCommands(i.id).isEmpty)
        XCTAssertEqual(threadCommands(i.id), [.decideDiff(t, diff: d.id, accept: false)])
    }

    func testAStaleDiffIsRefusedAndNothingIsWritten() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID()
        let stale = diff(t, state: .stale)
        let moved = diff(t, old: "Text a later round removed.")
        let reader = FakeThreadReader(records: [record(t)], diffsByThread: [t: [stale, moved]])
        for d in [stale, moved] {
            XCTAssertEqual(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: d.id, accept: true, reader: reader), "diff_stale")
        }
        XCTAssertTrue(tapeCommands(i.id).isEmpty)
        XCTAssertTrue(threadCommands(i.id).isEmpty)
    }

    func testAnAmbiguousPassageIsStaleNotGuessed() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID()
        let twice = "Same.\n\nSame."
        let store = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: i.id))
        try Data(twice.utf8).write(to: store.checkpointDirectory(1).appendingPathComponent("plan.md"))
        let d = diff(t, old: "Same.")
        let reader = FakeThreadReader(records: [record(t)], diffsByThread: [t: [d]])
        XCTAssertEqual(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: d.id, accept: true, reader: reader), "diff_stale")
    }

    func testDecidedAndUnknownDiffs() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID()
        let done = diff(t, state: .accepted)
        let reader = FakeThreadReader(records: [record(t)], diffsByThread: [t: [done]])
        XCTAssertNil(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: done.id, accept: true, reader: reader))
        XCTAssertEqual(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: done.id, accept: false, reader: reader), "diff_decided")
        XCTAssertEqual(svc.applyPhoneDiffDecide(i.id, token: UUID(), threadID: t.raw, diffID: UUID(), accept: true, reader: reader), "unknown_diff")
        XCTAssertTrue(tapeCommands(i.id).isEmpty && threadCommands(i.id).isEmpty)
    }

    // MARK: - get

    func testGetReturnsThePageOrAnUnknownThreadRefusal() async throws {
        let i = try seed(); let svc = await makeService(); let t = ThreadID()
        let reader = FakeThreadReader(records: [record(t)], turnsByThread: [t: [ThreadTurn(seq: 1, messageID: "m", you: "hi", checkpoint: 1, startedAt: date)]])
        let page = try svc.applyPhoneThreadGet(i.id, threadID: t.raw, since: nil, reader: reader).get()
        XCTAssertEqual(page.turns.map(\.seq), [1])
        XCTAssertEqual(svc.applyPhoneThreadGet(i.id, threadID: UUID(), since: nil, reader: reader), .failure(ThreadRefusal(code: "unknown_thread")))
    }
}
