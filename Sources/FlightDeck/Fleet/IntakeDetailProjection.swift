import CryptoKit
import FleetKit
import Foundation
import IntakeKit

/// The intake screen's content (spec §6.2), built from the desktop's own models so the phone
/// and the Mac describe the same moment the same way. Every now-dependent value is a DATE:
/// board clocks travel as `clockSince`, agent rows are built at `.distantPast` (no quiet, no
/// stalled, no running elapsed) and carry their dates instead, and a live slot has no duration.
/// So the encoded detail is byte-identical while nothing happens, which is what the etag needs.
enum IntakeDetailProjection {
    static let failureOutputLimit = 4096

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 over the detail encoded with sorted keys, `etag` blanked and `servedAt` zeroed —
    /// every input is already in memory, and a hash cannot go stale the way picked mtimes can.
    static func etag(_ detail: WireIntakeDetail) -> String {
        var d = detail
        d.etag = ""
        d.servedAt = .distantPast
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return hash((try? encoder.encode(d)) ?? Data())
    }

    /// The last `limit` UTF-8 bytes of `text`, moved forward to a character boundary when the
    /// cut lands inside one — `String(Substring.UTF8View)` is nil there, and the whole tail
    /// would read as empty.
    static func tail(_ text: String, limit: Int) -> String {
        let utf8 = text.utf8
        var cut = utf8.index(utf8.endIndex, offsetBy: -limit, limitedBy: utf8.startIndex) ?? utf8.startIndex
        while cut < utf8.endIndex, UTF8.isContinuation(utf8[cut]) { cut = utf8.index(after: cut) }
        return String(utf8[cut...]) ?? ""
    }

    /// `model` was built at `.distantPast`, so its running elapsed is 0 and it carries no
    /// quiet/stalled/rate-limited exception — the phone judges those from the dates sent here.
    /// A finished row's elapsed is frozen at `run.json`'s exit; a finish only `activity.json`
    /// recorded has no end on record, reads 0 here, and is sent as no duration, never "0:00".
    static func agent(_ model: SeatRowModel, activity: SeatActivity?) -> WireAgent {
        let glyph: String = switch model.glyph {
        case .queued: "queued"
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        case .fallback: "fallback"
        case .needsYou: "needsYou"
        }
        var fallback: String?, failure: String?
        switch model.exception {
        case .fallback(let text): fallback = text
        case .failed(let text): failure = text
        default: break
        }
        let finished = model.glyph == .done || model.glyph == .failed
        return WireAgent(
            id: model.id, glyph: glyph, role: model.role, identity: model.identity,
            headline: model.headline, action: model.action, steps: model.steps,
            contextFraction: model.contextFraction,
            footprint: model.footprint.map { WireFootprint(dir: $0.dir, count: $0.count) },
            result: model.result, cost: model.cost,
            startedAt: activity?.startedAt, lastEventAt: activity?.lastEventAt,
            rateLimitedAt: finished ? nil : activity?.rateLimitedAt,
            duration: finished && model.elapsed > 0 ? model.elapsed : nil, fallback: fallback, failure: failure)
    }

    static func round(_ c: Checkpoint) -> WireRound {
        let slots = c.record.slots
        let outcome = slots.contains { $0.status == .failed } ? "failed"
            : slots.contains { $0.status == .substituted } ? "fallback" : "ok"
        return WireRound(
            checkpoint: c.id, name: BoardModel.name(stage: c.stage, round: c.round),
            code: BoardModel.code(stage: c.stage, round: c.round), stage: c.stage.rawValue,
            startedAt: c.startedAt, landedAt: c.createdAt, outcome: outcome,
            changeCount: c.record.changeCount, linesAdded: c.record.linesAdded, linesRemoved: c.record.linesRemoved,
            verdicts: c.record.tally.map { WireVerdicts(agreed: $0.agree, somewhat: $0.somewhat, declined: $0.disagree) },
            note: c.record.note, sectionsChanged: c.record.sectionsChanged,
            agents: slots.map { s in
                WireRoundAgent(role: s.role, ran: "\(s.used.agent.rawValue) · \(s.used.model) · \(s.used.effort)",
                               status: s.status.rawValue, detail: s.diagnosis?.detail)
            },
            // Located against no blocks: the round list names the notes; the plan screen pins them.
            notesConsumed: c.record.annotations.map { IntakePlanProjection.locate($0, consumed: true, in: PlanBlocks(blocks: [])) })
    }

    @MainActor
    static func detail(_ id: UUID, project: UUID, service: IntakeService, servedAt: Date) -> WireIntakeDetail? {
        guard let i = service.intakes.first(where: { $0.id == id }) else { return nil }
        let tape = service.tapes[id]
        let files = service.seats.files(id)
        let summary = IntakeSummaryProjection.summary(i, tape: tape, seats: files,
                                                      needsAttention: service.needsAttention(i))
        let load: (Int, String) -> Data? = { service.checkpointFile(id, checkpoint: $0, $1) }
        let progress = tape.map { ProgressSummary.line(intake: i, tape: $0, triage: service.triageActivities[id], loadFile: load) } ?? []

        var board: WireBoard?
        var agents: [WireAgent] = []
        if let tape, let config = i.roundConfig {
            let model = BoardModel(intake: i, tape: tape, config: config, now: .distantPast, selected: nil, preview: nil)
            board = Self.board(model, tape: tape, config: config, cycles: service.convergence[id])
            if let round = tape.roundInProgress ?? pendingRound(service.pending[id]) {
                let seats = LiveSeats.files(files, pending: service.pending[id])
                agents = LiveSeats.rows(round: round, config: config, seats: seats, now: .distantPast)
                    .map { agent($0.model, activity: seats.activities[$0.model.id]) }
            }
        } else if i.state == .triaging {
            let activity = service.triageActivities[id]
            var model = SeatRowModel.make(run: "triage", slot: nil, requested: nil, activity: activity,
                                          record: nil, roundRecord: nil, now: .distantPast)
            if model.glyph == .running, model.headline == nil { model.headline = "Reading the repo" }
            agents = [agent(model, activity: activity)]
        }

        let answered = i.exchanges.compactMap { e in e.answers.map { WireExchange(questions: e.questions, answers: $0) } }
        let open = i.state == .needsAnswers ? i.exchanges.last.flatMap { $0.answers == nil ? $0.questions : nil } : nil
        let choice: WireChoice? = i.state == .awaitingChoice ? WireChoice(
            recommended: i.recommended?.rawValue, reason: i.recommendationReason, chosen: i.chosenPreset?.rawValue,
            roundsSummary: (i.chosenPreset ?? i.recommended).flatMap { p in i.roundConfig.map { RoundConfigEditor.summary(preset: p, config: $0) } }
        ) : nil
        let failure = i.failure.map { reason in
            WireFailure(reason: reason, output: i.rawFailureOutput.map { tail($0, limit: failureOutputLimit) })
        }
        // What the Mac's control bar says: only while the runner has not acknowledged it
        // (`HaltRequest.label(for:)`), so a pause on an idle tape is not "pausing" forever.
        let halt: String? = tape.flatMap { t in
            service.halts[id].flatMap { h in h.label(for: t) == nil ? nil : (h.kind == .pause ? "pausing" : "stopping") }
        }

        var detail = WireIntakeDetail(
            etag: "", project: project, summary: summary, intent: i.intent,
            progress: progress.map { WireProgressPhase(label: $0.label, detail: $0.detail) },
            board: board, agents: agents,
            rounds: (tape?.checkpoints ?? []).reversed().map(round),
            questions: i.exchanges.isEmpty ? nil : WireQuestions(open: open, answered: answered),
            choice: choice, failure: failure, pendingNotes: tape?.pendingNotes.count ?? 0, halt: halt,
            headCheckpoint: tape.flatMap { PlanSection.planHead(tape: $0, loadFile: load) }, servedAt: servedAt,
            steer: true)
        detail.etag = etag(detail)
        return detail
    }

    private static func pendingRound(_ p: PendingStart?) -> PlannedRound? {
        if case .round(let round?)? = p?.kind { return round }
        return nil
    }

    /// `m` was built at `.distantPast`, so every clock it formatted reads 0 — none is sent: the
    /// running and idle clocks travel as `clockSince`, and a live slot has no duration. Only
    /// review's TOTAL, a sum of finished rounds, goes as text.
    static func board(_ m: BoardModel, tape: Tape, config: RoundConfig, cycles: [ConvergenceCycle]?) -> WireBoard {
        let (caption, since, text): (String, Date?, String?) = switch tape.status {
        case .running: ("IN THE AIR", tape.roundStartedAt ?? tape.head?.createdAt, nil)
        case .failed: ("HALTED FOR", tape.failedAt ?? tape.head?.createdAt, nil)
        case .reachedReview: ("TOTAL", nil, m.inTheAir.value)
        case .idle, .paused, .stopped: ("PAUSED FOR", tape.head?.createdAt, nil)
        }
        let cell = cycles.flatMap { ConvergenceCellModel(cycles: $0) }
        return WireBoard(
            slots: m.slots.map { s in
                let state: String = switch s.state {
                case .done, .selected: "done"
                case .live: "live"
                case .future: "future"
                case .failed: "failed"
                }
                return WireSlot(id: s.id, name: s.name, code: s.code, state: state, major: s.major, group: s.group,
                                checkpoint: s.checkpointID, duration: s.state == .live ? nil : s.duration, flagged: s.flagged)
            },
            nowName: m.now.value, nowChip: m.nowChip, clockCaption: caption, clockSince: since, clockText: text,
            stopsAt: m.stopsAt.value, stopSlotID: m.stopSlotID, callingAt: m.callingAt.value,
            convergence: cell.map { WireConvergence(word: $0.word, amber: $0.tone == .amber, spark: $0.spark) },
            defaultPlay: config.defaultPlay.rawValue,
            controls: controls(TransportRules.make(tape: tape, config: config), board: m))
    }

    /// `rules` as the phone reads them. `annotate` is never sent — notes have their own gate —
    /// and the order is the bar's, so the list is stable and the etag doesn't churn on a Set's
    /// iteration order. The cycle is the one ± acts on, its planned count the board's own slots.
    static func controls(_ rules: TransportRules, board: BoardModel) -> WireControls {
        let order: [TransportButton] = [.step, .nextMajor, .toReview, .pause, .stop, .extend, .trim]
        let names: [TransportButton: String] = [.step: "step", .nextMajor: "nextMajor", .toReview: "toReview",
                                                .pause: "pause", .stop: "stop", .extend: "extend", .trim: "trim"]
        let stage = rules.extendStage ?? rules.trimStage
        let group = stage.map { $0 == .refine ? "REFINE" : "POLISH" }
        return WireControls(
            enabled: order.filter(rules.enabled.contains).compactMap { names[$0] },
            extendStage: rules.extendStage?.rawValue, trimStage: rules.trimStage?.rawValue,
            cycleName: stage.map { $0 == .refine ? "Refine" : "Polish" },
            cyclePlanned: group.map { g in board.slots.filter { $0.group == g }.count })
    }
}
