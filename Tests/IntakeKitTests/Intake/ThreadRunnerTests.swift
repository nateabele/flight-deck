import XCTest
@testable import IntakeKit

/// A scripted agent for ThreadRunner, modelled on `scripts/opencodeprobe/fake_llm.py`: what it
/// answers is chosen by a word in the human's message, so every test drives a real ThreadRunner
/// deterministically and no turn spends a token.
///
///     PROPOSE_STORAGE   -> proposes a diff to the Storage section (its quote occurs once)
///     PROPOSE_SYNC      -> proposes a diff to the Sync section
///     PROPOSE_AMBIGUOUS -> proposes a diff whose quote occurs twice, on every attempt
///     AMBIGUOUS_ONCE    -> ambiguous on the first attempt, the Storage diff on the retry
///     ADD_NOTE          -> adds a mustChange note anchored in Storage
///     ASK               -> asks a single-choice question
///     GATED             -> waits on the gate first (a turn the test holds open)
///     anything else     -> "Hello from the fake agent."
///
/// A retry resumes the session with only the refusals, so the agent remembers each thread's
/// word from its last message, as a real session would.
private final class ScriptedAgent: ThreadTurnExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ThreadTurnRequest] = []
    private var active = 0
    private var _maxActive = 0
    private var words: [ThreadID: String] = [:]
    private var attempts: [ThreadID: Int] = [:]
    let gate = Gate()

    var requests: [ThreadTurnRequest] { lock.withLock { _requests } }
    var maxActive: Int { lock.withLock { _maxActive } }

    static let keywords = ["PROPOSE_STORAGE", "PROPOSE_SYNC", "PROPOSE_AMBIGUOUS", "AMBIGUOUS_ONCE", "NOTE_AND_STORAGE",
                           "ADD_NOTE", "ASK", "GATED", "THROW"]
    /// Thrown for THROW: a file error, the kind the real executor throws when it can't set up
    /// a run's directory — not a cancellation.
    struct DiskFull: Error {}

    func run(_ r: ThreadTurnRequest) async throws -> ThreadTurnOutcome {
        let (word, attempt): (String?, Int) = lock.withLock {
            _requests.append(r)
            active += 1
            _maxActive = max(_maxActive, active)
            // The human's part of the prompt is everything after the first-turn template; a
            // keyword there sets the thread's mode until another one does.
            let human = r.prompt.components(separatedBy: "The human says:").last ?? r.prompt
            if let found = Self.keywords.first(where: { human.contains($0) }) {
                words[r.thread] = found
                attempts[r.thread] = 0
            } else if !r.prompt.contains("Your answer was not applied") {
                words[r.thread] = nil
            }
            attempts[r.thread, default: 0] += 1
            return (words[r.thread], attempts[r.thread]!)
        }
        defer { lock.withLock { active -= 1 } }
        if word == "GATED" || r.prompt.contains("GATED") { try await gate.wait() }
        if word == "THROW" { throw DiskFull() }
        let session = "sess-\(r.thread.raw.uuidString.prefix(8))"
        func diff(_ quote: String, _ replacement: String) -> ThreadAction {
            .proposeDiff(ProposedThreadDiff(checkpoint: Self.checkpoint(in: r.prompt) ?? 1, quote: quote, replacement: replacement))
        }
        let actions: [ThreadAction]
        switch word {
        case "PROPOSE_STORAGE": actions = [diff("Use SQLite for the queue.", "Use a file queue.")]
        case "PROPOSE_SYNC": actions = [diff("The client races the first sync.", "The client waits for the first sync.")]
        case "PROPOSE_AMBIGUOUS": actions = [diff("Retry the upload.", "Retry twice.")]
        case "AMBIGUOUS_ONCE":
            actions = attempt == 1 ? [diff("Retry the upload.", "Retry twice.")]
                : [diff("Use SQLite for the queue.", "Use a file queue.")]
        case "ADD_NOTE":
            actions = [.addNote(PlanNote(kind: .mustChange, note: "Name the queue's owner.",
                                         anchor: NoteAnchor(checkpoint: 1, quote: "Use SQLite for the queue.")))]
        case "NOTE_AND_STORAGE":
            actions = [.addNote(PlanNote(kind: .comment, note: "Owner?", anchor: nil)),
                       diff("Use SQLite for the queue.", "Use a file queue.")]
        case "ASK":
            actions = [.askQuestion(StructuredQuestion(id: "q1", text: "Which store?", kind: .single,
                                                       options: [.init(id: "a", label: "SQLite"), .init(id: "b", label: "Files")]))]
        default: actions = []
        }
        return .answered(ThreadAnswer(reply: "Hello from the fake agent.", decision: actions.isEmpty ? "" : "Decided.",
                                      actions: actions), sessionID: session)
    }

    /// The checkpoint the prompt says the workspace is, so a diff targets what the turn read.
    static func checkpoint(in prompt: String) -> Int? {
        guard let r = prompt.range(of: "is now checkpoint ") ?? prompt.range(of: "The plan is checkpoint ") else { return nil }
        return Int(prompt[r.upperBound...].prefix { $0.isNumber })
    }
}

/// Holds a call open until the test opens it; cancellation ends the wait by throwing.
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

final class ThreadRunnerTests: XCTestCase {
    static let plan = """
    # Plan

    ## Storage
    Retry the upload. Use SQLite for the queue.

    ## Sync
    Retry the upload. The client races the first sync.
    """
    /// A Refine round that left Storage alone and rewrote the Sync line the agent quotes.
    static let nextPlan = """
    # Plan

    ## Storage
    Retry the upload. Use SQLite for the queue.

    ## Sync
    Retry the upload. The client waits for the server before the first sync.
    """

    private var root: URL!
    private var intakeID: UUID!
    private var directory: URL { IntakeStore(root: root).directory(for: intakeID) }
    private var tapeStore: TapeStore { TapeStore(intakeDirectory: directory) }
    private var store: ThreadStore { ThreadStore(intakeDirectory: directory) }
    private var commands: ThreadCommandStore { ThreadCommandStore(intakeDirectory: directory) }
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-threads-\(UUID().uuidString)")
        let project = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let intake = Intake(projectPath: project.path, intent: "Add offline mode")
        intakeID = intake.id
        try IntakeStore(root: root).save(intake)
        var tape = Tape()
        try tapeStore.writeCheckpoint(Checkpoint(id: 1, stage: .refine, round: 1, major: false, createdAt: created),
                                      files: ["plan.md": Data(Self.plan.utf8)], into: &tape)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func runner(_ agent: ScriptedAgent, hooks: ThreadRunner.Hooks = .init()) -> ThreadRunner {
        ThreadRunner(root: root, intakeID: intakeID, executor: agent, pollInterval: .milliseconds(10), now: Date.init,
                     mergeRunner: SystemCommandRunner(), hooks: hooks)
    }

    private let storageAnchor = ThreadAnchor(note: NoteAnchor(checkpoint: 1, quote: "Use SQLite for the queue.",
                                                              section: "## Storage"))

    @discardableResult
    private func open(_ id: ThreadID = ThreadID(), autoAccept: Bool = false) throws -> ThreadID {
        try commands.append(.open(id, storageAnchor, title: "Why SQLite?", agent: .claude, model: "m", effort: "high"))
        if autoAccept { try commands.append(.setAutoAccept(id, true)) }
        return id
    }

    private func send(_ id: ThreadID, _ text: String, messageID: String = UUID().uuidString) throws {
        try commands.append(.message(id, text: text, messageID: messageID, source: nil, elementID: nil, subjectRevision: nil))
    }

    /// Lands a Refine round as IntakeRunner would: the checkpoint's files, then the tape.
    private func landRound(_ plan: String = ThreadRunnerTests.nextPlan) throws {
        var tape = tapeStore.loadTape()
        try tapeStore.writeCheckpoint(Checkpoint(id: 2, parent: 1, stage: .refine, round: 2, major: false, createdAt: created),
                                      files: ["plan.md": Data(plan.utf8)], into: &tape)
    }

    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Trash and Discard (A-I1)

    /// Trash moves the intake's folder away while a turn runs and another waits. The runner runs
    /// no further turn, and nothing it writes afterwards recreates the folder at the old path,
    /// which would make Finder's Put Back fail.
    func testATrashedIntakeRunsNoQueuedTurnAndRecreatesNothing() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "GATED first")
        try send(id, "And a second one")
        let done = Flag()
        let run = Task { await runner(agent).run(); done.set() }
        try await until("the first turn to start") { agent.gate.entered == 1 }

        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: trash.appendingPathComponent(intakeID.uuidString))
        agent.gate.open()
        try await until("the runner to exit") { done.value }
        run.cancel()

        XCTAssertEqual(agent.requests.count, 1, "the queued turn never ran")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing recreated at the old path")
    }

    /// Discard (or Trash with the folder still there): a `stop` in the thread log cancels the
    /// running turn and ends the runner before the queued one runs.
    func testAStopEndsTheRunnerBeforeAQueuedTurn() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "GATED first")
        try send(id, "And a second one")
        let done = Flag()
        let run = Task { await runner(agent).run(); done.set() }
        try await until("the first turn to start") { agent.gate.entered == 1 }

        try commands.append(.stop)
        try await until("the runner to stop") { done.value }
        agent.gate.open()
        run.cancel()
        _ = await run.value

        XCTAssertEqual(agent.requests.count, 1, "the queued turn never ran")
        XCTAssertEqual(store.cursor(), 4, "the stop is folded, so a later runner doesn't stop on it again")
        XCTAssertNil(store.heartbeat())
    }

    /// No store write creates a missing intake folder; inside an existing one, folders are made.
    func testStoreWritesNeverCreateTheIntakeFolder() throws {
        let gone = root.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try TapeStore(intakeDirectory: gone).appendCommand(.step))
        XCTAssertThrowsError(try ThreadCommandStore(intakeDirectory: gone).append(.resolve(ThreadID())))
        XCTAssertThrowsError(try ThreadStore(intakeDirectory: gone).saveCursor(1))
        ThreadStore(intakeDirectory: gone).saveHeartbeat(ThreadRunnerHeartbeat(pid: 1, heartbeat: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertNoThrow(try ThreadStore(intakeDirectory: directory).saveCursor(0))
    }

    // MARK: - One turn

    func testAMessageRunsOneTurnAndStoresTheReply() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "Why SQLite?", messageID: "m1")
        await runner(agent).run()

        let turns = store.turns(id)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].messageID, "m1")
        XCTAssertEqual(turns[0].you, "Why SQLite?")
        XCTAssertEqual(turns[0].reply, "Hello from the fake agent.")
        XCTAssertNotNil(turns[0].endedAt)
        XCTAssertEqual(turns[0].checkpoint, 1)
        let record = try XCTUnwrap(store.thread(id))
        XCTAssertEqual(record.status, .open)
        XCTAssertEqual(record.sessionID, "sess-\(id.raw.uuidString.prefix(8))")
        XCTAssertEqual(store.cursor(), 2)
        XCTAssertNil(store.heartbeat(), "an exited runner leaves no heartbeat")
        XCTAssertNil(store.activity(id))
    }

    /// The first turn: resume nothing, run in the repo, read the workspace, and carry only the
    /// outline, the anchor and its section, and an index of the rest.
    func testTheFirstTurnCarriesTheOutlineAnchorAndAnIndex() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "Why SQLite?")
        await runner(agent).run()

        let request = try XCTUnwrap(agent.requests.first)
        XCTAssertNil(request.resumeSessionID)
        XCTAssertEqual(request.project.standardizedFileURL.path, root.appendingPathComponent("repo").standardizedFileURL.path)
        XCTAssertEqual(request.readable, [store.workspaceDirectory(id)])
        XCTAssertEqual(request.agent, .claude)
        for expected in ["- s2 ## Storage", "> Use SQLite for the queue.", "It is in s2", "sections/s3.md", "intake.md",
                         "provenance/1.md", "Why SQLite?", AgentVocabulary.rule, "rg, git log"] {
            XCTAssertTrue(request.prompt.contains(expected), "first prompt lacks \(expected)")
        }
        XCTAssertFalse(request.prompt.contains("The client races the first sync."), "other sections are only indexed")
    }

    /// A later turn resumes the session and sends only what is new.
    func testALaterTurnResumesTheSession() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "Why SQLite?")
        await runner(agent).run()
        try send(id, "And backups?")
        await runner(agent).run()

        XCTAssertEqual(agent.requests.count, 2)
        XCTAssertEqual(agent.requests[1].resumeSessionID, "sess-\(id.raw.uuidString.prefix(8))")
        XCTAssertEqual(agent.requests[1].prompt, "And backups?")
        XCTAssertEqual(store.turns(id).map(\.seq), [1, 2])
    }

    /// Review focus 2: a phone retry or a canvas redelivery carries the same message id, in the
    /// same batch or a later one; exactly one turn runs.
    func testDuplicateMessageIDRunsOneTurn() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "Why SQLite?", messageID: "same")
        try send(id, "Why SQLite?", messageID: "same")
        await runner(agent).run()
        try send(id, "Why SQLite?", messageID: "same")
        await runner(agent).run()

        XCTAssertEqual(agent.requests.count, 1)
        XCTAssertEqual(store.turns(id).count, 1)
        XCTAssertEqual(store.cursor(), 4, "every copy is read past")
    }

    // MARK: - Validation

    /// Review focus 4: an ambiguous quote is fed back and retried, twice, and the turn then ends
    /// in "couldn't apply" with nothing applied.
    func testAmbiguousQuoteIsRetriedThenCouldntApply() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "PROPOSE_AMBIGUOUS")
        await runner(agent).run()

        XCTAssertEqual(agent.requests.count, 1 + ThreadRunner.retries)
        for retry in agent.requests.dropFirst() {
            XCTAssertTrue(retry.prompt.contains("ambiguous: the quote matches 2 places"), retry.prompt)
            XCTAssertNotNil(retry.resumeSessionID, "a retry resumes the session")
        }
        let turn = try XCTUnwrap(store.turns(id).first)
        XCTAssertTrue(turn.errors.first?.hasPrefix("couldn't apply: Action 1 (proposeDiff): ambiguous") ?? false, "\(turn.errors)")
        XCTAssertTrue(turn.actions.isEmpty)
        XCTAssertEqual(turn.reply, "Hello from the fake agent.")
        XCTAssertNotNil(turn.endedAt)
        XCTAssertTrue(store.diffs(id).isEmpty, "never applied")
        XCTAssertTrue(tapeStore.commands(after: 0).isEmpty, "nothing reaches the tape")
    }

    /// A retry that fixes the quote lands its diff, under the id its turn and position give it.
    func testARetryThatFixesTheQuoteKeepsTheDiff() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "AMBIGUOUS_ONCE")
        await runner(agent).run()

        XCTAssertEqual(agent.requests.count, 2)
        let diff = try XCTUnwrap(store.diffs(id).first)
        XCTAssertEqual(diff.id, ThreadIDs.diff(id, turn: 1, action: 0))
        XCTAssertEqual(diff.turn, 1)
        XCTAssertEqual(diff.state, .pending)
        XCTAssertEqual(diff.old, "Use SQLite for the queue.")
        XCTAssertEqual(diff.new, "Use a file queue.")
        XCTAssertEqual(diff.anchor.section, "## Storage")
        XCTAssertEqual(store.thread(id)?.status, .needsYou)
        XCTAssertEqual(store.turns(id).first?.errors, [])
    }

    // MARK: - Notes

    /// A note goes on the tape with the thread as its source and an id from (thread, turn,
    /// action); a turn rerun after a crash finds it there and doesn't add it again.
    func testNotesLandOnTheTapeOnceUnderADeterministicID() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "ADD_NOTE")
        await runner(agent).run()

        func notes() -> [PlanNote] {
            tapeStore.commands(after: 0).compactMap { if case .note(let n) = $0.command { n } else { nil } }
        }
        let note = try XCTUnwrap(notes().first)
        XCTAssertEqual(note.id, ThreadIDs.note(id, turn: 1, action: 0))
        XCTAssertEqual(note.source, .thread(id))
        XCTAssertEqual(note.kind, .mustChange)
        guard case .addNote(let stored) = store.turns(id).first?.actions.first else { return XCTFail("no stored note") }
        XCTAssertEqual(stored.id, note.id, "the turn's note and the tape's are the same note")

        // The crash: the turn's end never reached disk.
        var turns = store.turns(id)
        turns[0].endedAt = nil
        try store.save(turns: turns, of: id)
        await runner(agent).run()
        XCTAssertEqual(agent.requests.count, 2, "the unfinished turn ran again")
        XCTAssertEqual(notes().count, 1, "and its note landed once")
    }

    // MARK: - Rounds landing

    /// Review focus 1: a round lands while the agent works. The diff it proposed on the old
    /// version is carried onto the new one when its passage survived, and marked stale when the
    /// round rewrote it — never applied as a guess.
    func testRoundLandingMidTurnMakesDiffStaleOrRebased() async throws {
        let agent = ScriptedAgent()
        let survives = try open(), rewritten = try open()
        try send(survives, "GATED PROPOSE_STORAGE")
        try send(rewritten, "GATED PROPOSE_SYNC")
        let run = Task { await runner(agent).run() }
        try await until("both turns in the agent") { agent.gate.entered == 2 }
        try landRound()
        agent.gate.open()
        await run.value

        let carried = try XCTUnwrap(store.diffs(survives).first)
        XCTAssertEqual(carried.state, .pending)
        XCTAssertEqual(carried.checkpoint, 2, "rebased onto the round that landed")
        XCTAssertEqual(carried.anchor.checkpoint, 2)
        XCTAssertEqual(carried.old, "Use SQLite for the queue.")

        let gone = try XCTUnwrap(store.diffs(rewritten).first)
        XCTAssertEqual(gone.state, .stale, "the round rewrote its passage")
        XCTAssertEqual(gone.checkpoint, 1, "a stale diff keeps the version it was proposed on")
        XCTAssertEqual(store.thread(rewritten)?.status, .stale)
        XCTAssertTrue(tapeStore.commands(after: 0).isEmpty, "nothing applied")
    }

    /// The next turn after a round: a divider records "Now reading Refine 2", the pending diff
    /// is carried or marked stale, the workspace is rebuilt, and the resumed prompt says so.
    func testTheNextTurnAfterARoundDrawsADivider() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "PROPOSE_SYNC")
        await runner(agent).run()
        try landRound()
        try send(id, "Still racing?")
        await runner(agent).run()

        // C1: the queued turn keeps the seq it was given and the divider takes the next free
        // one, but the reader shows the divider just before the first turn that read its
        // version — the switch came before that answer, not after it.
        let turns = store.turns(id)
        XCTAssertEqual(turns.map(\.seq), [1, 3, 2], "stored seqs unchanged, shown in reading order")
        XCTAssertTrue(turns[1].isDivider)
        XCTAssertEqual(turns[1].reply, "Now reading Refine 2")
        XCTAssertEqual(turns[1].checkpoint, 2)
        XCTAssertEqual(turns[2].you, "Still racing?")
        XCTAssertEqual(turns[2].checkpoint, 2)
        XCTAssertEqual(store.diffs(id).first?.state, .stale)
        XCTAssertEqual(store.thread(id)?.followsCheckpoint, 2)
        let prompt = try XCTUnwrap(agent.requests.last?.prompt)
        XCTAssertTrue(prompt.contains("it is now checkpoint 2 (Refine 2)"), prompt)
        XCTAssertTrue(prompt.contains("- s3 ## Sync"))
        XCTAssertTrue(try String(contentsOf: store.workspaceDirectory(id).appendingPathComponent("sections/s3.md"),
                                 encoding: .utf8).contains("waits for the server"))
    }

    // MARK: - Auto-accept

    /// Auto-accept appends `applyThreadDiff` with the whole plan, built on the newest version
    /// there is: a human edit to the head still queued on the tape is kept, not overwritten.
    func testAutoAcceptBuildsOnAQueuedHumanEdit() async throws {
        let agent = ScriptedAgent()
        let id = try open(autoAccept: true)
        let humanEdit = Self.plan.replacingOccurrences(of: "The client races", with: "The client (edited) races")
        try tapeStore.appendCommand(.editPlan(checkpoint: 1, markdown: humanEdit))
        try send(id, "PROPOSE_STORAGE")
        await runner(agent).run()

        let applied = applyThreadDiffs()
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].checkpoint, 1)
        XCTAssertTrue(applied[0].markdown.contains("Use a file queue."), "the diff")
        XCTAssertTrue(applied[0].markdown.contains("The client (edited) races"), "the human's queued edit")
        XCTAssertEqual(store.diffs(id).first?.state, .accepted)
        XCTAssertEqual(store.thread(id)?.status, .open)
    }

    /// I2: an edit X that lands just before auto-accept appends is read, composed on and
    /// appended after in one critical section — exactly one `applyThreadDiff`, built on X.
    func testAutoAcceptComposesOnAnEditLandingJustBeforeIt() async throws {
        let agent = ScriptedAgent()
        let id = try open(autoAccept: true)
        let humanEdit = Self.plan.replacingOccurrences(of: "The client races", with: "The client (edited) races")
        let tapeStore = self.tapeStore
        let once = Once()
        let hooks = ThreadRunner.Hooks(beforeAutoAcceptAppend: {
            if once.fire() { _ = try? tapeStore.appendCommand(.editPlan(checkpoint: 1, markdown: humanEdit)) }
        })
        try send(id, "PROPOSE_STORAGE")
        await runner(agent, hooks: hooks).run()

        let applied = applyThreadDiffs()
        XCTAssertEqual(applied.count, 1, "one append, never a second to repair the first")
        XCTAssertTrue(applied[0].markdown.contains("Use a file queue."))
        XCTAssertTrue(applied[0].markdown.contains("The client (edited) races"), "built on X")
        XCTAssertEqual(store.diffs(id).first?.state, .accepted)
    }

    /// I2: however many human edits keep landing, the last word on the tape keeps the newest —
    /// no edit is lost, and the accept is never left on the tape behind a "stale" diff.
    func testNoHumanEditIsLostWhenEditsKeepLanding() async throws {
        let agent = ScriptedAgent()
        let id = try open(autoAccept: true)
        let tapeStore = self.tapeStore
        let counter = Counter()
        let hooks = ThreadRunner.Hooks(beforeAutoAcceptAppend: {
            let n = counter.next()
            _ = try? tapeStore.appendCommand(.editPlan(checkpoint: 1, markdown: ThreadRunnerTests.plan
                .replacingOccurrences(of: "The client races", with: "The client (edited \(n)) races")))
        })
        try send(id, "PROPOSE_STORAGE")
        await runner(agent, hooks: hooks).run()

        let last = try XCTUnwrap(tapeStore.commands(after: 0).last)
        guard case .applyThreadDiff(_, _, _, let markdown) = last.command else { return XCTFail("last is \(last.command)") }
        XCTAssertTrue(markdown.contains("(edited \(counter.value))"), "the newest human edit survives: \(markdown)")
        XCTAssertTrue(markdown.contains("Use a file queue."))
        XCTAssertEqual(store.diffs(id).first?.state, .accepted)
    }

    /// Auto-accept always targets the newest checkpoint: a diff proposed on 1 after round 2
    /// landed is applied to 2.
    func testAutoAcceptTargetsTheNewestCheckpoint() async throws {
        let agent = ScriptedAgent()
        let id = try open(autoAccept: true)
        try send(id, "GATED PROPOSE_STORAGE")
        let run = Task { await runner(agent).run() }
        try await until("the turn in the agent") { agent.gate.entered == 1 }
        try landRound()
        agent.gate.open()
        await run.value

        let applied = applyThreadDiffs()
        XCTAssertEqual(applied.map(\.checkpoint), [2])
        XCTAssertTrue(applied[0].markdown.contains("Use a file queue."))
        XCTAssertTrue(applied[0].markdown.contains("waits for the server"), "built on round 2's plan")
    }

    private func applyThreadDiffs() -> [(checkpoint: Int, markdown: String)] {
        tapeStore.commands(after: 0).compactMap {
            if case .applyThreadDiff(_, _, let cp, let md) = $0.command { (cp, md) } else { nil }
        }
    }

    // MARK: - Thread state

    func testDecideResolveAndReopen() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "PROPOSE_STORAGE")
        await runner(agent).run()
        let diff = try XCTUnwrap(store.diffs(id).first)
        try commands.append(.decideDiff(id, diff: diff.id, accept: false))
        try commands.append(.resolve(id))
        try send(id, "Ignored while resolved")
        await runner(agent).run()
        XCTAssertEqual(store.diffs(id).first?.state, .rejected)
        XCTAssertEqual(store.thread(id)?.status, .resolved)
        XCTAssertEqual(store.turns(id).count, 1, "a resolved thread takes no turns")

        try commands.append(.reopen(id))
        try commands.append(.setAgent(id, .codex, model: "c", effort: "low"))
        try send(id, "Back again")
        await runner(agent).run()
        XCTAssertEqual(store.turns(id).count, 2)
        XCTAssertEqual(agent.requests.last?.agent, .codex)
        XCTAssertNil(agent.requests.last?.resumeSessionID, "another agent starts its own session")
        XCTAssertEqual(store.thread(id)?.status, .open)
    }

    /// An answer to the agent's question runs a turn whose prompt pairs it with the question.
    func testAnAnswerIsSentWithItsQuestion() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "ASK")
        await runner(agent).run()
        XCTAssertEqual(store.thread(id)?.status, .needsYou)
        try commands.append(.answer(id, [StructuredAnswer(questionID: "q1", selected: ["b"])], messageID: "a1"))
        await runner(agent).run()
        XCTAssertEqual(agent.requests.last?.prompt, "Q: Which store?\nA: Files")
        XCTAssertEqual(store.turns(id).last?.answers?.first?.selected, ["b"])
    }

    /// Repropose runs one turn against the current version, telling the agent what went stale.
    func testReproposeRunsATurnForTheStaleDiff() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "PROPOSE_SYNC")
        await runner(agent).run()
        try landRound()
        try send(id, "Hi")
        await runner(agent).run()
        let stale = try XCTUnwrap(store.diffs(id).first { $0.state == .stale })
        try commands.append(.repropose(id, diff: stale.id))
        await runner(agent).run()
        let turn = try XCTUnwrap(store.turns(id).last)
        XCTAssertEqual(turn.reproposedDiff, stale.id)
        XCTAssertTrue(agent.requests.last?.prompt.contains("The client races the first sync.") ?? false)
    }

    // MARK: - Capacity and survival

    /// R3: at most two turns at once across an intake's threads; the third waits for a slot.
    func testAtMostTwoTurnsRunAtOnce() async throws {
        let agent = ScriptedAgent()
        let ids = try (0..<3).map { _ in try open() }
        for id in ids { try send(id, "GATED") }
        let run = Task { await runner(agent).run() }
        try await until("two turns in the agent") { agent.gate.entered == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(agent.gate.entered, 2, "the third is queued")
        XCTAssertEqual(ids.filter { store.thread($0)?.status == .answering }.count, 2)
        agent.gate.open()
        await run.value
        XCTAssertEqual(agent.maxActive, ThreadRunner.concurrencyCap)
        XCTAssertEqual(ids.map { store.turns($0).first?.endedAt != nil }, [true, true, true])
    }

    /// Review focus 5: the runner is a detached process, so the app quitting doesn't touch it;
    /// what does is the runner itself being shut down mid-turn. The finished turn stays done,
    /// the interrupted one stays queued, and the next runner resumes from the cursor and runs
    /// only that one — no turn runs twice to completion.
    func testRunnerSurvivesAppAndResumesCursor() async throws {
        let agent = ScriptedAgent()
        let a = try open(), b = try open()
        try send(a, "First")
        await runner(agent).run()
        try send(b, "GATED")
        let first = Task { await runner(agent).run() }
        try await until("b's turn in the agent") { agent.gate.entered == 1 }
        first.cancel()
        await first.value

        XCTAssertNotNil(store.turns(a).first?.endedAt)
        XCTAssertNil(store.turns(b).first?.endedAt, "the interrupted turn is still queued")
        XCTAssertNil(store.heartbeat())
        XCTAssertTrue(store.hasPendingWork(), "what tells the app to start a runner again")
        XCTAssertEqual(store.cursor(), 4, "the message was read before the turn ran")

        agent.gate.open()
        await runner(agent).run()
        XCTAssertEqual(agent.requests.filter { $0.thread == a }.count, 1, "the finished turn never reruns")
        XCTAssertEqual(agent.requests.filter { $0.thread == b }.count, 2, "the interrupted one ran again")
        XCTAssertEqual(store.turns(b).count, 1)
        XCTAssertEqual(store.turns(b).first?.reply, "Hello from the fake agent.")
        XCTAssertFalse(store.hasPendingWork())
        try send(b, "More")
        XCTAssertTrue(store.hasPendingWork(), "an unread command is work")
    }

    /// One runner per intake: a second one started while the first holds the lock does nothing.
    func testASecondRunnerStandsAside() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "GATED")
        let first = Task { await runner(agent).run() }
        try await until("the turn in the agent") { agent.gate.entered == 1 }
        await runner(agent).run()
        XCTAssertEqual(agent.requests.count, 1)
        agent.gate.open()
        await first.value
    }

    // MARK: - Fix round 1

    /// C1: a turn lands its note and its auto-accept, then the runner dies before the turn's
    /// end is saved; a round lands; the rerun keeps the turn's seq, so its note and diff keep
    /// their ids and land once. A divider is drawn once per head, however often it is retried.
    func testACrashedTurnRerunAfterARoundLandsNothingTwice() async throws {
        let agent = ScriptedAgent()
        let id = try open(autoAccept: true)
        try send(id, "Hi")
        await runner(agent).run()
        try send(id, "NOTE_AND_STORAGE")
        await runner(agent).run()
        XCTAssertEqual(notesOnTape().count, 1)
        XCTAssertEqual(applyThreadDiffs().count, 1)

        func crash(rewindTo checkpoint: Int? = nil) throws {
            var turns = store.turns(id)
            let i = try XCTUnwrap(turns.firstIndex { $0.messageID != "" && $0.actions.count == 2 })
            turns[i].endedAt = nil
            try store.save(turns: turns, of: id)
            if let checkpoint, var record = store.thread(id) {
                record.followsCheckpoint = checkpoint
                try store.save(record)
            }
        }
        try crash()
        try landRound()
        await runner(agent).run()
        // And the worst case: dying after the divider was drawn but before the thread recorded
        // the version it follows, so the rerun sees the round as new again.
        try crash(rewindTo: 1)
        await runner(agent).run()

        XCTAssertEqual(notesOnTape().count, 1, "no second note")
        XCTAssertEqual(applyThreadDiffs().count, 1, "no second applyThreadDiff")
        let turns = store.turns(id)
        XCTAssertEqual(turns.filter(\.isDivider).count, 1, "one divider per head")
        XCTAssertEqual(turns.first { $0.actions.count == 2 }?.seq, 2, "the turn kept its seq")
        XCTAssertEqual(store.diffs(id).count, 1)
        XCTAssertEqual(store.diffs(id).first?.state, .accepted)
    }

    /// I1: an executor that throws something other than a cancellation (a file it couldn't
    /// write) ends the turn as failed, and the runner goes idle instead of re-claiming it forever.
    func testAnExecutorErrorEndsTheTurnAsFailed() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "THROW")
        let finished = try await runWithin(seconds: 5, runner(agent))
        XCTAssertTrue(finished, "the runner went idle")
        XCTAssertLessThanOrEqual(agent.requests.count, 1, "claimed once, not in a loop")
        let turn = try XCTUnwrap(store.turns(id).first)
        XCTAssertNotNil(turn.endedAt)
        XCTAssertTrue(turn.errors.first?.hasPrefix("couldn't run:") ?? false, "\(turn.errors)")
        XCTAssertEqual(store.thread(id)?.status, .open)
    }

    /// A runner that died mid-turn left its thread `answering` with nothing running. The next
    /// runner puts it back to where it rests.
    func testAStuckAnsweringThreadIsResetAtStart() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        try send(id, "Hi")
        await runner(agent).run()
        var record = try XCTUnwrap(store.thread(id))
        record.status = .answering
        try store.save(record)
        await runner(agent).run()
        XCTAssertEqual(store.thread(id)?.status, .open)
        XCTAssertEqual(agent.requests.count, 1, "nothing ran")
    }

    /// The cursor never moves past a command whose turn couldn't be saved: the message is
    /// folded again once the disk lets it, and its turn runs.
    func testTheCursorStaysOnACommandWhoseSaveFailed() async throws {
        let agent = ScriptedAgent()
        let id = try open()
        await runner(agent).run()
        XCTAssertEqual(store.cursor(), 1)
        let dir = store.directory(id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        try send(id, "Hi")
        let run = Task { await runner(agent).run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.cursor(), 1, "not past the message whose turn didn't save")
        XCTAssertTrue(store.turns(id).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try await until("the turn ran") { store.turns(id).first?.endedAt != nil }
        await run.value
        XCTAssertEqual(store.cursor(), 2)
        XCTAssertEqual(agent.requests.count, 1)
    }

    private func notesOnTape() -> [PlanNote] {
        tapeStore.commands(after: 0).compactMap { if case .note(let n) = $0.command { n } else { nil } }
    }

    /// Runs `runner` and reports whether it returned within the time; a runner still going is
    /// cancelled, so a hot loop fails the test rather than hanging it.
    private func runWithin(seconds: TimeInterval, _ runner: ThreadRunner) async throws -> Bool {
        let done = Flag()
        let task = Task { await runner.run(); done.set() }
        let deadline = Date().addingTimeInterval(seconds)
        while !done.value && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if !done.value { task.cancel() }
        await task.value
        return Date() < deadline
    }

    /// R2: the live line reads the running turn's activity, and nothing once no turn runs.
    func testActivityShowsOnlyWhileATurnRuns() throws {
        let id = try open()
        try FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        var activity = SeatActivity(agent: .claude, startedAt: created)
        activity.action = ActivityAction(verb: "running", object: "rg queue")
        try IntakeJSON.encoder.encode(activity).write(to: store.activityURL(id))
        XCTAssertNil(store.activity(id), "no turn runs")
        try store.save(turns: [ThreadTurn(seq: 1, messageID: "m", you: "x", checkpoint: 1, startedAt: created)], of: id)
        XCTAssertEqual(store.activity(id), "running rg queue")
    }
}

/// Counts up from 1 on each `next()`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}

/// True exactly once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
