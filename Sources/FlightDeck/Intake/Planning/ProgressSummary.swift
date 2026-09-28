import Foundation
import IntakeKit

/// The header's one line of finished phases (spec §3 item 1): `✓ Triage 3:40 · 41 files
/// ✓ Draft & Synthesis 9:42 · 412 lines ✓ Refine ×3`. Pure — the ticks, spacing and type are the
/// view's; this decides only which phases have finished and what each one honestly measured.
/// Every number comes from a timestamp or a count the engine wrote down; a phase with nothing
/// recorded shows its name alone rather than a guess (spec §2 "honest data only").
enum ProgressSummary {
    /// - Parameters:
    ///   - triage: the last triage turn's `SeatActivity` (`IntakeService.triageActivity`) — nil
    ///     after a relaunch, since the service only keeps it for the session that ran it.
    ///   - loadFile: reads a checkpoint's file, as `ShapingModel.planText` does — the only
    ///     source of the plan's length, which no `RoundRecord` carries for draft or synthesis.
    ///     nil leaves the line count out.
    static func line(intake: Intake, tape: Tape, triage: SeatActivity? = nil,
                     loadFile: ((Int, String) -> Data?)? = nil) -> [(label: String, detail: String)] {
        var out: [(label: String, detail: String)] = []
        if triageFinished(intake) {
            out.append((label: "Triage", detail: triageDetail(intake, triage)))
        }
        let cps = tape.checkpoints

        let drafting = cps.filter { $0.stage == .draft || $0.stage == .synthesis }
        if let last = drafting.last {
            let lines = loadFile.flatMap { ShapingModel.planText(checkpoint: last.id, in: tape, loadFile: $0) }
                .map { lineCount($0) }
            let detail = [totalDuration(drafting, in: cps).map(BoardModel.clock),
                          lines.map { "\($0) line\($0 == 1 ? "" : "s")" }].compactMap { $0 }
            out.append((label: drafting.contains { $0.stage == .synthesis } ? "Draft & Synthesis" : "Draft",
                        detail: detail.joined(separator: " · ")))
        }
        let refines = cps.filter { $0.stage == .refine }.count
        if refines > 0 { out.append((label: "Refine", detail: "×\(refines)")) }
        if let encode = cps.last(where: { $0.stage == .encode }) {
            // "task changes", never ops: an encode's `changeCount` is its change set's op count,
            // edges included, so calling it "N tasks" would overstate what it created.
            out.append((label: "Encode", detail: encode.record.changeCount.map { "\($0) task change\($0 == 1 ? "" : "s")" } ?? ""))
        }
        let polishes = cps.filter { $0.stage == .polish }.count
        if polishes > 0 { out.append((label: "Polish", detail: "×\(polishes)")) }
        for (stage, label) in [(Stage.freshEyes, "Fresh eyes"), (.dedup, "Dedup")] {
            guard let cp = cps.last(where: { $0.stage == stage }) else { continue }
            out.append((label: label, detail: cp.record.changeCount.map { "\($0) change\($0 == 1 ? "" : "s")" } ?? ""))
        }
        return out
    }

    /// Past triage for good — not `.needsAnswers`, which is triage waiting on the human
    /// mid-conversation. `recommended` is triage's own output, so it also covers a later
    /// `.failed`/`.interrupted` intake whose failure came after triage, not during it.
    private static func triageFinished(_ intake: Intake) -> Bool {
        switch intake.state {
        case .triaging, .needsAnswers, .discarded: return false
        case .awaitingChoice, .parked, .shaping, .review, .releasing, .released, .partiallyReleased: return true
        case .failed, .interrupted: return intake.recommended != nil
        }
    }

    /// Clock and files only for a triage that was one turn: `activity.json` is rewritten by every
    /// turn, so after a clarifying round it holds the LAST turn alone, and its clock and footprint
    /// would pass off a fraction of triage as the whole. The number of question rounds is what
    /// the intake itself records in that case.
    private static func triageDetail(_ intake: Intake, _ activity: SeatActivity?) -> String {
        let rounds = intake.exchanges.count
        guard rounds == 0 else { return "\(rounds) round\(rounds == 1 ? "" : "s") of questions" }
        guard let activity, activity.finished, activity.error == nil else { return "" }
        // `footprintAll`, not the raw map: it drops FD's own scratch the same way the seat row does.
        let files = SeatRowModel.make(run: "triage", slot: nil, requested: nil, activity: activity, record: nil,
                                      roundRecord: nil, now: activity.startedAt).footprintAll.reduce(0) { $0 + $1.count }
        let parts = [activity.lastEventAt.map { BoardModel.clock(max(0, $0.timeIntervalSince(activity.startedAt))) },
                     files > 0 ? "\(files) file\(files == 1 ? "" : "s")" : nil]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Each round's own `createdAt − startedAt`, summed — never first-start-to-last-landing,
    /// which would count time the tape sat paused between rounds. A tape from before round
    /// timestamps falls back to the gap since the previous checkpoint, as `BoardModel`'s
    /// finished slots do; any round with neither makes the whole total unknown, so it is left out
    /// rather than under-reported.
    private static func totalDuration(_ rounds: [Checkpoint], in all: [Checkpoint]) -> TimeInterval? {
        var total: TimeInterval = 0
        for cp in rounds {
            let previous = all.firstIndex(of: cp).flatMap { $0 > 0 ? all[$0 - 1] : nil }
            guard let start = cp.startedAt ?? previous?.createdAt else { return nil }
            total += max(0, cp.createdAt.timeIntervalSince(start))
        }
        return total
    }

    /// Lines as an editor numbers them: a trailing newline ends the last line, it doesn't start
    /// another.
    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? n - 1 : n
    }
}
