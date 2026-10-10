import FleetKit
import Foundation
import IntakeKit

/// One seat's live status row (spec §6): everything the departures board's seat list shows,
/// folded from what the engine already writes (`SeatActivity`, `run.json`) plus the round's own
/// config and — once it lands — its checkpoint. Pure and `Equatable` so the view's diffing and
/// this file's tests never have to touch a file or a clock of their own.
struct SeatRowModel: Equatable, Identifiable {
    enum Glyph: Equatable {
        case queued, running, done, failed, fallback, needsYou
    }

    /// The only colour in a seat row (spec §2 "colour only for exceptions"). `needsYou` has no
    /// case here on purpose: none of `SeatActivity`/`RunRecord`/`SlotOutcome` carries a signal
    /// that a SEAT itself is waiting on the human — only a whole intake pauses for that — so
    /// `Glyph.needsYou` is reserved for a future per-seat signal and `make` never produces it.
    enum Exception: Equatable {
        case quiet(TimeInterval)
        case stalled(TimeInterval, last: String?)
        case rateLimited(TimeInterval)
        case fallback(String)
        case failed(String)
    }

    let id: String
    var glyph: Glyph
    var role: String
    var identity: String
    var headline: String?
    var action: String?
    var footprint: [(dir: String, count: Int)]
    /// The same mapping as `footprint` (`.` → `root`, FD's own scratch dirs dropped) but never
    /// collapsed to a top-4-plus-`+N` chip row — the expand interaction (spec §6, a chip row
    /// "expands to the file list") shows exactly this: the directories and their counts, sorted
    /// by count descending. The engine's `SeatActivity.footprint` only ever counts files per
    /// directory, never lists their names, so this is the file-level detail there is to show —
    /// `make` never invents file names to go further than that.
    var footprintAll: [(dir: String, count: Int)]
    var steps: String?
    var contextFraction: Double?
    /// The two numbers behind `contextFraction`, for a gauge that says "118k of 400k" rather
    /// than a percentage. `contextWindow` is nil whenever `contextFraction` is.
    var inputTokens: Int?
    var contextWindow: Int?
    var elapsed: TimeInterval
    var exception: Exception?
    var result: String?
    var cost: Double?

    static func == (lhs: SeatRowModel, rhs: SeatRowModel) -> Bool {
        lhs.id == rhs.id && lhs.glyph == rhs.glyph && lhs.role == rhs.role && lhs.identity == rhs.identity
            && lhs.headline == rhs.headline && lhs.action == rhs.action
            && lhs.footprint.elementsEqual(rhs.footprint) { $0.dir == $1.dir && $0.count == $1.count }
            && lhs.footprintAll.elementsEqual(rhs.footprintAll) { $0.dir == $1.dir && $0.count == $1.count }
            && lhs.steps == rhs.steps && lhs.contextFraction == rhs.contextFraction
            && lhs.inputTokens == rhs.inputTokens && lhs.contextWindow == rhs.contextWindow && lhs.elapsed == rhs.elapsed
            && lhs.exception == rhs.exception && lhs.result == rhs.result && lhs.cost == rhs.cost
    }

    /// - Parameters:
    ///   - run: the `runs/<run>` directory name (or `"triage"`) — used verbatim as `id`, and, when
    ///     no `SlotOutcome` exists yet, as the only place a still-running seat's role is written
    ///     down (see `roleFromRun`).
    ///   - slot: this seat's outcome from the checkpoint the round already produced — nil until
    ///     the round finishes.
    ///   - requested: the round config's seat for this slot (what it was ASKED to run) — nil for
    ///     triage, which has no `RoundConfig.Slot`.
    ///   - activity: this run's live `SeatActivity`, nil before the harness has emitted anything.
    ///   - record: this run's `run.json` — carries the process exit even when `activity.finished`
    ///     never got set (the stream ended mid-line; spec §6 "a row whose activity.json says
    ///     unfinished while its run.json shows an exit is treated as finished").
    ///   - seatResult: this run's own `runs/<run>/result.json`, written the moment the seat's output
    ///     parsed — preferred over `roundRecord`, which only exists once the WHOLE round lands.
    ///   - roundRecord: the checkpoint's `RoundRecord`, once the WHOLE round (not just this seat)
    ///     has landed — the source `result` reads from. This parameter is not in the brief's
    ///     sketch: `result` needs `changeCount`/`tally`/`sectionsChanged`, which live on
    ///     `RoundRecord`, not on `SlotOutcome` or the brief's `record: RunRecord?` (that type is
    ///     just the process's pid/exit code). See the task report for this deviation.
    static func make(run: String, slot: SlotOutcome?, requested: Slot?, activity: SeatActivity?, record: RunRecord?,
                      roundRecord: RoundRecord?, seatResult: SeatResult? = nil, now: Date, thresholds: SeatThresholds = .default) -> SeatRowModel {
        let activityAgent = activity?.agent
        // A slot with a checkpoint is settled regardless of what its own stream/process say —
        // `slot != nil` means a `RoundRecord` already landed for it.
        let processFinished = activity?.finished == true || record?.exitCode != nil || record?.finished != nil
            || slot != nil
        let failure = failureReason(activity: activity, slot: slot, record: record)
        let fallback = isFallback(slot: slot, requested: requested, activityAgent: activityAgent)

        let glyph: Glyph
        if activity == nil {
            glyph = .queued
        } else if processFinished {
            glyph = failure != nil ? .failed : .done
        } else {
            glyph = fallback ? .fallback : .running
        }

        let rawRole = slot?.role ?? roleFromRun(run) ?? "triage"
        let persona = slot?.persona ?? requested?.persona
        // `rawRole` stays the engine's own token (`result(rawRole:roundRecord:)` switches on it
        // below) — only the DISPLAYED role routes through `UIText.roleName`, so "crossReviewer"
        // reads "cross-check agent" on every row without touching the logic keyed to the raw name.
        let role = (persona != nil && persona != .general) ? personaName(persona!) : UIText.roleName(rawRole)

        let action = activity?.action.map(actionText)
        let headline = activity?.headline ?? action

        let exception: Exception?
        if let failure, processFinished {
            exception = .failed(failure)
        } else if !processFinished, let activity {
            exception = runningException(activity: activity, now: now, thresholds: thresholds,
                                          fallback: fallback, requested: requested, activityAgent: activityAgent,
                                          currentAction: action)
        } else {
            exception = nil
        }

        let allDirs = footprintAll(activity?.footprint ?? [:])
        let model = currentChoice(slot: slot, requested: requested, activityAgent: activityAgent)?.model
        return SeatRowModel(
            id: run,
            glyph: glyph,
            role: role,
            identity: identity(slot: slot, requested: requested, activityAgent: activityAgent),
            headline: headline,
            action: action,
            footprint: footprintChips(allDirs),
            footprintAll: allDirs,
            steps: activity?.steps.map(stepsText),
            contextFraction: contextFraction(inputTokens: activity?.inputTokens, model: model),
            inputTokens: activity?.inputTokens,
            contextWindow: activity?.inputTokens == nil ? nil : contextWindow(for: model),
            elapsed: elapsed(activity: activity, record: record, now: now),
            exception: exception,
            result: processFinished
                ? (seatResult.flatMap(result) ?? result(rawRole: rawRole, roundRecord: roundRecord)) : nil,
            cost: processFinished ? activity?.costUSD : nil)
    }

    // MARK: - Role

    /// The run's own directory name encodes stage, round and role
    /// (`RoundExecutor.runName`: `<stage>-<round>-<role>[-<index>][-fallback][-correction]`) —
    /// the only place a still-running seat's role lives before any `SlotOutcome` exists. Triage
    /// writes no such name (its activity is `triage/activity.json`, not `runs/<run>/…`), so it
    /// falls through every guard here and `make` defaults it to `"triage"`.
    private static func roleFromRun(_ run: String) -> String? {
        let parts = run.split(separator: "-").map(String.init)
        guard parts.count >= 3, Stage(rawValue: parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        return parts.dropFirst(2).first { Int($0) == nil && $0 != "fallback" && $0 != "correction" }
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

    // MARK: - Identity

    /// Which triple is actually running: the finished outcome's `used` choice once there is one,
    /// else the round config's fallback choice IF this run's harness has already diverged from
    /// what was requested (the fallback fired), else the requested choice itself. There is no
    /// live signal that names the model mid-run other than the config — `SeatActivity` carries a
    /// harness, never a model — so this is the best a still-running seat can say.
    private static func currentChoice(slot: SlotOutcome?, requested: Slot?, activityAgent: AgentID?) -> ModelChoice? {
        if let slot { return slot.used }
        guard let requested else { return nil }
        if let activityAgent, activityAgent != requested.choice.agent, let fallback = requested.fallback {
            return fallback
        }
        return requested.choice
    }

    private static func isFallback(slot: SlotOutcome?, requested: Slot?, activityAgent: AgentID?) -> Bool {
        // `used != requested` covers BOTH outcomes of a fallback attempt: `.substituted` (the
        // fallback succeeded) and `.failed` with `used` already the fallback choice (the
        // fallback attempt failed too) — status alone would miss the second one.
        if let slot { return slot.used.agent != slot.requested.agent }
        guard let requested, let activityAgent else { return false }
        return activityAgent != requested.choice.agent
    }

    /// "codex · gpt-6-sol · high", or after a fallback "claude → codex · gpt-6-sol" (spec §6) —
    /// the model, not the effort, on the far side of the arrow: the fallback line is about which
    /// harness took over, and the effort the harness that failed asked for says nothing about it.
    private static func identity(slot: SlotOutcome?, requested: Slot?, activityAgent: AgentID?) -> String {
        guard let choice = currentChoice(slot: slot, requested: requested, activityAgent: activityAgent) else {
            return activityAgent?.rawValue ?? "…"
        }
        guard isFallback(slot: slot, requested: requested, activityAgent: activityAgent),
              let from = slot?.requested.agent ?? requested?.choice.agent else {
            return "\(choice.agent.rawValue) · \(choice.model) · \(choice.effort)"
        }
        return "\(from.rawValue) → \(choice.agent.rawValue) · \(choice.model)"
    }

    /// "fell back to codex" — and, only when the engine actually recorded why (today that's
    /// only the failed-even-after-falling-back case; a successful fallback's `SlotOutcome`
    /// carries no diagnosis), "fell back to codex · <detail>". Never invents a reason the data
    /// doesn't have (spec §2 "honest data only") — the brief's illustrative "claude 401" assumes
    /// a reason the current engine doesn't record for a live or successful fallback.
    private static func fallbackReason(slot: SlotOutcome?, requested: Slot?, activityAgent: AgentID?) -> String? {
        guard isFallback(slot: slot, requested: requested, activityAgent: activityAgent) else { return nil }
        let to = currentChoice(slot: slot, requested: requested, activityAgent: activityAgent)?.agent.rawValue
            ?? activityAgent?.rawValue ?? "the fallback model"
        var text = "fell back to \(to)"
        if let detail = slot?.diagnosis?.detail, !detail.isEmpty { text += " · \(detail)" }
        return text
    }

    // MARK: - Action / headline

    /// "Reading Board.swift", or the bare verb when there is no object ("Searching the web").
    /// The object is a path or a search term — the UI's job is to middle-truncate it, never
    /// this model's, but a row's own text can't grow unbounded either, so it caps at 40 here.
    private static func actionText(_ action: ActivityAction) -> String {
        guard let object = action.object else { return action.verb }
        return "\(action.verb) \(middleTruncate(object, limit: 40))"
    }

    private static func middleTruncate(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let keep = limit - 1 // for the ellipsis
        let head = keep / 2 + keep % 2, tail = keep / 2
        guard head > 0, tail > 0 else { return String(s.prefix(limit)) }
        return "\(s.prefix(head))…\(s.suffix(tail))"
    }

    private static func stepsText(_ steps: ActivitySteps) -> String {
        guard let current = steps.current else { return "Step \(steps.done) of \(steps.total)" }
        return "Step \(steps.done + 1) of \(steps.total) · \(current)"
    }

    // MARK: - Failure

    /// The stream's own error when it has one; otherwise the checkpoint's own verdict on this
    /// slot — `.failed` is the status a fallback attempt gets when it fails too (`draft()`'s
    /// only path that also sets a `diagnosis`); otherwise `run.json`'s exit code (0 is not a
    /// failure); otherwise `"stopped"` when the process ended with no exit code at all
    /// (`ActivityParser.finish`'s own wording for that case, kept in step with it).
    private static func failureReason(activity: SeatActivity?, slot: SlotOutcome?, record: RunRecord?) -> String? {
        if let error = activity?.error, !error.isEmpty { return error }
        if slot?.status == .failed { return slot?.diagnosis?.detail ?? "failed" }
        if let code = record?.exitCode { return code == 0 ? nil : "exited \(code)" }
        if record?.finished != nil { return "stopped" }
        return nil
    }

    // MARK: - Exceptions while running

    /// Priority when more than one applies: an explicit rate-limit signal beats a time-based
    /// guess; a stall (needs a decision — spec's "Stop seat") beats mere quiet; a fallback that
    /// isn't also stalled still gets its line, since it's the reason the identity has an arrow.
    private static func runningException(activity: SeatActivity, now: Date, thresholds: SeatThresholds,
                                          fallback: Bool, requested: Slot?, activityAgent: AgentID?,
                                          currentAction: String?) -> Exception? {
        if let rateLimitedAt = activity.rateLimitedAt {
            return .rateLimited(max(0, now.timeIntervalSince(rateLimitedAt)))
        }
        let idle = max(0, now.timeIntervalSince(activity.lastEventAt ?? activity.startedAt))
        if idle >= thresholds.stalled { return .stalled(idle, last: currentAction) }
        if fallback, let reason = fallbackReason(slot: nil, requested: requested, activityAgent: activityAgent) {
            return .fallback(reason)
        }
        if idle >= thresholds.quiet { return .quiet(idle) }
        return nil
    }

    // MARK: - Elapsed

    /// Counts up from `startedAt`, frozen at `record.finished` once the process has actually
    /// exited (so a row doesn't keep ticking past a finish `activity.json` never got to record —
    /// see `make`'s `processFinished`). Clamped at 0: `startedAt`/`now` come from different
    /// processes' clocks, and a few milliseconds of skew must never show as a negative count.
    private static func elapsed(activity: SeatActivity?, record: RunRecord?, now: Date) -> TimeInterval {
        guard let started = activity?.startedAt else { return 0 }
        let end = record?.finished ?? now
        return max(0, end.timeIntervalSince(started))
    }

    // MARK: - Footprint

    /// FD's own scratch inside the intake's working directory — never the project — so it is
    /// dropped rather than shown as if the agent had touched the user's repo. `.` is the
    /// project's own root, renamed for a human ("root", not the punctuation).
    private static let ownScratchDirs: Set<String> = ["work", "drafts", "checkpoints"]

    /// Chips by top-level directory, largest first, capped at four plus a `+N` for the rest —
    /// `N` counts the remaining DIRECTORIES, not their combined file count, matching
    /// `ShapingModel.sectionList`'s "+N more items" convention elsewhere in this pipeline.
    private static func footprintAll(_ raw: [String: Int]) -> [(dir: String, count: Int)] {
        var mapped: [String: Int] = [:]
        for (key, count) in raw where !ownScratchDirs.contains(key) {
            mapped[key == "." ? "root" : key, default: 0] += count
        }
        // Case-insensitive tie-break: directory names mix `Dispatch`-style and `docs`-style
        // casing, and a plain `<` would sort every capitalized name ahead of every lowercase one
        // regardless of what it says, which reads as broken rather than alphabetical.
        return mapped.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key.lowercased() < $1.key.lowercased()
        }
            .map { (dir: $0.key, count: $0.value) }
    }

    /// The chip row: the same list, collapsed to its top 4 plus one `+N` chip whose count is the
    /// sum of everything past the fourth — never a distinct count of its own.
    private static func footprintChips(_ all: [(dir: String, count: Int)]) -> [(dir: String, count: Int)] {
        guard all.count > 4 else { return all }
        let rest = all[4...]
        return Array(all.prefix(4)) + [(dir: "+\(rest.count)", count: rest.reduce(0) { $0 + $1.count })]
    }

    // MARK: - Context

    /// codex/gpt-6/gpt-5.x, opus, sonnet and haiku windows (spec's ruling table); an unrecognised
    /// model returns nil so the row hides the gauge instead of guessing.
    private static func contextWindow(for model: String?) -> Int? {
        guard let m = model?.lowercased() else { return nil }
        if m.contains("gpt-6") || m.contains("gpt-5.") { return 400_000 }
        if m.contains("opus") { return 1_000_000 }
        if m.contains("sonnet") { return 1_000_000 }
        if m.contains("haiku") { return 200_000 }
        return nil
    }

    private static func contextFraction(inputTokens: Int?, model: String?) -> Double? {
        guard let inputTokens, let window = contextWindow(for: model), window > 0 else { return nil }
        return Double(inputTokens) / Double(window)
    }

    // MARK: - Result

    /// A finished seat's outcome, read off the round's checkpoint (not this seat alone — see
    /// `roundRecord`'s doc comment): the reviewer/synthesizer show what they proposed, the
    /// integrator shows how it judged those proposals, and encode/polish/fresh-eyes/dedup — all
    /// `changeSetSeat` roles — show the size of the change set they produced. Never "bead" (spec
    /// §2): "N task changes", not "N bead changes". A drafter has no round-level tally of its
    /// own (`RoundRecord.changeCount` is nil for a draft round), so it falls through to nil.
    private static func result(rawRole: String, roundRecord: RoundRecord?) -> String? {
        guard let record = roundRecord else { return nil }
        switch rawRole {
        case "reviewer", "synthesizer":
            guard let n = record.changeCount else { return nil }
            guard n > 0 else { return "No changes proposed" }
            let sections = record.sectionsChanged.isEmpty ? "" : " across " + record.sectionsChanged.map(sectionChip).joined(separator: " ")
            return "\(n) change\(n == 1 ? "" : "s")\(sections)"
        case "integrator":
            guard let tally = record.tally else { return nil }
            return "agreed \(tally.agree) · somewhat \(tally.somewhat) · declined \(tally.disagree)"
        case "encoder", "polisher":
            guard let n = record.changeCount else { return nil }
            return "\(n) task change\(n == 1 ? "" : "s")"
        default:
            return nil
        }
    }

    /// A finished seat's outcome from its own `SeatResult` (spec §6 "results as they land"): the
    /// same wording `result(rawRole:roundRecord:)` uses, so a row reads the same before and
    /// after its round's checkpoint lands. An integrator says both what it judged and what it
    /// changed, since the tally alone can't show a "somewhat" that rewrote half a section.
    private static func result(_ r: SeatResult) -> String? {
        switch r.kind {
        case .reviewer:
            guard let n = r.changeCount else { return nil }
            guard n > 0 else { return "No changes proposed" }
            let sections = r.sections.isEmpty ? "" : " across " + r.sections.map(sectionChip).joined(separator: " ")
            return "\(n) change\(n == 1 ? "" : "s")\(sections)"
        case .integrator:
            var parts: [String] = []
            if let a = r.agree, let s = r.somewhat, let d = r.disagree {
                parts.append("agreed \(a) · somewhat \(s) · declined \(d)")
            }
            if let added = r.linesAdded, let removed = r.linesRemoved {
                let n = r.sections.count
                parts.append("+\(added) −\(removed)" + (n > 0 ? " in \(n) section\(n == 1 ? "" : "s")" : ""))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .changeSet:
            guard let n = r.ops else { return nil }
            return "\(n) task change\(n == 1 ? "" : "s")"
        case .draft:
            guard let n = r.linesAdded else { return nil }
            return "Draft · \(n) line\(n == 1 ? "" : "s")"
        }
    }

    /// "§2" from a heading like "## 2. Scope"; a heading with no leading number chips on its
    /// first word instead, so an older or hand-edited plan still gets something short.
    private static func sectionChip(_ heading: String) -> String {
        let stripped = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        if let range = stripped.range(of: #"^\d+"#, options: .regularExpression) { return "§\(stripped[range])" }
        return "§" + (stripped.split(separator: " ").first.map(String.init) ?? stripped)
    }
}

/// How long a seat may look idle before the row calls it quiet or stalled (spec §6). Named
/// constants, not tuned against real runs yet (spec §12 non-goal) — a future pass adjusts these
/// two numbers, never the call sites.
struct SeatThresholds: Equatable {
    var quiet: TimeInterval = AgentActivityRules.quiet
    var stalled: TimeInterval = AgentActivityRules.stalled
    static let `default` = SeatThresholds()
}

/// Holds a seat row's headline and action text on screen for a minimum dwell — headline ≥ 3 s,
/// action ≥ 1.5 s (spec §6) — so a burst of short-lived reasoning/tool-use text doesn't flicker
/// faster than a human can read it. `offer` is called with the CURRENT (latest) values every
/// time the row would otherwise redraw (a 1 Hz tick, a fresh `SeatActivity`); intermediate values
/// offered between two dwell-gated updates are never shown — coalesced into whatever is latest
/// once the dwell elapses, which is what makes this a hold, not a queue. The very first value on
/// either channel shows immediately: there is nothing yet to hold, and spec §3 promises "no dead
/// moments", not a 3 s blank seat row.
@MainActor
final class DwellScheduler: ObservableObject {
    @Published private(set) var headline: String?
    @Published private(set) var action: String?

    private let clock: () -> Date
    private var headlineChangedAt: Date?
    private var actionChangedAt: Date?

    static let headlineDwell: TimeInterval = 3
    static let actionDwell: TimeInterval = 1.5

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Offering the SAME value repeatedly (the common case: the engine hasn't moved on) is how a
    /// hold gets released once its dwell expires — the first call after a change starts the
    /// dwell clock, and a later call with that value already past `dwell` old is what lets a
    /// still-different `offered` win. There is no separate "flush" entry point; callers just
    /// keep calling `offer` on every tick with whatever the source currently says.
    @discardableResult
    func offer(headline: String?, action: String?) -> (headline: String?, action: String?) {
        let now = clock()
        self.headline = Self.settle(current: self.headline, changedAt: &headlineChangedAt, offered: headline,
                                     dwell: Self.headlineDwell, now: now)
        self.action = Self.settle(current: self.action, changedAt: &actionChangedAt, offered: action,
                                   dwell: Self.actionDwell, now: now)
        return (self.headline, self.action)
    }

    private static func settle(current: String?, changedAt: inout Date?, offered: String?, dwell: TimeInterval,
                                now: Date) -> String? {
        guard offered != current else { return current }
        guard let since = changedAt else {
            // Nothing shown yet on this channel — adopt the first value with no wait.
            changedAt = now
            return offered
        }
        guard now.timeIntervalSince(since) >= dwell else { return current }
        // Releasing the hold IS a change of displayed value — reset the clock here too, or the
        // very next transition inherits this one's already-expired `changedAt` and shows with
        // zero dwell instead of a fresh one.
        changedAt = now
        return offered
    }
}
