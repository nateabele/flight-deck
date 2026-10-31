import Foundation
import Darwin

/// Runs one intake's ask threads (spec §5): folds `threads/commands.jsonl` into `threads/`,
/// runs each thread's queued turns through its agent, and appends to the tape only what must
/// reach the plan — a thread's notes and its auto-accepted diffs. It never writes `tape.json` or
/// `checkpoints/`, which stay IntakeRunner's, so the two run side by side.
///
/// Restartable like IntakeRunner: a turn is written to `turns.jsonl` the moment its message is
/// read, before the cursor moves past it, and keeps `endedAt` nil until it lands. A runner that
/// dies mid-turn leaves that turn queued, and the next one runs it again — under the same seq,
/// so the notes and diffs it makes get the same ids and land once.
public struct ThreadRunner: Sendable {
    /// At most this many turns run at once per intake (R3), across all its threads; a thread
    /// runs one turn at a time. Beside `CapacityPool.concurrencyCap`, which caps a round's
    /// seats: rounds and threads draw on the same accounts, and threads must not crowd a round.
    public static let concurrencyCap = 2
    /// A turn whose actions are refused is retried this many times with the refusals, then ends
    /// in "couldn't apply" (spec §5).
    public static let retries = 2

    private let root: URL
    private let intakeID: UUID
    private let executor: any ThreadTurnExecuting
    private let pollInterval: Duration
    private let now: @Sendable () -> Date
    private let mergeRunner: CommandRunner
    private let hooks: Hooks

    /// Test seams, internal on purpose: the instant between composing an auto-accepted plan
    /// and appending it, where a human edit could land unseen.
    struct Hooks: Sendable {
        var beforeAutoAcceptAppend: @Sendable () -> Void = {}
    }

    /// `executor` is the agent: `ThreadTurnExecutor` for the real CLIs, a scripted one in tests.
    /// `mergeRunner` runs `git merge-file` for `PlanRebase`.
    public init(root: URL, intakeID: UUID, executor: any ThreadTurnExecuting, pollInterval: Duration = .seconds(1),
                now: @escaping @Sendable () -> Date = Date.init, mergeRunner: CommandRunner = SystemCommandRunner()) {
        self.init(root: root, intakeID: intakeID, executor: executor, pollInterval: pollInterval, now: now,
                  mergeRunner: mergeRunner, hooks: Hooks())
    }

    init(root: URL, intakeID: UUID, executor: any ThreadTurnExecuting, pollInterval: Duration,
         now: @escaping @Sendable () -> Date, mergeRunner: CommandRunner, hooks: Hooks) {
        self.root = root
        self.intakeID = intakeID
        self.executor = executor
        self.pollInterval = pollInterval
        self.now = now
        self.mergeRunner = mergeRunner
        self.hooks = hooks
    }

    /// Runs until no thread has work, then exits. Like `IntakeRunner.run`, the lock is dropped
    /// before a last look at the commands: one that landed after the final read finds either
    /// this runner going round again or a fresh one the app spawns on seeing the heartbeat gone.
    /// Cancelling the calling task (a signal) cancels the running turns, which stay queued.
    public func run() async {
        let directory = IntakeStore(root: root).directory(for: intakeID)
        guard let intake = try? IntakeStore(root: root).load(id: intakeID) else { return }
        let store = ThreadStore(intakeDirectory: directory)
        try? FileManager.default.createDirectory(at: store.threadsDirectory, withIntermediateDirectories: true)
        guard let lock = ThreadRunnerLock(url: store.lockURL) else { return }
        let keeper = ThreadKeeper(store: store, tapeStore: TapeStore(intakeDirectory: directory),
                                  commands: ThreadCommandStore(intakeDirectory: directory), now: now)
        let context = TurnContext(intake: intake, executor: executor, mergeRunner: mergeRunner, now: now, hooks: hooks)
        while true {
            await drive(keeper, context)
            lock.release()
            guard !Task.isCancelled, await keeper.hasWork(), lock.acquire() else { return }
        }
    }

    private func drive(_ keeper: ThreadKeeper, _ context: TurnContext) async {
        let pid = getpid()
        // The turns are children of this group, so cancelling `run()` reaches every one of them
        // (and through `CommandRunner`'s process groups, every CLI they started).
        await withTaskGroup(of: Void.self) { group in
            while !Task.isCancelled {
                await keeper.beat(pid: pid)
                await keeper.fold()
                while await keeper.runningCount < Self.concurrencyCap, let next = await keeper.claimNext() {
                    group.addTask { await context.run(next, keeper) }
                }
                // Nothing running and nothing left to start or fold: done.
                if await keeper.runningCount == 0, await !keeper.hasWork() { break }
                // Wake when a turn ends or at the next poll, whichever is first: a freed slot
                // starts the next queued turn at once, and a new command waits one poll at most.
                let poll = Task { [pollInterval] in
                    try? await Task.sleep(for: pollInterval)
                    await keeper.wake()
                }
                await withTaskCancellationHandler {
                    await keeper.waitForTurnEnd()
                } onCancel: { poll.cancel() }
                poll.cancel()
            }
            group.cancelAll()
            await group.waitForAll()
        }
        await keeper.beat(pid: nil)
    }
}

// MARK: - Shared state

/// The one place `threads/` is read-modify-written. The command fold and every running turn
/// write the same files (a ⚙ toggling auto-accept while a turn saves its reply), so each change
/// is a whole read-modify-write inside this actor and none undoes another's.
actor ThreadKeeper {
    let store: ThreadStore
    let tapeStore: TapeStore
    let commands: ThreadCommandStore
    private let now: @Sendable () -> Date
    private var running = Set<ThreadID>()
    private var turnEndWaiters: [CheckedContinuation<Void, Never>] = []

    init(store: ThreadStore, tapeStore: TapeStore, commands: ThreadCommandStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.tapeStore = tapeStore
        self.commands = commands
        self.now = now
    }

    var runningCount: Int { running.count }

    func beat(pid: Int32?) {
        store.saveHeartbeat(pid.map { ThreadRunnerHeartbeat(pid: $0, heartbeat: now()) })
    }

    /// A command after the cursor, or a queued turn on a thread that takes turns.
    func hasWork() -> Bool { store.hasPendingWork() }

    // MARK: Commands

    /// Folds every command after the cursor into `threads/`, then moves the cursor past them.
    /// Turns are written before the cursor moves, so a crash between the two refolds the
    /// commands — and the `messageID` check makes a refolded message queue nothing twice.
    func fold() {
        let fresh = commands.commands(after: store.cursor())
        guard !fresh.isEmpty else { return }
        for envelope in fresh { apply(envelope) }
        try? store.saveCursor(fresh.last!.seq)
    }

    private func apply(_ envelope: ThreadCommandEnvelope) {
        let id = envelope.command.thread
        switch envelope.command {
        case .open(_, let anchor, let title, let agent, let model, let effort):
            guard store.thread(id) == nil else { return }
            let head = tapeStore.headPlanCheckpoint(in: tapeStore.loadTape()) ?? 0
            try? store.save(ThreadRecord(id: id, title: title, anchor: anchor, agent: agent, model: model, effort: effort,
                                         followsCheckpoint: head, createdAt: now()))
        case .message(_, let text, let messageID, _, _, _):
            queue(id, messageID: messageID, you: text, answers: nil)
        case .answer(_, let answers, let messageID):
            queue(id, messageID: messageID, you: nil, answers: answers)
        case .repropose(_, let diff):
            // One turn per repropose command: its seq names it, so a refold queues it once.
            queue(id, messageID: ThreadTurn.reproposePrefix + "\(diff.uuidString):\(envelope.seq)",
                  you: "Propose this change again against the current version.", answers: nil)
        case .setAutoAccept(_, let on):
            update(id) { $0.autoAccept = on }
        case .setAgent(_, let agent, let model, let effort):
            update(id) { record in
                // A session belongs to one CLI; another agent starts its own.
                if record.agent != agent { record.sessionID = nil }
                record.agent = agent
                record.model = model
                record.effort = effort
            }
        case .resolve:
            update(id) { $0.status = .resolved }
        case .reopen:
            update(id) { [store] record in
                guard record.status == .resolved else { return }
                record.status = Self.restingStatus(store.turns(id), store.diffs(id))
            }
        case .decideDiff(_, let diffID, let accept):
            guard var diff = store.diff(id, diffID), diff.state == .pending || diff.state == .stale else { return }
            diff.state = accept ? .accepted : .rejected
            try? store.save(diff)
            update(id) { [store] record in
                guard record.status != .resolved, !self.running.contains(id) else { return }
                record.status = Self.restingStatus(store.turns(id), store.diffs(id))
            }
        }
    }

    /// A resolved thread takes no turns until it is reopened (spec §5), so a message to it is
    /// dropped rather than queued to run on reopening. A thread this build never saw opened
    /// can't run a turn either.
    private func queue(_ id: ThreadID, messageID: String, you: String?, answers: [StructuredAnswer]?) {
        guard let record = store.thread(id), record.status != .resolved else { return }
        var turns = store.turns(id)
        guard !turns.contains(where: { $0.messageID == messageID }) else { return }
        turns.append(ThreadTurn(seq: (turns.map(\.seq).max() ?? 0) + 1, messageID: messageID, you: you, answers: answers,
                                checkpoint: record.followsCheckpoint, startedAt: now()))
        try? store.save(turns: turns, of: id)
    }

    // MARK: Scheduling

    /// The oldest queued turn of a thread that isn't running one, marked running. Threads are
    /// served oldest-queued first, so one chatty thread can't starve another.
    func claimNext() -> (thread: ThreadID, seq: Int)? {
        let candidates = store.threads().filter { !running.contains($0.id) }
            .compactMap { record in nextQueued(record).map { (record.id, $0) } }
            .sorted { ($0.1.startedAt, $0.1.seq) < ($1.1.startedAt, $1.1.seq) }
        guard let (id, turn) = candidates.first else { return nil }
        running.insert(id)
        update(id) { $0.status = .answering }
        return (id, turn.seq)
    }

    private func nextQueued(_ record: ThreadRecord) -> ThreadTurn? {
        guard record.status != .resolved else { return nil }
        return store.turns(record.id).first { $0.endedAt == nil && !$0.isDivider }
    }

    func turnEnded(_ id: ThreadID) {
        running.remove(id)
        wake()
    }

    func waitForTurnEnd() async {
        // A wake that came before the wait still counts, or a turn that ended in between
        // would leave the loop asleep until the next one.
        if woken { woken = false; return }
        await withCheckedContinuation { turnEndWaiters.append($0) }
    }

    /// Releases the drive loop's wait: a turn ended, or the poll interval ran out.
    func wake() {
        guard !turnEndWaiters.isEmpty else { woken = true; return }
        let waiters = turnEndWaiters
        turnEndWaiters = []
        waiters.forEach { $0.resume() }
    }
    private var woken = false

    // MARK: Writes

    func record(_ id: ThreadID) -> ThreadRecord? { store.thread(id) }
    func turns(_ id: ThreadID) -> [ThreadTurn] { store.turns(id) }
    func diffs(_ id: ThreadID) -> [ThreadDiff] { store.diffs(id) }

    func update(_ id: ThreadID, _ change: (inout ThreadRecord) -> Void) {
        guard var record = store.thread(id) else { return }
        change(&record)
        try? store.save(record)
    }

    func updateTurns(_ id: ThreadID, _ change: (inout [ThreadTurn]) -> Void) {
        var turns = store.turns(id)
        change(&turns)
        try? store.save(turns: turns, of: id)
    }

    func save(_ diff: ThreadDiff) { try? store.save(diff) }

    /// Where a thread rests once no turn runs: needing the human while a question or a diff
    /// waits on them, else open.
    static func restingStatus(_ turns: [ThreadTurn], _ diffs: [ThreadDiff]) -> ThreadStatus {
        if diffs.contains(where: { $0.state == .pending }) { return .needsYou }
        let lastAsked = turns.last { !$0.isDivider && $0.endedAt != nil }?.actions.contains {
            if case .askQuestion = $0 { return true } else { return false }
        } ?? false
        if lastAsked { return .needsYou }
        if diffs.contains(where: { $0.state == .stale }) { return .stale }
        return .open
    }
}

extension ThreadTurn {
    /// The `messageID` prefix of a turn a `repropose` queued: `repropose:<diff>:<command seq>`.
    public static let reproposePrefix = "repropose:"

    /// The stale diff a repropose turn is for.
    public var reproposedDiff: UUID? {
        guard messageID.hasPrefix(Self.reproposePrefix) else { return nil }
        return UUID(uuidString: String(messageID.dropFirst(Self.reproposePrefix.count).prefix(36)))
    }
}

// MARK: - One turn

/// Everything a turn needs that isn't on disk.
private struct TurnContext: Sendable {
    let intake: Intake
    let executor: any ThreadTurnExecuting
    let mergeRunner: CommandRunner
    let now: @Sendable () -> Date
    let hooks: ThreadRunner.Hooks

    var project: URL { URL(fileURLWithPath: intake.projectPath, isDirectory: true) }

    func run(_ claimed: (thread: ThreadID, seq: Int), _ keeper: ThreadKeeper) async {
        await runTurn(claimed.thread, seq: claimed.seq, keeper)
        await keeper.store.clearActivity(claimed.thread)
        await keeper.turnEnded(claimed.thread)
    }

    private func runTurn(_ id: ThreadID, seq initialSeq: Int, _ keeper: ThreadKeeper) async {
        let tapeStore = keeper.tapeStore, store = keeper.store
        guard var record = await keeper.record(id) else { return }
        let tape = tapeStore.loadTape()
        guard let head = tapeStore.headPlanCheckpoint(in: tape), let plan = tapeStore.effectivePlan(checkpoint: head) else {
            await end(id, seq: initialSeq, keeper) { $0.errors = ["There is no plan to read yet."] }
            return
        }

        // A round landed since this thread last read the plan: draw the divider, carry the
        // pending diffs onto the new version, and follow it.
        var seq = initialSeq
        var moved = false
        if record.followsCheckpoint != head {
            moved = true
            let label = tape.checkpoints.first { $0.id == head }.map(ThreadWorkspace.label) ?? "checkpoint \(head)"
            let hadTurns = await keeper.turns(id).contains { $0.endedAt != nil && !$0.isDivider }
            if hadTurns {
                await keeper.updateTurns(id) { turns in
                    // The divider takes this turn's place; it and every queued turn after it
                    // move down one. None of them has run, so nothing refers to their seqs yet.
                    for i in turns.indices where turns[i].seq >= seq && turns[i].endedAt == nil { turns[i].seq += 1 }
                    turns.append(ThreadTurn(seq: seq, messageID: ThreadTurn.dividerPrefix + "\(head)",
                                            reply: "Now reading \(label)", checkpoint: head, startedAt: now(), endedAt: now()))
                }
                seq += 1
            }
            for diff in await keeper.diffs(id) where diff.state == .pending && diff.checkpoint != head {
                await keeper.save(await rebase(diff, onto: head, headPlan: plan, tapeStore))
            }
            await keeper.update(id) { $0.followsCheckpoint = head }
            record.followsCheckpoint = head
        }
        await keeper.updateTurns(id) { turns in
            if let i = turns.firstIndex(where: { $0.seq == seq }) { turns[i].checkpoint = head }
        }
        guard let turn = await keeper.turns(id).first(where: { $0.seq == seq }) else { return }

        let workspace: ThreadWorkspace
        do {
            workspace = try ThreadWorkspace.build(in: store.workspaceDirectory(id), anchor: record.anchor, checkpoint: head,
                                                  plan: plan, tape: tape, store: tapeStore, intake: intake)
        } catch {
            await end(id, seq: seq, keeper) { $0.errors = ["Could not build the thread's workspace: \(error)"] }
            return
        }

        let earlier = await keeper.turns(id).filter { $0.seq < seq }
        let account = RunnerAccounts.load(from: tapeStore.intakeDirectory)?
            .entry(for: ModelChoice(agent: record.agent, model: record.model, effort: record.effort))
        var prompt = ThreadPrompts.turn(record: record, turn: turn, earlier: earlier, workspace: workspace,
                                        moved: moved && record.sessionID != nil, diffs: await keeper.diffs(id))
        var errors: [String] = []
        var lastReply: String?
        for attempt in 0...ThreadRunner.retries {
            let session = await keeper.record(id)?.sessionID
            let request = ThreadTurnRequest(thread: id, agent: record.agent, model: record.model, effort: record.effort,
                                            project: project, readable: [workspace.directory], prompt: prompt,
                                            resumeSessionID: session,
                                            runDirectory: store.runDirectory(id, name: "\(seq)-\(attempt)"),
                                            activityURL: store.activityURL(id), account: account?.ref,
                                            accountID: account?.accountID)
            let outcome: ThreadTurnOutcome
            do { outcome = try await executor.run(request) }
            catch { return } // Cancelled: the turn stays queued for the next runner.

            switch outcome {
            case .failed(let diagnosis, let sessionID):
                if let sessionID { await keeper.update(id) { $0.sessionID = sessionID } }
                await end(id, seq: seq, keeper) { $0.errors = ["couldn't run: \(diagnosis.detail)"] }
                return
            case .malformed(let why, let sessionID):
                if let sessionID { await keeper.update(id) { $0.sessionID = sessionID } }
                errors = ["The answer didn't match the schema: \(why)"]
            case .answered(let answer, let sessionID):
                await keeper.update(id) { $0.sessionID = sessionID }
                lastReply = answer.reply
                let outcome = ActionValidator.validate(answer.actions, checkpoint: head, plan: plan)
                if outcome.isValid {
                    await commit(answer, outcome.diffs, id: id, seq: seq, workspacePlan: plan, workspaceCheckpoint: head,
                                 keeper)
                    return
                }
                errors = outcome.errors
            }
            // The retry resumes the session, so it needs only what went wrong. With no session
            // (an answer that never got one) it starts over, refusals appended.
            let refusal = ThreadPrompts.retry(errors)
            prompt = await keeper.record(id)?.sessionID == nil ? prompt + "\n\n" + refusal : refusal
        }
        let finalReply = lastReply, finalErrors = errors
        await end(id, seq: seq, keeper) { turn in
            turn.reply = finalReply
            turn.errors = finalErrors.map { "couldn't apply: \($0)" }
        }
    }

    /// Lands a valid answer. Order matters for a crash: the diffs and notes first, each under an
    /// id derived from (thread, turn, action), then the turn's `endedAt` — so a turn that died
    /// before its end reruns, overwrites the same diff files and finds its notes already on the
    /// tape, and nothing lands twice.
    private func commit(_ answer: ThreadAnswer, _ located: [ActionValidator.LocatedDiff], id: ThreadID, seq: Int,
                        workspacePlan: String, workspaceCheckpoint: Int, _ keeper: ThreadKeeper) async {
        let tapeStore = keeper.tapeStore
        var actions = answer.actions
        for (i, action) in actions.enumerated() {
            guard case .addNote(var note) = action else { continue }
            note.id = ThreadIDs.note(id, turn: seq, action: i)
            note.source = .thread(id)
            actions[i] = .addNote(note)
            if !tapeHasNote(note.id, tapeStore) { _ = try? tapeStore.appendCommand(.note(note)) }
        }

        // A round that landed while the agent worked: the diffs were found on the version the
        // agent read, so carry them onto the new one or mark them stale — never apply a guess.
        let tape = tapeStore.loadTape()
        let head = tapeStore.headPlanCheckpoint(in: tape) ?? workspaceCheckpoint
        let headPlan = head == workspaceCheckpoint ? workspacePlan : (tapeStore.effectivePlan(checkpoint: head) ?? workspacePlan)
        let autoAccept = await keeper.record(id)?.autoAccept ?? false
        for d in located {
            var diff = ThreadDiff(id: ThreadIDs.diff(id, turn: seq, action: d.index), thread: id, turn: seq,
                                  checkpoint: workspaceCheckpoint, anchor: d.anchor, old: d.old, new: d.new)
            if let existing = await keeper.diffs(id).first(where: { $0.id == diff.id }), existing.state != .pending {
                continue // decided before a crash cut the turn short; leave the human's answer be
            }
            if head != workspaceCheckpoint {
                diff = await rebase(diff, base: workspacePlan, onto: head, headPlan: headPlan)
            }
            await keeper.save(diff)
            if autoAccept, diff.state == .pending {
                await keeper.save(await autoAcceptDiff(diff, keeper))
            }
        }

        let kept = actions
        await end(id, seq: seq, keeper) { turn in
            turn.reply = answer.reply
            turn.decision = answer.decision
            turn.actions = kept
            turn.errors = []
        }
    }

    /// Ends turn `seq` and settles the thread's status.
    private func end(_ id: ThreadID, seq: Int, _ keeper: ThreadKeeper, _ change: @Sendable (inout ThreadTurn) -> Void) async {
        let at = now()
        await keeper.updateTurns(id) { turns in
            guard let i = turns.firstIndex(where: { $0.seq == seq }) else { return }
            change(&turns[i])
            turns[i].endedAt = at
        }
        let turns = await keeper.turns(id), diffs = await keeper.diffs(id)
        await keeper.update(id) { record in
            guard record.status != .resolved else { return }
            record.status = ThreadKeeper.restingStatus(turns, diffs)
        }
    }

    // MARK: Rebase and auto-accept

    /// `diff` carried onto checkpoint `head`, whose effective plan is `headPlan`, or marked
    /// stale. The diff's own passage is found on the head first — a round that left it alone
    /// leaves it to apply as it is; failing that, the edit is three-way merged onto the head
    /// with `PlanRebase` (R4), and kept only when the merge is clean and is one hunk the diff
    /// can name. Anything else is stale: re-proposed, never applied as a guess.
    private func rebase(_ diff: ThreadDiff, onto head: Int, headPlan: String, _ tapeStore: TapeStore) async -> ThreadDiff {
        guard let base = tapeStore.effectivePlan(checkpoint: diff.checkpoint) else { return stale(diff) }
        return await rebase(diff, base: base, onto: head, headPlan: headPlan)
    }

    private func rebase(_ diff: ThreadDiff, base: String, onto head: Int, headPlan: String) async -> ThreadDiff {
        var moved = diff
        if case .success(let range) = ActionValidator.locate(quote: diff.old, prefix: diff.anchor.prefix,
                                                             suffix: diff.anchor.suffix, in: headPlan) {
            moved.checkpoint = head
            moved.anchor = NoteAnchor(checkpoint: head, selecting: range, in: headPlan)
            moved.old = String(headPlan[range])
            return moved
        }
        guard let edited = ActionValidator.apply(old: diff.old, anchor: diff.anchor, new: diff.new, to: base) else {
            return stale(diff)
        }
        let carried = await PlanRebase.retarget(markdown: edited, typedOn: diff.checkpoint, base: base, head: head,
                                                headPlan: headPlan, runner: mergeRunner)
        guard carried.conflict == nil, case .editPlan(_, let merged) = carried.command else { return stale(diff) }
        let hunks = PlanMetrics.hunks(from: headPlan, to: merged)
        guard hunks.count == 1, !hunks[0].oldLines.isEmpty else { return stale(diff) }
        let old = hunks[0].oldLines.joined(separator: "\n")
        guard case .success(let range) = ActionValidator.locate(quote: old, prefix: "", suffix: "", in: headPlan) else {
            return stale(diff)
        }
        moved.checkpoint = head
        moved.anchor = NoteAnchor(checkpoint: head, selecting: range, in: headPlan)
        moved.old = String(headPlan[range])
        moved.new = hunks[0].newLines.joined(separator: "\n")
        return moved
    }

    private func stale(_ diff: ThreadDiff) -> ThreadDiff {
        var d = diff
        d.state = .stale
        return d
    }

    /// Auto-accept (spec §5): ThreadRunner appends `applyThreadDiff` itself, always against the
    /// newest checkpoint. `applyThreadDiff` carries the WHOLE plan and replaces `plan.user.md`,
    /// so the plan it carries is built on the newest version there is, read just before the
    /// append: the last edit still queued on the tape for the head (one IntakeRunner hasn't
    /// folded yet), else the head's effective plan. The lock around the append (Stream B) can't
    /// also cover this read, so after appending it checks whether an edit to the head slipped in
    /// between; if one did, the diff is applied onto that edit and appended again, so the
    /// human's edit is never the one lost.
    private func autoAcceptDiff(_ diff: ThreadDiff, _ keeper: ThreadKeeper) async -> ThreadDiff {
        let tapeStore = keeper.tapeStore
        let all = tapeStore.commands(after: 0)
        // A crash after the append: it is on the tape already.
        if all.contains(where: { if case .applyThreadDiff(_, diff.id, _, _) = $0.command { true } else { false } }) {
            var d = diff
            d.state = .accepted
            return d
        }
        var current = diff
        var onto: (seq: Int, markdown: String)?
        for _ in 0..<3 {
            let tape = tapeStore.loadTape()
            guard let head = tapeStore.headPlanCheckpoint(in: tape),
                  let effective = tapeStore.effectivePlan(checkpoint: head) else { return stale(current) }
            let seen = tapeStore.commands(after: 0).last?.seq ?? 0
            let latest = onto?.markdown ?? Self.queuedEdit(for: head, after: tape.ackedCommandSeq, in: tapeStore)?.markdown
                ?? effective
            if current.checkpoint != head || onto != nil || latest != effective {
                let base = tapeStore.effectivePlan(checkpoint: current.checkpoint) ?? effective
                current = await rebase(current, base: base, onto: head, headPlan: latest)
                guard current.state == .pending else { return current }
            }
            guard let markdown = ActionValidator.apply(old: current.old, anchor: current.anchor, new: current.new, to: latest)
            else { return stale(current) }
            hooks.beforeAutoAcceptAppend()
            guard let seq = try? tapeStore.appendCommand(.applyThreadDiff(thread: current.thread, diff: current.id,
                                                                          checkpoint: head, markdown: markdown))
            else { return current }
            current.state = .accepted
            guard let slipped = tapeStore.commands(after: seen).last(where: { envelope in
                envelope.seq < seq && Self.edit(envelope.command, for: head) != nil
            }) else { return current }
            onto = (slipped.seq, Self.edit(slipped.command, for: head)!)
            current.state = .pending
        }
        return stale(current)
    }

    /// The last plan edit for `checkpoint` still queued on the tape after `acked`.
    private static func queuedEdit(for checkpoint: Int, after acked: Int, in tapeStore: TapeStore) -> (seq: Int, markdown: String)? {
        tapeStore.commands(after: acked).compactMap { e in edit(e.command, for: checkpoint).map { (e.seq, $0) } }.last
    }

    private static func edit(_ command: TapeCommand, for checkpoint: Int) -> String? {
        switch command {
        case .editPlan(checkpoint, let markdown), .applyThreadDiff(_, _, checkpoint, let markdown): markdown
        default: nil
        }
    }

    private func tapeHasNote(_ id: UUID, _ tapeStore: TapeStore) -> Bool {
        let tape = tapeStore.loadTape()
        if tape.pendingNotes.contains(where: { $0.id == id }) { return true }
        if tape.checkpoints.contains(where: { $0.record.annotations.contains { $0.id == id } }) { return true }
        return tapeStore.commands(after: 0).contains { if case .note(let n) = $0.command { n.id == id } else { false } }
    }
}

/// The ids a turn gives what it makes, from (thread, turn seq, action index): a turn rerun
/// after a crash makes the same note and the same diff, which land once.
public enum ThreadIDs {
    public static func note(_ thread: ThreadID, turn: Int, action: Int) -> UUID {
        stable("note\u{0}\(thread.raw.uuidString)\u{0}\(turn)\u{0}\(action)")
    }

    public static func diff(_ thread: ThreadID, turn: Int, action: Int) -> UUID {
        stable("diff\u{0}\(thread.raw.uuidString)\u{0}\(turn)\u{0}\(action)")
    }

    /// FNV-1a over the seed's UTF-8, twice with different bases for 128 bits — the same in every
    /// process, which `Hasher` is not.
    static func stable(_ seed: String) -> UUID {
        func fnv(_ basis: UInt64) -> UInt64 {
            var h = basis
            for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * i))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * i))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID, so it reads as one
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// The exclusive, non-blocking `flock` on `threads/runner.lock`: one ThreadRunner per intake.
/// The kernel drops it when the process dies, so a crashed runner leaves no stale lock.
private final class ThreadRunnerLock: @unchecked Sendable {
    private let fd: Int32

    init?(url: URL) {
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0, acquire() else { return nil }
    }

    func acquire() -> Bool { flock(fd, LOCK_EX | LOCK_NB) == 0 }
    func release() { flock(fd, LOCK_UN) }
    deinit { if fd >= 0 { close(fd) } }
}
