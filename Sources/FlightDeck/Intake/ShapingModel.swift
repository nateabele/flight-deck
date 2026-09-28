import Foundation
import IntakeKit

/// A transport-bar button. `rewind` (⏮) is deliberately absent: it needs branching, which
/// this plan doesn't build (spec §6.4), and a dimmed button that can never light up is noise.
enum TransportButton: CaseIterable, Hashable {
    case step, nextMajor, toReview, pause, stop, extend, trim, annotate
}

/// One mark on the tape strip — a checkpoint already on the tape (`done`) or a round the
/// planner would run next. Positions are ordinal (`order`), not time: rounds take wildly
/// different wall-clock times and a time axis would crush the short ones into one tick.
struct StageMarker: Identifiable, Equatable {
    var order: Int
    var stage: Stage
    var round: Int
    var label: String
    var major: Bool
    var done: Bool
    /// The round the runner is executing right now (always the first pending marker).
    var inProgress: Bool
    var checkpointID: Int?
    var id: Int { order }
}

struct SlotBadge: Equatable {
    var label: String
    var status: SlotStatus
    /// Hover text for a substituted or failed seat; nil for one that ran as asked.
    var diagnosis: String?
    /// The model that actually ran ("codex gpt-6-sol"), for the round's detail panel.
    var model: String = ""
}

struct RoundCard: Identifiable, Equatable {
    var checkpointID: Int
    var title: String
    var changes: String?
    /// nil for a draft round: its drafts are written from nothing, so a "+N/−0" against
    /// nothing measures nothing.
    var lines: String?
    var tally: String?
    var slots: [SlotBadge]
    /// The record's note — reviewer summary, integrator notes, a fallback remark — shown
    /// expanded on the selected card and as the hover text on every card.
    var note: String?
    /// The sections the round touched, short: the first three and a count of the rest.
    var sections: String?
    /// The board's name for the round ("Refine 1") and its stage group ("REFINE") — the strip's
    /// cards and the detail panel say what the board says.
    var name: String = ""
    var stageTitle: String = ""
    /// `createdAt − startedAt`, by the board's rule (`BoardModel`'s finished slots): the gap since
    /// the previous checkpoint on a tape from before round timestamps, nil with neither.
    var duration: TimeInterval?
    /// Every section the round touched, `#` marks dropped — the panel has room for all of them.
    var allSections: [String] = []
    /// The human's notes the round consumed, as written.
    var notesApplied: [String] = []
    var id: Int { checkpointID }
}

/// Everything the shaping view shows, derived from an intake and its tape with no SwiftUI
/// in sight — so each rule (which buttons light up, what the status line promises, where the
/// diff base is) is pinned by `ShapingModelTests` rather than discovered by clicking.
struct ShapingModel {
    enum ViewerMode: Hashable, CaseIterable { case plan, diff, changeSet }

    let intake: Intake
    let tape: Tape
    let stages: [StageMarker]
    /// The next round the runner would start from the head — nil once the planned sequence is
    /// exhausted (release review) or when the intake has no round config to plan from.
    let nextRound: PlannedRound?

    init(intake: Intake, tape: Tape) {
        self.intake = intake
        self.tape = tape
        self.nextRound = intake.roundConfig.flatMap { TapePlanner.next(after: tape, config: $0) }
        self.stages = BoardModel.stages(tape: tape, config: intake.roundConfig)
    }

    /// Index into `stages` of the head checkpoint, or nil before the first round finishes.
    var playheadIndex: Int? { stages.lastIndex(where: \.done) }

    // MARK: - Transport

    var enabled: Set<TransportButton> {
        switch tape.status {
        case .running: [.pause, .stop, .annotate]
        case .paused, .idle, .stopped: [.step, .nextMajor, .toReview, .extend, .trim, .annotate]
        // ⏯ re-runs the round that failed; ⏭ is withheld because after a failure the human
        // should see one round succeed before committing to a whole stage again.
        case .failed: [.step, .toReview, .annotate]
        case .reachedReview: []
        }
    }

    /// Stages ＋ can lengthen — `BoardModel.extendableStages`, shared so the strip's + and the
    /// board's bracket handle can't disagree.
    var extendStages: [Stage] { BoardModel.extendableStages(tape: tape, config: intake.roundConfig) }

    /// Stages − can shorten — `BoardModel.trimmableStages`, shared with the bracket's − for the
    /// same reason.
    var trimStages: [Stage] { BoardModel.trimmableStages(tape: tape, config: intake.roundConfig) }

    // MARK: - Status line

    /// What the tape is doing and what each lit button would run — the spec's "a status line
    /// says what each button would run" (§8.3), so ⏭ never has to be clicked to find out how
    /// far it goes.
    var statusLine: String {
        switch tape.status {
        case .reachedReview:
            return "Reached release review"
        case .running:
            let current = tape.roundInProgress.map { Self.label(stage: $0.stage, round: $0.round) }
                ?? nextRound.map { Self.label(stage: $0.stage, round: $0.round) } ?? "round"
            return "Running \(current) · " + runningTarget(current: current)
        case .failed:
            let failed = tape.roundInProgress ?? nextRound
            let name = failed.map { Self.label(stage: $0.stage, round: $0.round) }
            var hints: [String] = []
            if let name { hints.append("⏯ retries \(name)") }
            hints.append("⏩ runs to review")
            return "\(name ?? "Round") failed — " + hints.joined(separator: " · ")
        case .idle, .paused, .stopped:
            var head: String
            if let h = tape.head {
                let at = Self.label(stage: h.stage, round: h.round)
                head = (tape.status == .stopped ? "Stopped at " : "Paused at ") + at
                if let changes = h.record.changeCount {
                    head += " · \(changes) change\(changes == 1 ? "" : "s")"
                    if let prior = previousInStage(h), let priorChanges = prior.record.changeCount {
                        head += " (\(Self.label(stage: prior.stage, round: prior.round)): \(priorChanges))"
                    }
                }
            } else {
                head = "Not started"
            }
            guard let next = nextRound else { return head + " — ⏩ opens release review" }
            let nextName = Self.label(stage: next.stage, round: next.round)
            return head + " — ⏯ runs \(nextName) · ⏭ runs \(nextMajorSpan(from: next)) · ⏩ runs to review"
        }
    }

    private func runningTarget(current: String) -> String {
        switch tape.target {
        case .review: return "runs to review"
        case .nextMinor: return "stops after \(current)"
        case .none: return "pausing after \(current)"
        case .nextMajor:
            guard let major = upcomingMajor(from: tape.roundInProgress ?? nextRound) else { return "stops at the next major checkpoint" }
            return "stops at \(Self.majorName(major))"
        }
    }

    /// "R3", "R2–R3 → plan final", "drafts": the rounds ⏭ would run, and the milestone it
    /// lands on when that has a name distinct from the round label.
    private func nextMajorSpan(from next: PlannedRound) -> String {
        let first = Self.label(stage: next.stage, round: next.round)
        guard let major = upcomingMajor(from: next) else { return first }
        let last = Self.label(stage: major.stage, round: major.round)
        var span = first == last ? first : "\(first)–\(last)"
        let milestone = Self.majorName(major)
        if milestone != last { span += " → \(milestone)" }
        return span
    }

    /// The first major round at or after `round` in the planned sequence.
    private func upcomingMajor(from round: PlannedRound?) -> PlannedRound? {
        guard let round else { return nil }
        let pending = stages.filter { !$0.done }
        guard let start = pending.firstIndex(where: { $0.stage == round.stage && $0.round == round.round }) else {
            return round.major ? round : nil
        }
        return pending[start...].first(where: \.major).map { PlannedRound(stage: $0.stage, round: $0.round, major: true) }
    }

    private func previousInStage(_ checkpoint: Checkpoint) -> Checkpoint? {
        guard let index = tape.checkpoints.firstIndex(of: checkpoint), index > 0 else { return nil }
        let prior = tape.checkpoints[index - 1]
        return prior.stage == checkpoint.stage ? prior : nil
    }

    // MARK: - Banner

    /// The runner's reason for stopping, and what to do about it. The title is the category
    /// in words plus the harness's own detail; the action is shown verbatim because
    /// `FailureDiagnosis` already phrases it as an instruction.
    var pauseBanner: (title: String, action: String)? {
        guard let d = tape.pauseDiagnosis else { return nil }
        let category = Self.categoryName(d.category)
        return (title: category.prefix(1).uppercased() + category.dropFirst() + ": " + d.detail, action: d.action)
    }

    // MARK: - Round cards

    var roundCards: [RoundCard] {
        tape.checkpoints.enumerated().map { index, cp in
            let r = cp.record
            let isDraft = cp.stage == .draft
            // A draft round has no change count; what it made is drafts, one per drafter that
            // produced one (a failed drafter's slot is still on the record).
            let drafts = r.slots.filter { $0.status != .failed }.count
            return RoundCard(
                checkpointID: cp.id,
                title: Self.label(stage: cp.stage, round: cp.round),
                changes: isDraft ? "\(drafts) draft\(drafts == 1 ? "" : "s")"
                    : r.changeCount.map { "\($0) change\($0 == 1 ? "" : "s")" },
                lines: isDraft ? nil : "+\(r.linesAdded)/−\(r.linesRemoved)",
                // The seat row's wording (`SeatRowModel.result`), so a round's card and the row
                // that produced it never describe the same verdicts two ways.
                tally: r.tally.map { "agreed \($0.agree) · somewhat \($0.somewhat) · declined \($0.disagree)" },
                slots: r.slots.map(Self.badge),
                note: r.note,
                sections: Self.sectionList(r.sectionsChanged),
                name: BoardModel.name(stage: cp.stage, round: cp.round),
                stageTitle: Self.stageTitle(cp.stage),
                duration: (cp.startedAt ?? (index > 0 ? tape.checkpoints[index - 1].createdAt : nil))
                    .map { max(0, cp.createdAt.timeIntervalSince($0)) },
                allSections: r.sectionsChanged.map(Self.heading),
                notesApplied: r.annotations.map(\.note))
        }
    }

    private static func heading(_ section: String) -> String {
        section.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    /// "Scope, Rollout, Risks +1": a card is a few lines wide, and the full list is one click
    /// away in the diff. Headings lose their `#` marks — the card already says it's a plan.
    private static func sectionList(_ sections: [String]) -> String? {
        guard !sections.isEmpty else { return nil }
        let names = sections.prefix(3).map(heading)
        let rest = sections.count - names.count
        return names.joined(separator: ", ") + (rest > 0 ? " +\(rest)" : "")
    }

    private static func badge(_ slot: SlotOutcome) -> SlotBadge {
        var label = slot.role
        if let persona = slot.persona, persona != .general { label += " · " + personaName(persona) }
        let reason = slot.diagnosis.map { " — \(categoryName($0.category)): \($0.detail). \($0.action)" } ?? ""
        let diagnosis: String? = switch slot.status {
        case .ok: nil
        case .substituted: "Ran \(modelName(slot.used)) instead of \(modelName(slot.requested))" + reason
        case .failed: "Failed" + reason
        }
        return SlotBadge(label: label, status: slot.status, diagnosis: diagnosis, model: modelName(slot.used))
    }

    // MARK: - Pill

    /// The `.shaping` pill's text, once `IntakeStatePill` is wired to the tape (Task 11).
    /// Lowercase to match the pill's other labels.
    static func pillLabel(for tape: Tape) -> String {
        let current = (tape.roundInProgress.map { label(stage: $0.stage, round: $0.round) })
            ?? tape.head.map { label(stage: $0.stage, round: $0.round) }
        switch tape.status {
        case .reachedReview: return "review ready"
        case .running: return current.map { "running · \($0)" } ?? "running"
        case .failed: return current.map { "failed · \($0)" } ?? "failed"
        case .stopped: return current.map { "stopped · \($0)" } ?? "stopped"
        case .paused, .idle:
            guard let head = tape.head else { return "shaping" }
            return "paused · \(label(stage: head.stage, round: head.round))"
        }
    }

    // MARK: - Plan viewer

    /// A checkpoint's plan: the integrated `plan.md` when the round produced one, else the
    /// lowest-numbered draft — the draft round writes only `drafts/<n>.md`, and showing
    /// nothing for the very first checkpoint would make the tape look empty until synthesis.
    /// Lowest-numbered, not `drafts/0.md`: a draft round writes only the drafters that
    /// succeeded, so with drafter 0 failed its file doesn't exist — and the first surviving
    /// draft is the one synthesis and Sketch's refine build on (`RoundExecutor.draftFiles`).
    /// The draft record has one slot per drafter, which bounds the search.
    static func planText(checkpoint: Int, in tape: Tape, loadFile: (Int, String) -> Data?) -> String? {
        if let plan = loadFile(checkpoint, "plan.md") { return String(decoding: plan, as: UTF8.self) }
        let drafters = tape.checkpoints.first { $0.id == checkpoint }?.record.slots.count ?? 0
        for i in 0..<max(drafters, 1) {
            if let draft = loadFile(checkpoint, "drafts/\(i).md") { return String(decoding: draft, as: UTF8.self) }
        }
        return nil
    }

    /// The nearest checkpoint before `checkpoint` (in tape order) that has a plan. Encode and
    /// polish checkpoints carry a change set instead, so "previous checkpoint" alone would
    /// diff a plan against nothing and show every line as added.
    static func previousPlanCheckpoint(before checkpoint: Int, in tape: Tape, loadFile: (Int, String) -> Data?) -> Int? {
        guard let index = tape.checkpoints.firstIndex(where: { $0.id == checkpoint }) else { return nil }
        return tape.checkpoints[..<index].reversed().first { planText(checkpoint: $0.id, in: tape, loadFile: loadFile) != nil }?.id
    }

    /// What the plan viewer's text depends on — and nothing else. The view memoizes its text
    /// on this key: without it, every body evaluation (a runner heartbeat, a card hover)
    /// re-read two files and re-ran `PlanMetrics.unifiedDiff`. `head` is in the key because a
    /// nil selection follows the head, and a new checkpoint landing must refresh the viewer.
    struct ViewerKey: Equatable {
        var checkpoint: Int?
        var mode: ViewerMode
        var head: Int?
    }

    static func viewerKey(selected: Int?, mode: ViewerMode, tape: Tape) -> ViewerKey {
        ViewerKey(checkpoint: selected ?? tape.head?.id, mode: mode, head: tape.head?.id)
    }

    static func viewerContent(_ key: ViewerKey, tape: Tape, loadFile: (Int, String) -> Data?) -> String {
        guard let checkpoint = key.checkpoint else { return "No rounds yet." }
        return viewerText(key.mode, checkpoint: checkpoint, tape: tape, loadFile: loadFile)
    }

    static func viewerText(_ mode: ViewerMode, checkpoint: Int, tape: Tape, loadFile: (Int, String) -> Data?) -> String {
        switch mode {
        case .plan:
            return planText(checkpoint: checkpoint, in: tape, loadFile: loadFile) ?? "No plan at this checkpoint."
        case .diff:
            guard let current = planText(checkpoint: checkpoint, in: tape, loadFile: loadFile) else { return "No plan at this checkpoint." }
            guard let base = previousPlanCheckpoint(before: checkpoint, in: tape, loadFile: loadFile),
                  let old = planText(checkpoint: base, in: tape, loadFile: loadFile) else { return "No earlier plan to compare with." }
            let diff = PlanMetrics.unifiedDiff(from: old, to: current)
            return diff.isEmpty ? "No changes since the previous plan." : diff
        case .changeSet:
            guard let data = loadFile(checkpoint, "changeset.json") else { return "No change set at this checkpoint." }
            guard let set = try? ChangeSet.decode(data) else { return "The change set at this checkpoint couldn't be read." }
            if set.ops.isEmpty { return "The change set is empty." }
            return set.ops.enumerated().map { "\($0.offset + 1). " + describe($0.element) }.joined(separator: "\n")
        }
    }

    static func describe(_ op: ChangeOp) -> String {
        switch op {
        case .createBead(let bead):
            return "New task new:\(bead.tempId) — \(bead.title)"
        case .addEdge(let from, let to, let kind):
            return "Edge \(from.wireValue) → \(to.wireValue) (\(kind.rawValue))"
        case .editBead(let id, let set, _, _):
            // Title and priority are short enough to show; description/acceptance are
            // paragraphs, so they're named only — the plan view has the full text.
            var fields: [String] = []
            if let title = set.title { fields.append("title: \(title)") }
            if set.description != nil { fields.append("description") }
            if set.acceptance != nil { fields.append("acceptance") }
            if let priority = set.priority { fields.append("priority: \(priority)") }
            return "Edit \(id) — " + fields.joined(separator: "; ")
        case .reopen(let id, let reason, _):
            return "Reopen \(id) — \(reason)"
        case .followUp(let tempId, let of, let title, _, _):
            return "Follow-up new:\(tempId) on \(of) — \(title)"
        }
    }

    // MARK: - Labels

    /// The short name a round goes by on the strip, the cards and the status line.
    static func label(stage: Stage, round: Int) -> String {
        switch stage {
        case .draft: "drafts"
        case .synthesis: "synthesis"
        case .refine: "R\(round)"
        case .encode: "encoded"
        case .polish: "P\(round)"
        case .freshEyes: "fresh eyes"
        case .dedup: "dedup"
        }
    }

    /// What reaching a major checkpoint means — the last refine round is where the plan is
    /// final, which "R3" alone doesn't say.
    static func majorName(_ round: PlannedRound) -> String {
        switch round.stage {
        case .refine: "plan final"
        case .polish: "polish done"
        default: label(stage: round.stage, round: round.round)
        }
    }

    static func stageTitle(_ stage: Stage) -> String {
        switch stage {
        case .draft: "DRAFT"
        case .synthesis: "SYNTH"
        case .refine: "REFINE"
        case .encode: "ENCODE"
        case .polish: "POLISH"
        case .freshEyes, .dedup: "FINAL"
        }
    }

    private static func categoryName(_ c: DiagnosisCategory) -> String {
        switch c {
        case .rateLimited: "rate limited"
        case .authExpired: "auth expired"
        case .timeout: "timed out"
        case .harnessError: "harness error"
        case .invalidOutput: "invalid output"
        }
    }

    private static func personaName(_ p: DrafterPersona) -> String {
        switch p {
        case .general: "general"
        case .arbiter: "arbiter"
        case .realist: "realist"
        case .coverage: "coverage"
        case .stressTest: "stress test"
        }
    }

    private static func modelName(_ m: ModelChoice) -> String { "\(m.harness.rawValue) \(m.model)" }
}
