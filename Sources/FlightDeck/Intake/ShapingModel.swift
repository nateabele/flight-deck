import Foundation
import IntakeKit

/// A transport-bar button. `rewind` (⏮) is deliberately absent: it needs branching, which
/// this plan doesn't build (spec §6.4), and a dimmed button that can never light up is noise.
enum TransportButton: CaseIterable, Hashable {
    case step, nextMajor, toReview, pause, stop, extend, annotate
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
}

struct RoundCard: Identifiable, Equatable {
    var checkpointID: Int
    var title: String
    var changes: String?
    var lines: String
    var tally: String?
    var slots: [SlotBadge]
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
        self.stages = Self.markers(tape: tape, config: intake.roundConfig)
    }

    /// Index into `stages` of the head checkpoint, or nil before the first round finishes.
    var playheadIndex: Int? { stages.lastIndex(where: \.done) }

    // MARK: - Transport

    var enabled: Set<TransportButton> {
        switch tape.status {
        case .running: [.pause, .stop, .annotate]
        case .paused, .idle, .stopped: [.step, .nextMajor, .toReview, .extend, .annotate]
        // ⏯ re-runs the round that failed; ⏭ is withheld because after a failure the human
        // should see one round succeed before committing to a whole stage again.
        case .failed: [.step, .toReview, .annotate]
        case .reachedReview: []
        }
    }

    /// Stages ＋ can lengthen: ones the config actually runs and the head hasn't moved past.
    /// `TapePlanner` silently ignores an extend for a finished stage, so offering it would be a
    /// menu item that does nothing.
    var extendStages: [Stage] {
        guard let config = intake.roundConfig else { return [] }
        let headRank = tape.head.map { Self.rank($0.stage) } ?? -1
        var stages: [Stage] = []
        if config.reviewer != nil, headRank <= Self.rank(.refine) { stages.append(.refine) }
        if config.polisher != nil, headRank <= Self.rank(.polish) { stages.append(.polish) }
        return stages
    }

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
        tape.checkpoints.map { cp in
            let r = cp.record
            return RoundCard(
                checkpointID: cp.id,
                title: Self.label(stage: cp.stage, round: cp.round),
                changes: r.changeCount.map { "\($0) change\($0 == 1 ? "" : "s")" },
                lines: "+\(r.linesAdded)/−\(r.linesRemoved)",
                tally: r.tally.map { "agree \($0.agree) / some \($0.somewhat) / no \($0.disagree)" },
                slots: r.slots.map(Self.badge))
        }
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
        return SlotBadge(label: label, status: slot.status, diagnosis: diagnosis)
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
    /// first draft — the draft round writes only `drafts/<n>.md`, and showing nothing for the
    /// very first checkpoint would make the tape look empty until synthesis.
    static func planText(checkpoint: Int, loadFile: (Int, String) -> Data?) -> String? {
        let data = loadFile(checkpoint, "plan.md") ?? loadFile(checkpoint, "drafts/0.md")
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    /// The nearest checkpoint before `checkpoint` (in tape order) that has a plan. Encode and
    /// polish checkpoints carry a change set instead, so "previous checkpoint" alone would
    /// diff a plan against nothing and show every line as added.
    static func previousPlanCheckpoint(before checkpoint: Int, in tape: Tape, loadFile: (Int, String) -> Data?) -> Int? {
        guard let index = tape.checkpoints.firstIndex(where: { $0.id == checkpoint }) else { return nil }
        return tape.checkpoints[..<index].reversed().first { planText(checkpoint: $0.id, loadFile: loadFile) != nil }?.id
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
            return planText(checkpoint: checkpoint, loadFile: loadFile) ?? "No plan at this checkpoint."
        case .diff:
            guard let current = planText(checkpoint: checkpoint, loadFile: loadFile) else { return "No plan at this checkpoint." }
            guard let base = previousPlanCheckpoint(before: checkpoint, in: tape, loadFile: loadFile),
                  let old = planText(checkpoint: base, loadFile: loadFile) else { return "No earlier plan to compare with." }
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
            return "New bead new:\(bead.tempId) — \(bead.title)"
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

    /// Stage order in the planned sequence — `Stage` is declared in that order but isn't
    /// `CaseIterable`, and IntakeKit is out of scope here.
    private static func rank(_ s: Stage) -> Int {
        [Stage.draft, .synthesis, .refine, .encode, .polish, .freshEyes, .dedup].firstIndex(of: s) ?? 0
    }

    // MARK: - Markers

    /// The tape's checkpoints, then whatever `TapePlanner` would run after them, found by
    /// replaying `next` on a scratch copy — the planner's sequence is private, and replaying it
    /// means the strip can never disagree with what the runner will actually do (extensions
    /// included).
    private static func markers(tape: Tape, config: RoundConfig?) -> [StageMarker] {
        var markers = tape.checkpoints.enumerated().map { i, cp in
            StageMarker(order: i, stage: cp.stage, round: cp.round, label: label(stage: cp.stage, round: cp.round),
                        major: cp.major, done: true, inProgress: false, checkpointID: cp.id)
        }
        guard let config else { return markers }
        var scratch = tape
        // Bounded so a planner bug can't hang the main thread; no real config comes close.
        while markers.count < 200, let next = TapePlanner.next(after: scratch, config: config) {
            markers.append(StageMarker(order: markers.count, stage: next.stage, round: next.round,
                                       label: label(stage: next.stage, round: next.round), major: next.major,
                                       done: false, inProgress: false, checkpointID: nil))
            scratch.checkpoints.append(Checkpoint(id: (scratch.head?.id ?? 0) + 1, stage: next.stage, round: next.round,
                                                  major: next.major, createdAt: Date(timeIntervalSince1970: 0)))
        }
        if tape.status == .running, let first = markers.firstIndex(where: { !$0.done }) {
            markers[first].inProgress = true
        }
        return markers
    }
}
