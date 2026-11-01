import Foundation
import IntakeKit

/// Where a committed plan edit goes (spec §7.2; Task 10's open end). An edit is sent for the
/// checkpoint it was typed on — unless a newer head has landed since. Then the edit, kept
/// there, would feed no round, so it is merged onto the head by the runner's own rule
/// (`EditLayer.retarget`) and sent for the head; a conflict keeps it where it was typed and
/// raises the banner.
///
/// Merges run one after another (each onto the head as the one before it left it), and every
/// step reads the tape as it is NOW (`Env.tape`, into the service) rather than as it was when
/// the edit was committed: a round can land while a merge waits its turn or while `git` runs.
/// After the wait and again after `git`, a head that moved — or a head plan that changed under
/// the merge — means merging again, against what is there now, up to `maxMerges` times; a head
/// that keeps moving leaves the edit on its own round, with the banner, rather than chasing it.
///
/// A clean merge's text is offered to the editor (`Env.deliver`) as a new text for the head,
/// never swapped in: the editor's own rule then shows it at once or holds it behind the banner
/// while the human is typing. Typing on the head before taking it is merged onto it in turn
/// (`carried`), so neither the typing nor the carried edit is lost when it is committed.
@MainActor
final class PlanEditRouter {
    struct Env {
        /// The intake's tape as the service has it now.
        var tape: () -> Tape = { .empty }
        var loadFile: (Int, String) -> Data? = { _, _ in nil }
        var send: (TapeCommand) -> Void = { _ in }
        var onConflict: (EditConflict) -> Void = { _ in }
        /// A merged plan for `checkpoint`, to be offered to the editor.
        var deliver: (_ checkpoint: Int, _ plan: String) -> Void = { _, _ in }
        var runner: CommandRunner = SystemCommandRunner()
        /// The newest plan queued for a checkpoint that IntakeRunner hasn't folded yet — a hand
        /// edit or a thread's accepted diff, whoever sent it (`IntakeService.queuedPlan`). Nil
        /// (renders, tests) falls back to this router's own `sent`.
        var queued: ((Int) -> String?)?
    }

    var env = Env()
    static let maxMerges = 3

    /// The last text sent for each checkpoint: what a reload shows until the runner has
    /// applied it, and "ours" for a merge onto that checkpoint.
    private(set) var sent: [Int: String] = [:]
    /// Checkpoints whose edit could not be carried onto a newer head: later commits of the
    /// same edit stay with it, rather than merging a remainder onto the head without the part
    /// that conflicted.
    private(set) var stuck: Set<Int> = []
    /// What a merge wrote onto a head the editor hasn't taken yet: the plan it wrote, and the
    /// edit it carried there (from which checkpoint, as typed).
    private var carried: [Int: (plan: String, from: Int, markdown: String)] = [:]
    /// The last commit typed on each checkpoint, and the text its editor had loaded: what the
    /// next commit from the same load is relative to. A head plan that moved away from it since —
    /// a thread's accept from anywhere, folded or still queued — is merged under the typing
    /// rather than overwritten by it (A-I3, B-C1).
    private var typed: [Int: (loaded: String, markdown: String)] = [:]
    private var chain: Task<Void, Never>?
    private var queued = 0

    nonisolated init() {}

    /// Routes an edit committed on `checkpoint`, whose editor loaded `loaded`. Sent at once
    /// when there is nothing to merge and nothing queued — a Step pressed right after typing
    /// must find the edit already sent — and otherwise queued behind the merges before it.
    func commit(_ markdown: String, typedOn checkpoint: Int, loaded: String, editable: Bool) {
        if chain == nil, !needsMerge(checkpoint, loaded: loaded, editable: editable, tape: env.tape()) {
            // The editor took the merge it was offered: its commits are plain again.
            if carried[checkpoint]?.plan == loaded { carried[checkpoint] = nil }
            if editable, isRefused(checkpoint, tape: env.tape()) { stuck.insert(checkpoint) }
            typed[checkpoint] = (loaded, markdown)
            return direct(checkpoint, markdown)
        }
        let previous = chain
        queued += 1
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await self?.route(markdown, typedOn: checkpoint, loaded: loaded, editable: editable)
            guard let self else { return }
            self.queued -= 1
            if self.queued == 0 { self.chain = nil }
        }
    }

    /// Waits for every queued merge — for tests.
    func settle() async {
        while let chain { await chain.value }
    }

    /// The head's round already failed to carry `checkpoint`'s edits (`RoundRecord.editConflict`).
    private func isRefused(_ checkpoint: Int, tape: Tape) -> Bool {
        guard let head = PlanSection.planHead(tape: tape, loadFile: env.loadFile), head != checkpoint else { return false }
        return tape.checkpoints.first { $0.id == head }?.record.editConflict == checkpoint
    }

    /// The head's plan as it stands: the newest edit queued for it (whoever queued it), else
    /// the plan on disk. Without the service's queue, this router's own last send stands in.
    private func headPlan(_ head: Int, tape: Tape) -> String? {
        let disk = { PlanSection.effectivePlan(checkpoint: head, tape: tape, loadFile: self.env.loadFile) }
        if let queued = env.queued { return queued(head) ?? disk() }
        return sent[head] ?? disk()
    }

    /// What a commit typed on `checkpoint` from `loaded` is relative to: the last commit from the
    /// same load (the editor's text is cumulative), else the load itself.
    private func typedBase(_ checkpoint: Int, loaded: String) -> String {
        typed[checkpoint].flatMap { $0.loaded == loaded ? $0.markdown : nil } ?? loaded
    }

    private func needsMerge(_ checkpoint: Int, loaded: String, editable: Bool, tape: Tape) -> Bool {
        guard editable, !stuck.contains(checkpoint), let head = PlanSection.planHead(tape: tape, loadFile: env.loadFile) else { return false }
        if head == checkpoint {
            if let carried = carried[checkpoint], carried.plan != loaded { return true }
            // Something other than this typing changed the head since its last commit — a thread's
            // accept, from this Mac, the phone or auto-accept: the typing goes on top of it.
            // Compared unwrapped: the runner stores an edit unwrapped (`TapeStore.writeUserEdits`),
            // and that alone is no one else's change.
            return headPlan(head, tape: tape).map {
                MarkdownUnwrap.unwrap($0) != MarkdownUnwrap.unwrap(typedBase(checkpoint, loaded: loaded))
            } ?? false
        }
        // The runner already failed to carry this checkpoint's edits into the head; merging
        // more of them onto it would land the rest without the part that conflicted.
        return !isRefused(checkpoint, tape: tape)
    }

    private func route(_ markdown: String, typedOn checkpoint: Int, loaded: String, editable: Bool) async {
        var merges = 0
        while true {
            let tape = env.tape()
            guard needsMerge(checkpoint, loaded: loaded, editable: editable, tape: tape),
                  let head = PlanSection.planHead(tape: tape, loadFile: env.loadFile) else {
                if editable, isRefused(checkpoint, tape: tape) { stuck.insert(checkpoint) }
                if carried[checkpoint]?.plan == loaded { carried[checkpoint] = nil }
                typed[checkpoint] = (loaded, markdown)
                return direct(checkpoint, markdown)
            }
            // Onto the head: its plan now. Typed on the head itself, over a merge it hadn't
            // taken: the edit's base is what the editor loaded. Typed on an older checkpoint:
            // the checkpoint's text before the head moved — commits since went to the head, so
            // that is still the last one sent for it (or the load).
            guard let ours = headPlan(head, tape: tape) else { return }
            let base = head == checkpoint ? typedBase(checkpoint, loaded: loaded) : sent[checkpoint] ?? loaded
            var outcome = await EditLayer.retarget(markdown: markdown, typedOn: checkpoint, base: base, head: head,
                                                   headPlan: ours, runner: env.runner)
            // Typing on the head next to a passage an accept changed is a conflict to `git` (the
            // hunks touch) but not to the human: the accept's lines are put onto the typing as they are.
            if outcome.conflict != nil, head == checkpoint, carried[head] == nil,
               let replayed = PlanRebase.replay(base: base, ours: ours, onto: markdown) {
                outcome = PlanRebase.Retarget(command: .editPlan(checkpoint: head, markdown: replayed), conflict: nil)
            }
            merges += 1

            let now = env.tape()
            let nowHead = PlanSection.planHead(tape: now, loadFile: env.loadFile)
            let nowOurs = nowHead.flatMap { headPlan($0, tape: now) }
            typed[checkpoint] = (loaded, markdown)
            if stuck.contains(checkpoint) { return direct(checkpoint, markdown) }
            if nowHead != head || nowOurs != ours {
                if merges < Self.maxMerges { continue }
                // A head that keeps moving: the edit stays on its round, and says so.
                stuck.insert(checkpoint)
                direct(checkpoint, markdown)
                return env.onConflict(EditConflict(edits: checkpoint, landedIn: nowHead ?? head))
            }

            switch (outcome.conflict, head == checkpoint) {
            case (nil, _):
                guard case .editPlan(_, let plan) = outcome.command else { return }
                sent[head] = plan
                env.send(.editPlan(checkpoint: head, markdown: plan))
                if head != checkpoint {
                    carried[head] = (plan, checkpoint, markdown)
                } else if let carry = carried[head] {
                    carried[head] = (plan, carry.from, carry.markdown)
                }
                // Typing on the head merged over an accept carries nothing from another round:
                // `typed` alone brings the next commit from this load back here.
                env.deliver(head, plan)
            case (let conflict?, false):
                stuck.insert(checkpoint)
                direct(checkpoint, markdown)
                env.onConflict(conflict)
            case (_, true):
                // Typing on the head conflicts with what a merge carried onto it: the typing is
                // the human's latest word and stays; the carried edit goes back to its round,
                // with the banner, as a conflict at the merge would have left it.
                let lost = carried.removeValue(forKey: head)
                direct(head, markdown)
                if let lost {
                    stuck.insert(lost.from)
                    direct(lost.from, lost.markdown)
                    env.onConflict(EditConflict(edits: lost.from, landedIn: head))
                }
            }
            return
        }
    }

    private func direct(_ checkpoint: Int, _ markdown: String) {
        sent[checkpoint] = markdown
        env.send(.editPlan(checkpoint: checkpoint, markdown: markdown))
    }
}
