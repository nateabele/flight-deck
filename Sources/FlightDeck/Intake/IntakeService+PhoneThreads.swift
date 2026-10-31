import Foundation
import FleetKit
import IntakeKit

/// The phone's ask-thread ops (`intake.thread.*`, `intake.diff.decide`), as `FleetService`
/// dispatches them. Stream D owns this file.
///
/// `String?` like the sibling phone ops: nil is accepted, otherwise the `err` code. They are
/// token-idempotent through the same memory (`alreadyAccepted` / `accept` / `refuse`).
///
/// Each public op is a gate over an `apply…` twin that takes the reader: the gate keeps a Mac
/// whose ThreadRunner has not shipped refusing everything (`threadsAvailable`), and the twin
/// is what the tests drive with a fake store. Handlers only APPEND — the thread's commands to
/// `threads/commands.jsonl`, an accepted diff's `applyThreadDiff` to the tape's — so ThreadRunner
/// and IntakeRunner stay the single writers of their own state.
///
/// **New-thread id contract.** `phoneThreadSend` with `threadID: nil` opens thread
/// `ThreadID.opened(byToken: token)` — `ThreadID(raw: token)` — and its first message's
/// `messageID` is `ThreadCommand.firstMessageID(token:)`, `token.uuidString`. A retry after a
/// lost ack carries the same token, so it names the same thread and the same message, and
/// ThreadRunner (which dedupes on `messageID`, R9) opens no second thread and runs no second
/// turn. The phone's outbox can therefore show the new thread under that id before the Mac
/// answers.
extension IntakeService {
    func phoneThreadSend(_ id: UUID, token: UUID, threadID: UUID?, anchor: WireThreadAnchor?, text: String) -> String? {
        guard threadsAvailable else { return Self.threadsUnavailable }
        return applyPhoneThreadSend(id, token: token, threadID: threadID, anchor: anchor, text: text, reader: liveReader(id))
    }

    /// Answers to a turn's `askQuestion` actions; queues the thread's next turn.
    func phoneThreadAnswer(_ id: UUID, token: UUID, threadID: UUID, answers: [WireStructuredAnswer]) -> String? {
        guard threadsAvailable else { return Self.threadsUnavailable }
        return applyPhoneThreadAnswer(id, token: token, threadID: threadID, answers: answers, reader: liveReader(id))
    }

    func phoneThreadResolve(_ id: UUID, token: UUID, threadID: UUID) -> String? {
        guard threadsAvailable else { return Self.threadsUnavailable }
        return applyPhoneThreadResolve(id, token: token, threadID: threadID, reader: liveReader(id))
    }

    /// Refused with `diff_stale` when the diff could not be rebased.
    func phoneDiffDecide(_ id: UUID, token: UUID, threadID: UUID, diffID: UUID, accept: Bool) -> String? {
        guard threadsAvailable else { return Self.threadsUnavailable }
        return applyPhoneDiffDecide(id, token: token, threadID: threadID, diffID: diffID, accept: accept, reader: liveReader(id))
    }

    func phoneThreadGet(_ id: UUID, threadID: UUID, since: Int?) -> Result<WireThreadPage, ThreadRefusal> {
        guard threadsAvailable else { return .failure(Self.unavailable) }
        return applyPhoneThreadGet(id, threadID: threadID, since: since, reader: liveReader(id))
    }

    private func liveReader(_ id: UUID) -> any ThreadStoreReading { threadReader(id) ?? EmptyThreadStore() }

    // MARK: - send

    func applyPhoneThreadSend(_ id: UUID, token: UUID, threadID: UUID?, anchor: WireThreadAnchor?, text: String,
                              reader: any ThreadStoreReading) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return refuse("empty_message", id) }
        let commands = ThreadCommandStore(intakeDirectory: tapeStore(id).intakeDirectory)
        let queued = commands.commands(after: 0).map(\.command)
        let thread: ThreadID, messageID = ThreadCommand.firstMessageID(token: token)

        if let threadID {
            thread = ThreadID(raw: threadID)
            let opening = queued.contains { if case .open(thread, _, _, _, _, _) = $0 { true } else { false } }
            guard let record = reader.threads().first(where: { $0.id == thread }) else {
                // A thread the phone opened a moment ago exists only as a queued open.
                guard opening else { return refuse("unknown_thread", id) }
                return append(.message(thread, text: trimmed, messageID: token.uuidString, source: nil, elementID: nil,
                                       subjectRevision: nil), to: commands, token: token, intake: id, queued: queued)
            }
            guard record.status != .resolved else { return refuse("thread_resolved", id) }
            return append(.message(thread, text: trimmed, messageID: token.uuidString, source: nil, elementID: nil,
                                   subjectRevision: nil), to: commands, token: token, intake: id, queued: queued)
        }

        thread = ThreadID.opened(byToken: token)
        // The agent a phone-opened thread starts with: the integrator, the one that already
        // owns the plan's prose. The Mac's agent menu can change it afterwards.
        guard let agent = intake(id)?.roundConfig?.integrator else { return refuse("no_agent", id) }
        let threadAnchor: ThreadAnchor
        switch anchorForThread(anchor, intake: id) {
        case .success(let a): threadAnchor = a
        case .failure(let refusal): return refuse(refusal.code, id)
        }
        // A retry whose first append landed must add only what is missing.
        if !queued.contains(where: { if case .open(thread, _, _, _, _, _) = $0 { true } else { false } }) {
            do {
                try commands.append(.open(thread, threadAnchor, title: Self.threadTitle(trimmed), agent: agent.agent,
                                          model: agent.model, effort: agent.effort))
            } catch { return refuse("write_failed", id) }
        }
        return append(.message(thread, text: trimmed, messageID: messageID, source: nil, elementID: nil, subjectRevision: nil),
                      to: commands, token: token, intake: id, queued: queued)
    }

    /// Appends `message` unless the log already holds that `messageID` (a retry whose append
    /// landed but whose ack did not), then remembers the token.
    private func append(_ message: ThreadCommand, to store: ThreadCommandStore, token: UUID, intake id: UUID,
                        queued: [ThreadCommand]) -> String? {
        let landed = queued.contains { $0 == message }
            || queued.contains { if case .message(_, _, let m, _, _, _) = $0, case .message(_, _, let want, _, _, _) = message { m == want } else { false } }
        if !landed {
            do { try store.append(message) } catch { return refuse("write_failed", id) }
        }
        accept(token, for: id)
        return nil
    }

    static func threadTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }

    /// The thread's anchor from what the phone SHOWED, built from the markdown source the way
    /// `phoneNote` builds a note's, so a thread and a note on the same selection agree. Without a
    /// block the quote is taken as sent; without either, the thread is on the whole plan.
    private func anchorForThread(_ wire: WireThreadAnchor?, intake id: UUID) -> Result<ThreadAnchor, ThreadRefusal> {
        guard let wire, wire.checkpoint != nil || wire.block != nil || wire.quote != nil else { return .success(.wholePlan) }
        guard let checkpoint = wire.checkpoint else { return .failure(ThreadRefusal(code: "unknown_checkpoint")) }
        let load: (Int, String) -> Data? = { self.checkpointFile(id, checkpoint: $0, $1) }
        guard let markdown = PlanSection.effectivePlan(checkpoint: checkpoint, tape: storedTape(id), loadFile: load)
        else { return .failure(ThreadRefusal(code: "unknown_checkpoint")) }
        let phrase = wire.quote.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let block = wire.block {
            let blocks = PlanBlocks.split(markdown)
            guard let b = blocks.block(at: block) else { return .failure(ThreadRefusal(code: "unknown_block")) }
            let scope = Self.occurrence(of: b, in: blocks, markdown: markdown)
            let found = phrase.flatMap { RenderedQuoteLocator.range(of: $0, within: scope, of: markdown) }
            return .success(ThreadAnchor(note: NoteAnchor(checkpoint: checkpoint, selecting: found ?? scope, in: markdown)))
        }
        guard let phrase else { return .success(.wholePlan) }
        return .success(ThreadAnchor(note: NoteAnchor(checkpoint: checkpoint, quote: phrase, section: wire.section)))
    }

    // MARK: - resolve, answer

    func applyPhoneThreadResolve(_ id: UUID, token: UUID, threadID: UUID, reader: any ThreadStoreReading) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        let thread = ThreadID(raw: threadID)
        guard let record = reader.threads().first(where: { $0.id == thread }) else { return refuse("unknown_thread", id) }
        if record.status != .resolved {
            do { try ThreadCommandStore(intakeDirectory: tapeStore(id).intakeDirectory).append(.resolve(thread)) }
            catch { return refuse("write_failed", id) }
        }
        accept(token, for: id)
        return nil
    }

    func applyPhoneThreadAnswer(_ id: UUID, token: UUID, threadID: UUID, answers: [WireStructuredAnswer],
                                reader: any ThreadStoreReading) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        let thread = ThreadID(raw: threadID)
        guard reader.threads().contains(where: { $0.id == thread }) else { return refuse("unknown_thread", id) }
        // Only the newest turn's questions are open; an answer to anything older is to a
        // question the thread has already moved past.
        guard !IntakeThreadProjection.openQuestions(reader.turns(thread)).isEmpty else { return refuse("stale_questions", id) }
        let mapped = answers.map { StructuredAnswer(questionID: $0.questionID, selected: $0.selected, other: $0.other) }
        do {
            try ThreadCommandStore(intakeDirectory: tapeStore(id).intakeDirectory)
                .append(.answer(thread, mapped, messageID: token.uuidString))
        } catch { return refuse("write_failed", id) }
        accept(token, for: id)
        return nil
    }

    // MARK: - diffs

    /// ✓ appends the tape's `applyThreadDiff` FIRST and the thread's `decideDiff` second: if the
    /// second append fails the edit is there and the retry adds the decision, whereas the other
    /// order could leave a diff marked accepted that never changed the plan.
    func applyPhoneDiffDecide(_ id: UUID, token: UUID, threadID: UUID, diffID: UUID, accept doAccept: Bool,
                              reader: any ThreadStoreReading) -> String? {
        if alreadyAccepted(token, for: id) { return nil }
        if let refusal = notShaping(id) { return refusal }
        let thread = ThreadID(raw: threadID)
        guard reader.threads().contains(where: { $0.id == thread }) else { return refuse("unknown_thread", id) }
        guard let diff = reader.diffs(thread).first(where: { $0.id == diffID }) else { return refuse("unknown_diff", id) }
        let tape = tapeStore(id)
        // An edit already on the tape means an earlier ✓ got this far: the diff may have gone
        // stale BECAUSE the edit changed its passage, and the retry must still record the decision.
        let alreadyQueued = tape.commands(after: 0).contains {
            if case .applyThreadDiff(_, let queued, _, _) = $0.command { queued == diffID } else { false }
        }
        switch diff.state {
        case .stale:
            if !(doAccept && alreadyQueued) { return refuse("diff_stale", id) }
        case .accepted, .rejected:
            // The same decision twice is an ack (a second phone, or a retry under a new token).
            if (diff.state == .accepted) == doAccept {
                accept(token, for: id)
                return nil
            }
            return refuse("diff_decided", id)
        case .pending: break
        }

        if doAccept {
            if !alreadyQueued {
                let load: (Int, String) -> Data? = { self.checkpointFile(id, checkpoint: $0, $1) }
                guard let markdown = PlanSection.effectivePlan(checkpoint: diff.checkpoint, tape: storedTape(id), loadFile: load),
                      let edited = Self.applying(diff, to: markdown)
                else { return refuse("diff_stale", id) }
                do { try tape.appendCommand(.applyThreadDiff(thread: thread, diff: diffID, checkpoint: diff.checkpoint, markdown: edited)) }
                catch { return refuse("write_failed", id) }
            }
        }
        do { try ThreadCommandStore(intakeDirectory: tape.intakeDirectory).append(.decideDiff(thread, diff: diffID, accept: doAccept)) }
        catch { return refuse("write_failed", id) }
        accept(token, for: id)
        return nil
    }

    /// `markdown` with the diff's old passage replaced, or nil when the passage is gone or
    /// ambiguous. Exactly once, never a best guess (R6): an edit to the wrong place is worse
    /// than a stale diff the person can re-propose.
    static func applying(_ diff: ThreadDiff, to markdown: String) -> String? {
        guard !diff.old.isEmpty else { return nil }
        let parts = markdown.components(separatedBy: diff.old)
        guard parts.count == 2 else { return nil }
        return parts[0] + diff.new + parts[1]
    }

    // MARK: - get

    func applyPhoneThreadGet(_ id: UUID, threadID: UUID, since: Int?,
                             reader: any ThreadStoreReading) -> Result<WireThreadPage, ThreadRefusal> {
        guard intake(id) != nil else { return .failure(ThreadRefusal(code: "unknown_intake")) }
        let load: (Int, String) -> Data? = { self.checkpointFile(id, checkpoint: $0, $1) }
        let tape = storedTape(id)
        let markdown = PlanSection.planHead(tape: tape, loadFile: load)
            .flatMap { PlanSection.effectivePlan(checkpoint: $0, tape: tape, loadFile: load) } ?? ""
        guard let page = IntakeThreadProjection.page(reader: reader, thread: ThreadID(raw: threadID), since: since,
                                                     blocks: PlanBlocks.split(markdown))
        else { return .failure(ThreadRefusal(code: "unknown_thread")) }
        return .success(page)
    }
}
