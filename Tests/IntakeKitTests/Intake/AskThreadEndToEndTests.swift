import XCTest
@testable import IntakeKit

/// An agent that answers every turn with one diff and a decision, as a real one would after
/// reading the anchored section. No tokens.
private struct ProposingAgent: ThreadTurnExecuting {
    func run(_ r: ThreadTurnRequest) async throws -> ThreadTurnOutcome {
        .answered(ThreadAnswer(reply: "One target keeps v1 small.", decision: "Mac only for v1.",
                               actions: [.proposeDiff(ProposedThreadDiff(checkpoint: 1, quote: "One",
                                                                         replacement: "One, Mac only"))]),
                  sessionID: "thread-session")
    }
}

/// P1 end to end, every runner real and every agent scripted: ✦ Ask on a passage → the thread's
/// agent replies with a diff → the human accepts it → the next round's seats see the edit as
/// the human's and the thread's decision line beside it (spec §11).
final class AskThreadEndToEndTests: XCTestCase {
    private let codexA = ModelChoice(agent: .codex, model: "A", effort: "high")
    private let claudeB = ModelChoice(agent: .claude, model: "B", effort: "medium")
    private static let draftPlan = "# Plan\n\n## Scope\nOne\n"
    private var root: URL!
    private var intake: Intake!

    private var project: URL { root.appendingPathComponent("project") }
    private var intakes: URL { root.appendingPathComponent("intakes") }
    private var directory: URL { IntakeStore(root: intakes).directory(for: intake.id) }
    private var tapeStore: TapeStore { TapeStore(intakeDirectory: directory) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AskThreadE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        intake = Intake(projectPath: project.path, intent: "Add dark mode")
        intake.roundConfig = RoundConfig(drafters: [Slot(codexA)], synthesizer: nil, reviewer: Slot(codexA),
                                         integrator: claudeB, encoder: codexA, polisher: nil, refinementCap: 2,
                                         polishCap: 0, freshEyesAndDedup: false, defaultPlay: .step, customized: false)
        try IntakeStore(root: intakes).save(intake)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func round(_ runner: ScriptedHarnessRunner) async -> RunnerStatus {
        await IntakeRunner(root: intakes, intakeID: intake.id,
                           executor: RoundExecutor(runner: runner, graphReader: GraphReader(runner: runner, environment: [:])),
                           environment: ["PATH": "/usr/bin:/bin"], pollInterval: .milliseconds(20)).run()
    }

    private static func seats(_ call: ScriptedHarnessRunner.Call) -> CommandResult {
        switch call.role {
        case "drafter": return ok(call, "d", json(DraftOutput(plan: draftPlan)))
        case "reviewer":
            return ok(call, "rev", json(ReviewOutput(changes: [ProposedChange(section: "## Scope", rationale: "r", edit: "e")],
                                                     summary: "found 1")))
        default:
            let plan = call.cwd.appendingPathComponent("plan.md")
            let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
            try! (before + "\n## Added\nline\n").write(to: plan, atomically: true, encoding: .utf8)
            return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 0, disagree: 0, notes: "applied")))
        }
    }

    private func threads() async {
        await ThreadRunner(root: intakes, intakeID: intake.id, executor: ProposingAgent(), pollInterval: .milliseconds(20)).run()
    }

    func testAskReplyAcceptAndTheNextRoundSeesTheDecision() async throws {
        // A draft to ask about.
        _ = try tapeStore.appendCommand(.step)
        let drafted = await round(ScriptedHarnessRunner(Self.seats))
        XCTAssertEqual(drafted, .paused)
        XCTAssertEqual(tapeStore.effectivePlan(checkpoint: 1), Self.draftPlan)

        // ✦ Ask on "One".
        let thread = ThreadID()
        let commands = ThreadCommandStore(intakeDirectory: directory)
        try commands.append(.open(thread, ThreadAnchor(note: NoteAnchor(checkpoint: 1, quote: "One", section: "Scope")),
                                  title: "Why one target?", agent: .claude, model: "m", effort: "e"))
        try commands.append(.message(thread, text: "Why only one?", messageID: "m1", source: nil, elementID: nil,
                                     subjectRevision: nil))
        await threads()

        // The reply, and a pending diff.
        let store = ThreadStore(intakeDirectory: directory)
        let turn = try XCTUnwrap(store.turns(thread).last)
        XCTAssertEqual(turn.reply, "One target keeps v1 small.")
        XCTAssertEqual(turn.decision, "Mac only for v1.")
        let diff = try XCTUnwrap(store.diffs(thread).first)
        XCTAssertEqual(diff.state, .pending)
        XCTAssertEqual(store.thread(thread)?.status, .needsYou)

        // ✓: the edit first, then the decision (the app's order).
        XCTAssertEqual(try ThreadAccept.append(diff, editedMarkdown: nil, to: tapeStore), .appended)
        XCTAssertEqual(try ThreadAccept.append(diff, editedMarkdown: nil, to: tapeStore), .already, "a retry appends nothing")
        try commands.append(.decideDiff(thread, diff: diff.id, accept: true))
        await threads()
        XCTAssertEqual(store.diffs(thread).first?.state, .accepted)
        XCTAssertEqual(store.thread(thread)?.status, .open)

        // The next round: the accepted text is the human's edit, its source recorded, and the
        // seats are told the decision behind it.
        _ = try tapeStore.appendCommand(.step)
        let next = ScriptedHarnessRunner(Self.seats)
        let refined = await round(next)
        XCTAssertEqual(refined, .paused)
        XCTAssertEqual(tapeStore.userEdits(checkpoint: 1), "# Plan\n\n## Scope\nOne, Mac only\n")
        XCTAssertEqual(tapeStore.threadEditSources(checkpoint: 1), [ThreadEditSource(thread: thread, diff: diff.id)])
        let reviewer = try XCTUnwrap(next.calls("reviewer").first).prompt
        XCTAssertTrue(reviewer.contains("+One, Mac only"), reviewer)
        XCTAssertTrue(reviewer.contains(RoundPrompts.threadDecisionsHeader), reviewer)
        XCTAssertTrue(reviewer.contains("""
        - "Why one target?", on "One" (Scope): Mac only for v1.
          Its change is already in the plan, among the human's edits.
        """), reviewer)
    }

    /// A-I2: a thread decided, and its diff accepted, while round 2 runs. Round 2 already read
    /// its plan, so round 3 is the first that can hear it: its seats get the decision (keyed on
    /// round 2's START, not its landing) and the accepted edit's source, carried forward onto
    /// round 2's checkpoint with the edit itself.
    func testAThreadDecidedMidRoundReachesTheNextRound() async throws {
        _ = try tapeStore.appendCommand(.step)
        let drafted = await round(ScriptedHarnessRunner(Self.seats))
        XCTAssertEqual(drafted, .paused)

        let thread = ThreadID()
        let diff = ThreadDiff(thread: thread, turn: 1, checkpoint: 1,
                              anchor: NoteAnchor(checkpoint: 1, quote: "One", section: "Scope"), old: "One", new: "One, Mac only")
        let dir = directory, tapes = tapeStore
        final class Count: @unchecked Sendable { var reviews = 0 }
        let count = Count()
        let midRound: @Sendable (ScriptedHarnessRunner.Call) -> CommandResult = { call in
            if call.role == "reviewer" {
                count.reviews += 1
                if count.reviews == 1 {
                    // The thread's turn ends now, mid round 2, and the human accepts its diff.
                    let store = ThreadStore(intakeDirectory: dir)
                    try! store.save(ThreadRecord(id: thread, title: "Why one target?",
                                                 anchor: ThreadAnchor(note: NoteAnchor(checkpoint: 1, quote: "One", section: "Scope")),
                                                 status: .open, agent: .claude, model: "m", effort: "e",
                                                 followsCheckpoint: 1, createdAt: Date()))
                    try! store.save(turns: [ThreadTurn(seq: 1, messageID: "m1", you: "Why only one?", reply: "Small v1.",
                                                       decision: "Mac only for v1.", checkpoint: 1,
                                                       startedAt: Date(), endedAt: Date())], of: thread)
                    var accepted = diff
                    accepted.state = .accepted
                    try! store.save(accepted)
                    _ = try! ThreadAccept.append(diff, editedMarkdown: nil, to: tapes)
                }
            }
            if call.role == "integrator", count.reviews == 1 {
                // Let the round's command watcher fold the accept before the round lands.
                let deadline = Date().addingTimeInterval(5)
                while tapes.threadEditSources(checkpoint: 1).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                // Away from the accepted line, so the carry merges cleanly.
                let plan = call.cwd.appendingPathComponent("plan.md")
                let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
                try! before.replacingOccurrences(of: "# Plan\n", with: "# Plan\n\nIntro.\n")
                    .write(to: plan, atomically: true, encoding: .utf8)
                return ok(call, "int", json(IntegrateOutput(agree: 1, somewhat: 0, disagree: 0, notes: "applied")))
            }
            return Self.seats(call)
        }

        _ = try tapeStore.appendCommand(.step)
        let second = await round(ScriptedHarnessRunner(midRound))
        XCTAssertEqual(second, .paused)
        XCTAssertEqual(tapeStore.threadEditSources(checkpoint: 2), [ThreadEditSource(thread: thread, diff: diff.id)],
                       "the source rides with the carried edit")

        _ = try tapeStore.appendCommand(.step)
        let third = ScriptedHarnessRunner(midRound)
        let thirdStatus = await round(third)
        XCTAssertEqual(thirdStatus, .paused)
        let reviewer = try XCTUnwrap(third.calls("reviewer").first).prompt
        XCTAssertTrue(reviewer.contains("""
        - "Why one target?", on "One" (Scope): Mac only for v1.
          Its change is already in the plan, among the human's edits.
        """), reviewer)
    }

    /// An accept composes on the newest version there is under the commands lock: a hand edit
    /// still queued for the head is kept, a diff from an older checkpoint applies to the head
    /// only where its passage still is, and an edited accept carries the human's text as it is,
    /// on the head only.
    func testAnAcceptComposesOnTheNewestQueuedEditOfTheHead() async throws {
        _ = try tapeStore.appendCommand(.step)
        let drafted = await round(ScriptedHarnessRunner(Self.seats))
        XCTAssertEqual(drafted, .paused)
        let thread = ThreadID()
        let diff = ThreadDiff(thread: thread, turn: 1, checkpoint: 1,
                              anchor: NoteAnchor(checkpoint: 1, quote: "One", section: "Scope"), old: "One", new: "One, Mac only")
        _ = try tapeStore.appendCommand(.editPlan(checkpoint: 1, markdown: "# Plan\n\n## Scope\nOne\n\n## Risks\nNone\n"))

        XCTAssertEqual(try ThreadAccept.append(diff, editedMarkdown: nil, to: tapeStore), .appended)
        guard case .applyThreadDiff(thread, diff.id, 1, let markdown) = try XCTUnwrap(tapeStore.commands(after: 0).last).command
        else { return XCTFail("expected applyThreadDiff") }
        XCTAssertEqual(markdown, "# Plan\n\n## Scope\nOne, Mac only\n\n## Risks\nNone\n", "the queued hand edit is kept")

        var old = diff
        old.id = UUID()
        old.checkpoint = 0
        old.old = "None"
        old.new = "Some"
        XCTAssertEqual(try ThreadAccept.append(old, editedMarkdown: nil, to: tapeStore), .appended)
        guard case .applyThreadDiff(_, old.id, 1, "# Plan\n\n## Scope\nOne, Mac only\n\n## Risks\nSome\n") =
                try XCTUnwrap(tapeStore.commands(after: 0).last).command
        else { return XCTFail("an old diff whose passage the head kept lands on the head") }
        var oldEdited = old
        oldEdited.id = UUID()
        XCTAssertEqual(try ThreadAccept.append(oldEdited, editedMarkdown: "# Plan\n", to: tapeStore), .stale)

        var edited = diff
        edited.id = UUID()
        XCTAssertEqual(try ThreadAccept.append(edited, editedMarkdown: "# Plan\n\n## Scope\nTwo\n", to: tapeStore), .appended)
        guard case .applyThreadDiff(_, edited.id, 1, "# Plan\n\n## Scope\nTwo\n") = try XCTUnwrap(tapeStore.commands(after: 0).last).command
        else { return XCTFail("expected the edited markdown") }

        var gone = diff
        gone.id = UUID()
        gone.old = "Nowhere in the plan"
        XCTAssertEqual(try ThreadAccept.append(gone, editedMarkdown: nil, to: tapeStore), .stale)
    }
    /// The UI fixture's shape exactly (`PlanningUIFixture`, `threads`): one draft checkpoint with
    /// only `drafts/0.md`, paused, notes pending, and a diff on the opening sentence anchored with
    /// the prefix and suffix a real selection captures. A ✓ there must append the edit.
    func testAnAcceptOnADraftOnlyPlanAppendsTheEdit() throws {
        var plan = "# Fixture Plan\n\nA synthetic plan for the planning inspector UI test.\n\n"
        for section in 1...3 { plan += "## \(section). Fixture section \(section)\n\n1. Step 1 of section \(section).\n\n" }
        var tape = tapeStore.loadTape()
        try tapeStore.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                      files: ["drafts/0.md": Data(plan.utf8)], into: &tape)
        tape.pendingNotes = [PlanNote(note: "Say more.")]
        tape.status = .paused
        try tapeStore.saveTape(tape)
        let old = "A synthetic plan for the planning inspector UI test."
        let anchor = NoteAnchor(checkpoint: 1, selecting: plan.range(of: old)!, in: plan)
        let diff = ThreadDiff(thread: ThreadID(), turn: 1, checkpoint: 1, anchor: anchor, old: old,
                              new: "A synthetic plan that an ask thread has edited.")
        XCTAssertEqual(try ThreadAccept.append(diff, editedMarkdown: nil, to: tapeStore), .appended)
        guard case .applyThreadDiff(_, diff.id, 1, let markdown) = try XCTUnwrap(tapeStore.commands(after: 0).last).command
        else { return XCTFail("no applyThreadDiff") }
        XCTAssertTrue(markdown.contains("an ask thread has edited"))
    }
}
