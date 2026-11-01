import Foundation
import IntakeKit

/// Why a thread operation was refused. `code` is the machine-readable contract, the same
/// string the phone receives as an `err` code.
struct ThreadRefusal: Error, Equatable {
    let code: String
}

/// Ask threads' entry points on the Mac (spec §5, §6): what the Mac UI sends through, and the
/// ThreadRunner each intake's threads run in. The phone's ops are `IntakeService+PhoneThreads`.
///
/// Single writers: the app only APPENDS — a thread's commands to `threads/commands.jsonl`, an
/// accepted diff's `applyThreadDiff` to the tape's `commands.jsonl` — and ThreadRunner and
/// IntakeRunner fold them into the state each owns. After an append, the intake's ThreadRunner
/// is started if none is live (`kickThreads`), so a message never waits for the next tick.
extension IntakeService {
    /// What a binding whose service is gone answers (the panel outlived its window). An old
    /// Mac answered every thread op with it before threads shipped; the phone still maps it.
    static let threadsUnavailable = "threads_unavailable"
    static var unavailable: ThreadRefusal { ThreadRefusal(code: threadsUnavailable) }

    /// `id`'s threads as ThreadRunner last wrote them, for an intake this service knows. One
    /// store per intake, so its read cache (a stat per file when nothing changed) survives
    /// between the panel's polls.
    func threadReader(_ id: UUID) -> (any ThreadStoreReading)? {
        guard intake(id) != nil else { return nil }
        return threadStore(id)
    }

    func threadStore(_ id: UUID) -> ThreadStore {
        if let store = threadStores[id] { return store }
        let made = ThreadStore(intakeDirectory: tapeStore(id).intakeDirectory)
        threadStores[id] = made
        return made
    }

    /// What the detail pane hands `PlanNotesController` for intake `id`: the reader and the send
    /// API in one value, so the Ask cards and the thread panel are built on it without the
    /// detail view changing again.
    func threadBinding(for id: UUID) -> IntakeThreadBinding {
        IntakeThreadBinding(intakeID: id, reader: threadReader(id) ?? EmptyThreadStore(), service: self)
    }

    // MARK: - The Mac's ops

    /// A new thread on `anchor`, with its first message. Returns the thread's id at once; the
    /// turn runs in ThreadRunner.
    func openThread(_ id: UUID, anchor: ThreadAnchor, title: String, text: String, agent: AgentID, model: String,
                    effort: String) -> Result<ThreadID, ThreadRefusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ThreadRefusal(code: "empty_message")) }
        let thread = ThreadID()
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refusal = appendThread(id, [
            .open(thread, anchor, title: named.isEmpty ? Self.threadTitle(trimmed) : named, agent: agent, model: model, effort: effort),
            .message(thread, text: trimmed, messageID: UUID().uuidString, source: nil, elementID: nil, subjectRevision: nil),
        ]) { return .failure(refusal) }
        return .success(thread)
    }

    func sendThreadMessage(_ id: UUID, thread: ThreadID, text: String) -> ThreadRefusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ThreadRefusal(code: "empty_message") }
        if let refusal = openForTurns(id, thread) { return refusal }
        return appendThread(id, [.message(thread, text: trimmed, messageID: UUID().uuidString, source: nil, elementID: nil,
                                          subjectRevision: nil)])
    }

    /// Answers to the questions a turn asked (`askQuestion`).
    func answerThread(_ id: UUID, thread: ThreadID, answers: [StructuredAnswer]) -> ThreadRefusal? {
        if let refusal = openForTurns(id, thread) { return refusal }
        return appendThread(id, [.answer(thread, answers, messageID: UUID().uuidString)])
    }

    func setThreadAutoAccept(_ id: UUID, thread: ThreadID, _ on: Bool) -> ThreadRefusal? {
        if let refusal = known(id, thread) { return refusal }
        return appendThread(id, [.setAutoAccept(thread, on)])
    }

    func setThreadAgent(_ id: UUID, thread: ThreadID, agent: AgentID, model: String, effort: String) -> ThreadRefusal? {
        if let refusal = known(id, thread) { return refusal }
        return appendThread(id, [.setAgent(thread, agent, model: model, effort: effort)])
    }

    func resolveThread(_ id: UUID, thread: ThreadID) -> ThreadRefusal? {
        if let refusal = known(id, thread) { return refusal }
        return appendThread(id, [.resolve(thread)])
    }

    func reopenThread(_ id: UUID, thread: ThreadID) -> ThreadRefusal? {
        if let refusal = known(id, thread) { return refusal }
        return appendThread(id, [.reopen(thread)])
    }

    /// ✓ or ✗ on a pending diff. An accept also puts `TapeCommand.applyThreadDiff` on the tape.
    ///
    /// A non-nil `editedMarkdown` is the plan the human changed the proposal into (Edit, then
    /// Accept edited): it is the `applyThreadDiff` markdown, recorded as an accept (ruling).
    /// Without it an accept applies the diff's own replacement.
    ///
    /// The tape's `applyThreadDiff` is appended FIRST and the thread's `decideDiff` second: if the
    /// second append fails the edit is there and a retry adds the decision (`ThreadAccept` sees
    /// the edit and appends nothing twice), whereas the other order could leave a diff marked
    /// accepted that never changed the plan.
    func decideDiff(_ id: UUID, thread: ThreadID, diff diffID: UUID, accept: Bool, editedMarkdown: String? = nil) -> ThreadRefusal? {
        if let code = notShaping(id) { return ThreadRefusal(code: code) }
        let accept = accept || editedMarkdown != nil
        guard threadStore(id).thread(thread) != nil else { return ThreadRefusal(code: "unknown_thread") }
        guard let diff = threadStore(id).diff(thread, diffID) else { return ThreadRefusal(code: "unknown_diff") }
        switch diff.state {
        case .accepted, .rejected:
            // The same decision twice is no error (the phone and the Mac both pressed it).
            return (diff.state == .accepted) == accept ? nil : ThreadRefusal(code: "diff_decided")
        case .stale:
            // Stale is the runner's word that the passage moved: refused, as for the phone,
            // unless an earlier ✓ already put the edit on the tape (and so made it stale).
            if !(accept && threadDiffQueued(id, diffID)) { return ThreadRefusal(code: "diff_stale") }
        case .pending:
            break
        }
        if accept {
            if let refusal = acceptOnTape(id, diff, editedMarkdown: editedMarkdown) { return refusal }
        }
        return appendThread(id, [.decideDiff(thread, diff: diffID, accept: accept)])
    }

    /// One turn against the newest checkpoint for a stale diff.
    func reproposeDiff(_ id: UUID, thread: ThreadID, diff: UUID) -> ThreadRefusal? {
        if let refusal = openForTurns(id, thread) { return refusal }
        guard threadStore(id).diff(thread, diff) != nil else { return ThreadRefusal(code: "unknown_diff") }
        return appendThread(id, [.repropose(thread, diff: diff)])
    }

    // MARK: - Shared by the Mac's and the phone's ops

    /// `applyThreadDiff` for `diff`, composed on the newest version of the head under the
    /// commands lock (`ThreadAccept`); nil once it is on the tape. A diff that no longer applies
    /// is `diff_stale`: the human re-proposes it, nothing is applied as a guess.
    func acceptOnTape(_ id: UUID, _ diff: ThreadDiff, editedMarkdown: String?) -> ThreadRefusal? {
        let outcome: ThreadAccept.Outcome
        do { outcome = try ThreadAccept.append(diff, editedMarkdown: editedMarkdown, to: tapeStore(id)) }
        catch { return ThreadRefusal(code: "write_failed") }
        switch outcome {
        case .appended, .already: return nil
        case .stale: return ThreadRefusal(code: "diff_stale")
        }
    }

    /// Whether an `applyThreadDiff` for `diff` is already on the tape.
    func threadDiffQueued(_ id: UUID, _ diff: UUID) -> Bool {
        tapeStore(id).commands(after: 0).contains {
            if case .applyThreadDiff(_, diff, _, _) = $0.command { true } else { false }
        }
    }

    /// Appends `commands` to the intake's thread log, in order, and makes sure a ThreadRunner
    /// will fold them.
    func appendThread(_ id: UUID, _ commands: [ThreadCommand]) -> ThreadRefusal? {
        if let code = notShaping(id) { return ThreadRefusal(code: code) }
        let log = ThreadCommandStore(intakeDirectory: tapeStore(id).intakeDirectory)
        do { for command in commands { try log.append(command) } }
        catch { return ThreadRefusal(code: "write_failed") }
        kickThreads(id)
        return nil
    }

    /// A thread the reader has, or one opened a moment ago that ThreadRunner hasn't folded yet.
    private func known(_ id: UUID, _ thread: ThreadID) -> ThreadRefusal? {
        if let code = notShaping(id) { return ThreadRefusal(code: code) }
        if threadStore(id).thread(thread) != nil { return nil }
        let opening = ThreadCommandStore(intakeDirectory: tapeStore(id).intakeDirectory).commands(after: 0)
            .contains { if case .open(thread, _, _, _, _, _) = $0.command { true } else { false } }
        return opening ? nil : ThreadRefusal(code: "unknown_thread")
    }

    /// `known`, and not resolved: a resolved thread takes no turns until it is reopened (spec §5).
    /// Refused rather than queued, since ThreadRunner would drop the message without a word.
    private func openForTurns(_ id: UUID, _ thread: ThreadID) -> ThreadRefusal? {
        if let refusal = known(id, thread) { return refusal }
        return threadStore(id).thread(thread)?.status == .resolved ? ThreadRefusal(code: "thread_resolved") : nil
    }

    // MARK: - ThreadRunner

    /// Starts `id`'s ThreadRunner unless one is live. ThreadRunner holds `threads/runner.lock`,
    /// so a second one started in a race exits at once without touching anything.
    func kickThreads(_ id: UUID) {
        guard let threadRunner, intake(id)?.state == .shaping else { return }
        threadSockets.insert(id)
        guard !threadRunner.isRunning(id, tape: nil) else { return }
        _ = threadRunner.ensureRunning(id)
    }

    /// Each tick, for the shaping intakes: brings back a ThreadRunner that died with work left
    /// (a turn queued, a command not folded) and collects the `fd-abduco` daemon of one that has
    /// finished. Work is memoized on the thread files' stamps, so an idle tick costs a stat per
    /// file and starts nothing; the liveness probe (a socket connect) runs only when there is
    /// work or a daemon to collect.
    func pollThreads(_ shaping: Set<UUID>) {
        guard let threadRunner else { return }
        for id in shaping where hasThreadWork(id) {
            threadSockets.insert(id)
            if !threadRunner.isRunning(id, tape: nil) { _ = threadRunner.ensureRunning(id) }
        }
        for id in threadSockets where !(shaping.contains(id) && hasThreadWork(id)) {
            guard FileManager.default.fileExists(atPath: threadRunner.socketPath(for: id)) else {
                threadSockets.remove(id)
                continue
            }
            guard !threadRunner.isRunning(id, tape: nil) else { continue }
            threadRunner.reap(id)
            if !FileManager.default.fileExists(atPath: threadRunner.socketPath(for: id)) { threadSockets.remove(id) }
        }
        for gone in Set(threadStores.keys).subtracting(intakes.map(\.id)) {
            threadStores[gone] = nil
            threadWorkMemo[gone] = nil
        }
    }

    private func hasThreadWork(_ id: UUID) -> Bool {
        let threads = threadStore(id)
        let stamp = ThreadWorkStamp(
            threads: threads.fingerprint(),
            commands: TranscriptStamp(of: ThreadCommandStore(intakeDirectory: threads.intakeDirectory).commandsURL),
            cursor: TranscriptStamp(of: threads.cursorURL))
        if let memo = threadWorkMemo[id], memo.stamp == stamp { return memo.pending }
        let pending = threads.hasPendingWork()
        threadWorkMemo[id] = (stamp, pending)
        return pending
    }
}

/// What `hasThreadWork`'s answer is a function of: every thread file's stamp, the command log's
/// and the cursor's.
struct ThreadWorkStamp: Equatable {
    var threads: Int
    var commands: TranscriptStamp?
    var cursor: TranscriptStamp?
}

/// One entry of the thread header's agent menu.
struct ThreadAgentChoice: Equatable, Identifiable {
    let agent: AgentID
    let model: String
    let modelName: String
    let effort: String

    var id: String { "\(agent.rawValue)/\(model)" }

    /// Grok and OpenCode answer from the files alone (R1, and the OpenCode no-bash ruling): the
    /// header says so rather than let a thread seem able to run `git log` there.
    var readsFilesOnly: Bool { HeadlessCommand.threadReadsFilesOnly(agent) }
}

/// One intake's ask threads as the Mac UI holds them: what to read, and where each send goes —
/// `IntakeService`'s own API above, for this intake. Weak to the service, as the notes
/// controller's other closures are bound: the view state must not keep a service alive.
///
/// Each send unwraps the service first. `service?.op(…) ?? unavailable` would read as one
/// optional — the op's nil, which means accepted, and the service's absence alike — and turn
/// every accepted send into a refusal.

@MainActor
struct IntakeThreadBinding {
    let intakeID: UUID
    let reader: any ThreadStoreReading
    weak var service: IntakeService?

    func open(anchor: ThreadAnchor, title: String, text: String, agent: AgentID, model: String,
              effort: String) -> Result<ThreadID, ThreadRefusal> {
        guard let service else { return .failure(IntakeService.unavailable) }
        return service.openThread(intakeID, anchor: anchor, title: title, text: text, agent: agent, model: model,
                                  effort: effort)
    }

    func send(_ thread: ThreadID, text: String) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.sendThreadMessage(intakeID, thread: thread, text: text)
    }

    func answer(_ thread: ThreadID, answers: [StructuredAnswer]) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.answerThread(intakeID, thread: thread, answers: answers)
    }

    func setAutoAccept(_ thread: ThreadID, _ on: Bool) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.setThreadAutoAccept(intakeID, thread: thread, on)
    }

    func setAgent(_ thread: ThreadID, agent: AgentID, model: String, effort: String) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.setThreadAgent(intakeID, thread: thread, agent: agent, model: model, effort: effort)
    }

    func resolve(_ thread: ThreadID) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.resolveThread(intakeID, thread: thread)
    }

    func reopen(_ thread: ThreadID) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.reopenThread(intakeID, thread: thread)
    }

    func decideDiff(_ thread: ThreadID, diff: UUID, accept: Bool, editedMarkdown: String? = nil) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.decideDiff(intakeID, thread: thread, diff: diff, accept: accept, editedMarkdown: editedMarkdown)
    }

    /// What a new thread asks: the integrator's choice for this intake when it has a round config,
    /// else the first agent this machine can run, at that agent's detected model. The integrator is
    /// the seat that rewrites the plan, so it is the one whose answers the plan can take.
    func defaults() -> ThreadDefaults {
        guard let service else { return ThreadDefaults() }
        if let chosen = service.intake(intakeID)?.roundConfig?.integrator {
            return ThreadDefaults(agent: chosen.agent, model: chosen.model, effort: chosen.effort)
        }
        let available = service.availableModels()
        if let chosen = AgentID.allCases.compactMap({ available.choices[$0] }).first {
            return ThreadDefaults(agent: chosen.agent, model: chosen.model, effort: chosen.effort)
        }
        return ThreadDefaults()
    }

    /// Every agent and model the thread header's menu offers, as the Rounds editor's menus list them
    /// for this intake's project.
    func menu() -> [ThreadAgentChoice] {
        guard let service else { return [] }
        let available = service.availableModels(project: service.intake(intakeID)?.projectPath)
        return AgentID.allCases.flatMap { agent -> [ThreadAgentChoice] in
            guard let base = available.choices[agent] else { return [] }
            return available.menuOptions(for: agent).map {
                ThreadAgentChoice(agent: agent, model: $0.id, modelName: $0.name, effort: base.effort)
            }
        }
    }

    func repropose(_ thread: ThreadID, diff: UUID) -> ThreadRefusal? {
        guard let service else { return IntakeService.unavailable }
        return service.reproposeDiff(intakeID, thread: thread, diff: diff)
    }
}
