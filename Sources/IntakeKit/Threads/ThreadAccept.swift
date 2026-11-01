import Foundation

/// One ask thread's accepted diff inside a checkpoint's `plan.user.md`: what
/// `TapeStore.recordThreadEdit` records when IntakeRunner applies `applyThreadDiff`.
public struct ThreadEditSource: Codable, Equatable, Sendable {
    public var thread: ThreadID
    public var diff: UUID
    public init(thread: ThreadID, diff: UUID) {
        self.thread = thread
        self.diff = diff
    }
}

/// The human's ✓ on a thread's diff, from the Mac or the phone: the `applyThreadDiff` that puts
/// it in the plan.
///
/// `applyThreadDiff` carries the WHOLE plan and replaces `plan.user.md`, so it must be built on
/// the newest version there is: the last edit still queued for the head (a hand edit or an
/// earlier accept IntakeRunner hasn't folded yet), else the head's effective plan. Reading that
/// version, composing and appending are one critical section under the commands lock
/// (`TapeStore.appendCommand(composing:)`), so no edit can land in between and be overwritten —
/// the rule ThreadRunner's auto-accept follows too.
public enum ThreadAccept {
    /// N1: the note a thread gets when the human's typing took one of its accepts back.
    public static let typingWonNote = "Your typing changed the same line before this edit landed; check the proposal again."
    public enum Outcome: Equatable, Sendable {
        /// The edit is on the tape.
        case appended
        /// An earlier accept of this diff is already on the tape (a retry): nothing appended.
        case already
        /// The diff doesn't apply to the newest version: its passage is gone or ambiguous there,
        /// or an edited accept names an older checkpoint. Nothing appended; re-propose it.
        case stale
    }

    /// Appends `applyThreadDiff` for `diff`. `editedMarkdown` is the plan the human changed the
    /// proposal into (Edit, then Accept edited): it is taken as it is, as an accept, when the
    /// diff is on the head (the plan the editor shows). Without it the diff's own replacement is
    /// applied to the newest version, exactly once, never as a best guess (R6) — so a diff from
    /// before a round landed applies when the round left its passage alone (ThreadRunner's
    /// rebase does the same first, but only on the thread's next turn), and is stale otherwise.
    public static func append(_ diff: ThreadDiff, editedMarkdown: String?, to tapeStore: TapeStore) throws -> Outcome {
        var outcome = Outcome.stale
        let threads = ThreadStore(intakeDirectory: tapeStore.intakeDirectory)
        let diff = threads.diff(diff.thread, diff.id) ?? diff
        var lost: [ThreadDiff] = []
        try tapeStore.appendCommand(composing: { commands in
            if queuedSeq(of: diff, in: commands) != nil {
                outcome = .already
                return nil
            }
            let tape = tapeStore.loadTape()
            guard let head = tapeStore.headPlanCheckpoint(in: tape),
                  let effective = tapeStore.effectivePlan(checkpoint: head) else { return nil }
            var markdown: String
            if let editedMarkdown {
                guard diff.checkpoint == head else { return nil }
                markdown = editedMarkdown
                // N2: the editor's text may predate accepts still queued. Each one is put back
                // into it; one whose own line the text changed can't be, and follows N1's rule:
                // the human's text wins and that accept is taken back to pending.
                for queued in queuedAccepts(on: head, in: commands, after: tape.ackedCommandSeq, threads: threads)
                where queued.id != diff.id && !markdown.contains(queued.new) {
                    if let composed = ActionValidator.apply(old: queued.old, anchor: queued.anchor, new: queued.new, to: markdown) {
                        markdown = composed
                    } else {
                        lost.append(queued)
                    }
                }
            } else {
                let latest = commands.filter { $0.seq > tape.ackedCommandSeq }
                    .compactMap { edit($0.command, for: head) }.last ?? effective
                guard let applied = ActionValidator.apply(old: diff.old, anchor: diff.anchor, new: diff.new, to: latest)
                else { return nil }
                markdown = applied
            }
            outcome = .appended
            return .applyThreadDiff(thread: diff.thread, diff: diff.id, checkpoint: head, markdown: markdown)
        })
        if let head = lost.first?.checkpoint ?? Optional(diff.checkpoint), !lost.isEmpty {
            try takeBack(lost, checkpoint: head, tapeStore: tapeStore)
        }
        return outcome
    }

    /// The tape seq of `diff`'s accept still counting: an `applyThreadDiff` for it after any
    /// point the human's typing took it back (`ThreadDiff.reopenedAfter`, N1). Nil when none.
    public static func queuedSeq(of diff: ThreadDiff, in commands: [CommandEnvelope]) -> Int? {
        commands.last { envelope in
            guard case .applyThreadDiff(_, diff.id, _, _) = envelope.command else { return false }
            return envelope.seq > (diff.reopenedAfter ?? 0)
        }?.seq
    }

    /// The diffs whose accepts are queued for `checkpoint` and not folded yet, still counting.
    static func queuedAccepts(on checkpoint: Int, in commands: [CommandEnvelope], after acked: Int,
                              threads: ThreadStore) -> [ThreadDiff] {
        commands.filter { $0.seq > acked }.compactMap { envelope -> ThreadDiff? in
            guard case .applyThreadDiff(let thread, let id, checkpoint, _) = envelope.command,
                  let d = threads.diff(thread, id), envelope.seq > (d.reopenedAfter ?? 0) else { return nil }
            return d
        }
    }

    /// N1: the human's typing in `plan` replaced the change of accepts not yet folded, or folded
    /// into `checkpoint`'s layer: those whose new text the plan no longer holds. Each is taken
    /// back (`takeBack`). Call it after the typing's `editPlan` is on the tape.
    public static func takeBackLost(in plan: String, checkpoint: Int, tapeStore: TapeStore) throws {
        let threads = ThreadStore(intakeDirectory: tapeStore.intakeDirectory)
        let commands = tapeStore.commands(after: 0)
        var candidates = queuedAccepts(on: checkpoint, in: commands, after: tapeStore.loadTape().ackedCommandSeq, threads: threads)
        for source in tapeStore.threadEditSources(checkpoint: checkpoint) where !candidates.contains(where: { $0.id == source.diff }) {
            if let d = threads.diff(source.thread, source.diff) { candidates.append(d) }
        }
        let lost = candidates.filter { !$0.new.isEmpty && !plan.contains($0.new) && $0.state != .rejected }
        if !lost.isEmpty { try takeBack(lost, checkpoint: checkpoint, tapeStore: tapeStore) }
    }

    /// Takes `diffs`' accepts back: the tape drops their sources (`withdrawThreadEdit`), and each
    /// thread is told — the diff pending again, with `typingWonNote` — so the panel, the plan's
    /// proposal bar and the decision log all agree that it is not accepted.
    static func takeBack(_ diffs: [ThreadDiff], checkpoint: Int, tapeStore: TapeStore) throws {
        let log = ThreadCommandStore(intakeDirectory: tapeStore.intakeDirectory)
        for d in diffs {
            let seq = try tapeStore.appendCommand(.withdrawThreadEdit(thread: d.thread, diff: d.id, checkpoint: checkpoint))
            try log.append(.reopenDiff(d.thread, diff: d.id, afterSeq: seq, note: typingWonNote))
        }
    }

    /// The whole plan a queued command sets for `checkpoint`, if it is an edit of it.
    static func edit(_ command: TapeCommand, for checkpoint: Int) -> String? {
        switch command {
        case .editPlan(checkpoint, let markdown), .applyThreadDiff(_, _, checkpoint, let markdown): markdown
        default: nil
        }
    }
}
