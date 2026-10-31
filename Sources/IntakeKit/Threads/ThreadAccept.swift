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
    public enum Outcome: Equatable, Sendable {
        /// The edit is on the tape.
        case appended
        /// An earlier accept of this diff is already on the tape (a retry): nothing appended.
        case already
        /// The diff doesn't apply to the newest version: it was proposed on an older checkpoint,
        /// or its passage is gone or ambiguous. Nothing appended; re-propose it.
        case stale
    }

    /// Appends `applyThreadDiff` for `diff`. `editedMarkdown` is the plan the human changed the
    /// proposal into (Edit, then Accept edited): it is taken as it is, as an accept. Without it
    /// the diff's own replacement is applied, exactly once, never as a best guess (R6).
    public static func append(_ diff: ThreadDiff, editedMarkdown: String?, to tapeStore: TapeStore) throws -> Outcome {
        var outcome = Outcome.stale
        try tapeStore.appendCommand(composing: { commands in
            if commands.contains(where: { if case .applyThreadDiff(_, diff.id, _, _) = $0.command { true } else { false } }) {
                outcome = .already
                return nil
            }
            let tape = tapeStore.loadTape()
            guard let head = tapeStore.headPlanCheckpoint(in: tape), diff.checkpoint == head,
                  let effective = tapeStore.effectivePlan(checkpoint: head) else { return nil }
            let markdown: String
            if let editedMarkdown {
                markdown = editedMarkdown
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
        return outcome
    }

    /// The whole plan a queued command sets for `checkpoint`, if it is an edit of it.
    static func edit(_ command: TapeCommand, for checkpoint: Int) -> String? {
        switch command {
        case .editPlan(checkpoint, let markdown), .applyThreadDiff(_, _, checkpoint, let markdown): markdown
        default: nil
        }
    }
}
