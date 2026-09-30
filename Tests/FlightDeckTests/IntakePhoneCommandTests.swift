import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// Records what the service asked of the runner, instead of spawning `fd-abduco` — copied from
/// `IntakeDetailProjectionTests`, whose copy is private to its file.
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

/// The phone's steer commands as the Mac applies them (spec §6.5): validated against the same
/// `TransportRules` the desktop bar reads, refused with a named code, and idempotent per token —
/// a retry after a lost ack must not queue a second Step or a second copy of a note.
@MainActor
final class IntakePhoneCommandTests: XCTestCase {
    private var root: URL!
    private var runner: FakeRunnerController!
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntakePhoneCommandTests-\(UUID())", isDirectory: true)
        runner = FakeRunnerController()
        runner.socketDirectory = root
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: fixtures (from IntakeDetailProjectionTests)

    private func makeService() async -> IntakeService {
        let svc = IntakeService(store: IntakeStore(root: root), headless: InertHeadlessRunner(),
                                processRunner: SilentProcessRunner(),
                                triageSettings: TriageSettings(harness: .codex, model: "m1", effort: "high"),
                                availableModels: .defaults, runner: runner,
                                inject: { _, _, _, _ in true }, hasSession: { _, _ in false },
                                now: { [unowned self] in self.clockNow },
                                readFile: { try? Data(contentsOf: $0) },
                                announce: { _ in })
        await svc.launchRecovery?.value
        for i in svc.intakes { await svc.convergenceFold(for: i.id)?.value }
        svc.pollTapes()
        return svc
    }

    /// Seeded with the Full-plan preset, whose reviewer and polisher give + and − a stage.
    @discardableResult
    private func seed(_ state: IntakeState) throws -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = state
        i.recommended = .fullPlan
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
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

    private func writeCheckpointFile(_ id: UUID, checkpoint: Int, _ name: String, _ text: String) throws {
        let dir = tapeStore(id).checkpointDirectory(checkpoint)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func commandLines(_ id: UUID) -> Int {
        guard let data = try? Data(contentsOf: tapeStore(id).commandsURL) else { return 0 }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    private func seedTape(_ status: RunnerStatus) throws -> Intake {
        let i = try seed(.shaping)
        try updateTape(i.id) { tape in
            tape.status = status
            if status == .running { tape.roundInProgress = PlannedRound(stage: .draft, round: 0, major: true) }
        }
        return i
    }

    private static let plan = "# P\n\n## 1. Scope\n\nKeep **account sign-in** in scope.\n\nShip the rest later."
    private static let phrase = "Keep **account sign-in** in scope."

    /// A shaping intake whose checkpoint 1 holds `plan`, and the block index of `phrase` in it.
    private func seedPlan(_ plan: String = plan, phrase: String = phrase) throws -> (Intake, Int) {
        let i = try seed(.shaping)
        try updateTape(i.id) { tape in
            tape.status = .paused
            tape.checkpoints = [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: self.clockNow)]
        }
        try writeCheckpointFile(i.id, checkpoint: 1, "plan.md", plan)
        let block = try XCTUnwrap(PlanBlocks.split(plan).blocks.first { $0.text == phrase }?.index)
        return (i, block)
    }

    /// The notes queued in `commands.jsonl`, withdrawals applied — notes are not folded into the
    /// published tape until a runner acks them, and no runner runs here.
    private func queuedNotes(_ id: UUID) -> [PlanNote] {
        tapeStore(id).commands(after: 0).reduce(into: []) { notes, queued in
            switch queued.command {
            case .note(let note): notes.append(note)
            case .removeNote(let withdrawn): notes.removeAll { $0.id == withdrawn }
            default: break
            }
        }
    }

    // MARK: transport

    func testAPauseWhileRunningIsQueued() async throws {
        let i = try seedTape(.running)
        let svc = await makeService()
        let before = commandLines(i.id)
        XCTAssertNil(svc.phoneTape(i.id, token: UUID(), command: "pause", stage: nil))
        XCTAssertEqual(svc.halts[i.id]?.kind, .pause)
        XCTAssertEqual(commandLines(i.id), before + 1)
    }

    func testARepeatedTokenAcksWithoutSendingAgain() async throws {
        let i = try seedTape(.paused)
        let svc = await makeService()
        let before = commandLines(i.id)
        let token = UUID()
        XCTAssertNil(svc.phoneTape(i.id, token: token, command: "step", stage: nil))
        XCTAssertNil(svc.phoneTape(i.id, token: token, command: "step", stage: nil), "a retry is acked")
        XCTAssertEqual(commandLines(i.id), before + 1, "but not applied twice")
    }

    func testAKeyTheRulesDisallowIsRefused() async throws {
        let failed = try seedTape(.failed)
        let running = try seedTape(.running)
        let svc = await makeService()
        XCTAssertEqual(svc.phoneTape(failed.id, token: UUID(), command: "nextMajor", stage: nil), "not_allowed")
        XCTAssertEqual(svc.phoneTape(running.id, token: UUID(), command: "step", stage: nil), "not_allowed")
        XCTAssertEqual(svc.phoneTape(running.id, token: UUID(), command: "rewind", stage: nil), "unknown_command")
    }

    func testExtendNeedsTheRulesStage() async throws {
        let i = try seedTape(.paused)
        let svc = await makeService()
        XCTAssertEqual(svc.phoneTape(i.id, token: UUID(), command: "extend", stage: "polish"), "not_allowed")
        XCTAssertNil(svc.phoneTape(i.id, token: UUID(), command: "extend", stage: "refine"))
    }

    /// A refused command does not burn its token: the corrected retry with the same token applies.
    func testARefusalLeavesTheTokenUsable() async throws {
        let i = try seedTape(.paused)
        let svc = await makeService()
        let token = UUID()
        let before = commandLines(i.id)
        XCTAssertEqual(svc.phoneTape(i.id, token: token, command: "extend", stage: "polish"), "not_allowed")
        XCTAssertNil(svc.phoneTape(i.id, token: token, command: "extend", stage: "refine"))
        XCTAssertEqual(commandLines(i.id), before + 1)
    }

    func testANonShapingIntakeHasMovedOn() async throws {
        let review = try seed(.review)
        let svc = await makeService()
        XCTAssertEqual(svc.phoneTape(review.id, token: UUID(), command: "pause", stage: nil), "intake_moved_on")
        XCTAssertEqual(svc.phoneTape(UUID(), token: UUID(), command: "pause", stage: nil), "unknown_intake")
        XCTAssertEqual(svc.phoneDefaultPlay(review.id, token: UUID(), mode: "step"), "intake_moved_on")
        XCTAssertEqual(svc.phoneNote(review.id, token: UUID(), noteID: UUID(), kind: "comment", text: "x",
                                     checkpoint: nil, block: nil, quote: nil), "intake_moved_on")
        XCTAssertEqual(svc.phoneRemoveNote(review.id, token: UUID(), noteID: UUID()), "intake_moved_on")
    }

    func testDefaultPlay() async throws {
        let i = try seedTape(.paused)
        let svc = await makeService()
        XCTAssertNil(svc.phoneDefaultPlay(i.id, token: UUID(), mode: "toReview"))
        XCTAssertEqual(svc.intakes.first { $0.id == i.id }?.roundConfig?.defaultPlay, .toReview)
        XCTAssertEqual(svc.phoneDefaultPlay(i.id, token: UUID(), mode: "sideways"), "unknown_mode")
    }

    // MARK: notes

    func testANoteOnAPhraseAnchorsToThatPhrase() async throws {
        let (i, block) = try seedPlan()
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "mustChange", text: "No.",
                                   checkpoint: 1, block: block, quote: "account sign-in in scope"))
        let note = try XCTUnwrap(queuedNotes(i.id).first { $0.id == noteID })
        XCTAssertEqual(note.kind, .mustChange)
        XCTAssertEqual(note.note, "No.")
        XCTAssertEqual(note.anchor?.quote, "account sign-in** in scope")
        XCTAssertEqual(note.anchor?.checkpoint, 1)
    }

    func testAPhraseNotFoundAnchorsToTheWholeBlock() async throws {
        let (i, block) = try seedPlan()
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "Hm.",
                                   checkpoint: 1, block: block, quote: "not in the text"))
        XCTAssertEqual(queuedNotes(i.id).first { $0.id == noteID }?.anchor?.quote, Self.phrase)
    }

    /// An earlier block that merely CONTAINS this block's text must not be taken for it: the
    /// phrase "TBD" on `- TBD` anchors in that item, not inside `- TBD later` above it.
    func testAnEarlierBlockContainingTheTextIsNotTheBlock() async throws {
        let (i, block) = try seedPlan("# P\n\n- TBD later\n- TBD\n\nEnd.", phrase: "- TBD")
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "Which?",
                                   checkpoint: 1, block: block, quote: "TBD"))
        let anchor = try XCTUnwrap(queuedNotes(i.id).first { $0.id == noteID }?.anchor)
        XCTAssertEqual(anchor.quote, "TBD")
        XCTAssertTrue(anchor.prefix.hasSuffix("- TBD later\n- "), "anchored inside the wrong block: \(anchor.prefix)")
        XCTAssertTrue(anchor.suffix.hasPrefix("\n\nEnd."), "anchored inside the wrong block: \(anchor.suffix)")
    }

    /// Two identical items: a note on the second anchors to the second.
    func testTheSecondOfTwoIdenticalBlocksIsTheSecond() async throws {
        let plan = "# P\n\n- TBD\n- TBD\n\nEnd."
        let (i, _) = try seedPlan(plan, phrase: "- TBD")
        let second = try XCTUnwrap(PlanBlocks.split(plan).blocks.last { $0.text == "- TBD" }?.index)
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "This one.",
                                   checkpoint: 1, block: second, quote: "TBD"))
        let anchor = try XCTUnwrap(queuedNotes(i.id).first { $0.id == noteID }?.anchor)
        XCTAssertTrue(anchor.prefix.hasSuffix("- TBD\n- "), "anchored to the first item: \(anchor.prefix)")
        XCTAssertTrue(anchor.suffix.hasPrefix("\n\nEnd."))
    }

    /// A blank quote is no phrase at all: the whole block, the same as a nil quote.
    func testABlankQuoteAnchorsToTheWholeBlock() async throws {
        let (i, block) = try seedPlan()
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "Hm.",
                                   checkpoint: 1, block: block, quote: "  "))
        XCTAssertEqual(queuedNotes(i.id).first { $0.id == noteID }?.anchor?.quote, Self.phrase)
    }

    func testAPlanWideNoteHasNoAnchor() async throws {
        let (i, _) = try seedPlan()
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "Overall fine.",
                                   checkpoint: nil, block: nil, quote: nil))
        let note = try XCTUnwrap(queuedNotes(i.id).first { $0.id == noteID })
        XCTAssertNil(note.anchor)
    }

    func testAHighlightMayBeEmptyButACommentOnAQuestionMayNot() async throws {
        let (i, block) = try seedPlan()
        let svc = await makeService()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: UUID(), kind: "comment", text: "",
                                   checkpoint: 1, block: block, quote: nil))
        XCTAssertEqual(svc.phoneNote(i.id, token: UUID(), noteID: UUID(), kind: "question", text: "  ",
                                     checkpoint: 1, block: block, quote: nil), "empty_note")
        XCTAssertEqual(svc.phoneNote(i.id, token: UUID(), noteID: UUID(), kind: "shout", text: "x",
                                     checkpoint: nil, block: nil, quote: nil), "unknown_kind")
    }

    func testBadBlockAndCheckpoint() async throws {
        let (i, _) = try seedPlan()
        let svc = await makeService()
        XCTAssertEqual(svc.phoneNote(i.id, token: UUID(), noteID: UUID(), kind: "comment", text: "x",
                                     checkpoint: 1, block: 999, quote: nil), "unknown_block")
        XCTAssertEqual(svc.phoneNote(i.id, token: UUID(), noteID: UUID(), kind: "comment", text: "x",
                                     checkpoint: 999, block: 0, quote: nil), "unknown_checkpoint")
    }

    func testARepeatedNoteTokenAddsOneNote() async throws {
        let (i, _) = try seedPlan()
        let svc = await makeService()
        let before = commandLines(i.id)
        let token = UUID()
        for _ in 0..<2 {
            XCTAssertNil(svc.phoneNote(i.id, token: token, noteID: UUID(), kind: "comment", text: "Once.",
                                       checkpoint: nil, block: nil, quote: nil))
        }
        XCTAssertEqual(commandLines(i.id), before + 1)
    }

    /// A retry after a lost ack finds the state its own first delivery changed — the note is
    /// already gone — and must still be acked, not refused as consumed.
    func testARetriedRemoveIsAckedNotRefused() async throws {
        let (i, _) = try seedPlan()
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "Drop me.",
                                   checkpoint: nil, block: nil, quote: nil))
        let token = UUID()
        XCTAssertNil(svc.phoneRemoveNote(i.id, token: token, noteID: noteID))
        let before = commandLines(i.id)
        XCTAssertNil(svc.phoneRemoveNote(i.id, token: token, noteID: noteID))
        XCTAssertEqual(commandLines(i.id), before)
    }

    func testRemovingAPendingNoteAndAConsumedOne() async throws {
        let (i, _) = try seedPlan()
        let svc = await makeService()
        let noteID = UUID()
        XCTAssertNil(svc.phoneNote(i.id, token: UUID(), noteID: noteID, kind: "comment", text: "Drop me.",
                                   checkpoint: nil, block: nil, quote: nil))
        XCTAssertNil(svc.phoneRemoveNote(i.id, token: UUID(), noteID: noteID))
        XCTAssertFalse(queuedNotes(i.id).contains { $0.id == noteID })
        XCTAssertEqual(svc.phoneRemoveNote(i.id, token: UUID(), noteID: UUID()), "note_consumed")
    }
}
