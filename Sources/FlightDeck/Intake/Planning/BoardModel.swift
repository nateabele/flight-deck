import Foundation
import IntakeKit

/// One stage slot on the departures board's tape — a finished round, the one in flight, or one
/// still to come — in words and in the fixed code the board falls back to when the name doesn't
/// fit (spec §5.3). The code table is fixed (CLR{n}, DRFT, SYN, RF{n}, ENC, PL{n}, FRSH, DDUP,
/// REV) so a narrow board reads the same on every intake.
struct TapeSlot: Identifiable, Equatable {
    enum State: Equatable { case done, live, future, failed, selected }
    /// "clarify-1", "draft-0", "refine-2", …, "review" — stable across a round finishing, so a
    /// flap surface keyed on it (`card.<id>`) doesn't replay when the slot changes state.
    let id: String
    let name: String
    let code: String
    var state: State
    /// How long the round ran (finished or failed) or has been running (live); nil where there's
    /// no honest origin. See `BoardModel.duration`.
    var duration: TimeInterval?
    let major: Bool
    /// The round consumed notes, or will consume an unanchored note that's pending now.
    var flagged: Bool
    let checkpointID: Int?
    /// "CLARIFY", "REFINE", "POLISH" for the bracketed cycles; nil for one-off stages.
    let group: String?

    /// The narrowest slot that shows `name` whole — what `LabelFit.choose` compares against.
    func fullWidth(measure: (String) -> CGFloat, padding: CGFloat = 8) -> CGFloat { measure(name) + padding }
    /// The narrowest slot that shows `code`; the tape never squeezes a slot below this, it
    /// scrolls instead, so codes can't overlap.
    func codeWidth(measure: (String) -> CGFloat, padding: CGFloat = 8) -> CGFloat { measure(code) + padding }
}

/// A bracketed cycle on the tape ("REFINE ×5"), with the stage its + handle extends — nil once
/// the head is past it, since `TapePlanner` ignores an extend for a finished stage.
struct TapeGroup: Equatable {
    let name: String
    let range: ClosedRange<Int>
    let extendable: Stage?

    /// The group's short form, from the same code table as its slots ("RF" for RF1…RF5), for a
    /// bracket too narrow for the name (`BoardModel.bracketTitles`).
    var code: String {
        switch name {
        case "CLARIFY": "CLR"
        case "REFINE": "RF"
        case "POLISH": "PL"
        default: name
        }
    }
}

/// One cell of the board row. `shortLabel` is the label's short form (spec §5.3), used when the
/// label itself doesn't fit its cell — a readable word ("PAUSED", "IN AIR"), never a cryptic
/// abbreviation, because a caption nobody can decode is worse than none.
struct BoardField: Equatable {
    let label: String
    let shortLabel: String
    let value: String
    let detail: String?
    /// `value`'s short form ("RF2", "5 · RF5 · ENC · …") for a cell too narrow for the names;
    /// nil where the value has no code (a clock, "Not started").
    var valueCode: String? = nil
    /// `detail` said with slot codes ("since ENC", "since RF2 failed"), for a cell where the
    /// sentence would be cut mid-word; nil where `detail` is free text (a failure diagnosis)
    /// that has no shorter honest form.
    var shortDetail: String? = nil
}

/// Everything the departures board (spec §5) shows, derived from an intake, its tape and a clock
/// with no SwiftUI in sight — so which slot is live, where each play mode stops and what the
/// board fields say are pinned by `BoardModelTests` rather than discovered by clicking.
struct BoardModel: Equatable {
    var slots: [TapeSlot]
    var groups: [TapeGroup]
    var now: BoardField
    /// The state chip beside NOW's value: ON COURSE, PAUSED, STOPPED, FAILED, NEEDS YOU, READY.
    var nowChip: String
    var inTheAir: BoardField
    var stopsAt: BoardField
    var callingAt: BoardField
    /// The slot the current (or previewed) play mode stops on — outlined in accent. Nil at review.
    var stopSlotID: String?
    /// The head slot while the tape sits paused, stopped or idle — outlined with a pause glyph.
    var pausedAtSlotID: String?

    /// `now` is the caller's clock (a 1 Hz timer), not `Date()`, so the live slot's duration is
    /// testable and the board re-derives only when the view asks.
    ///
    init(intake: Intake, tape: Tape, config: RoundConfig, now: Date, selected: Int?, preview: PlayMode?) {
        let markers = Self.stages(tape: tape, config: config)
        let pending = markers.firstIndex { !$0.done }
        let unanchoredPending = tape.pendingNotes.contains { $0.anchor == nil }

        var slots: [TapeSlot] = intake.exchanges.filter { $0.answers != nil }.indices.map { i in
            TapeSlot(id: "clarify-\(i + 1)", name: "Clarify \(i + 1)", code: "CLR\(i + 1)", state: .done,
                     duration: nil, major: false, flagged: false, checkpointID: nil, group: "CLARIFY")
        }
        for (i, marker) in markers.enumerated() {
            let checkpoint = marker.checkpointID.flatMap { id in tape.checkpoints.first { $0.id == id } }
            var state: TapeSlot.State = .future
            var flagged = false
            if let checkpoint {
                state = checkpoint.id == selected ? .selected : .done
                flagged = !checkpoint.record.annotations.isEmpty
            } else if i == pending {
                switch tape.status {
                case .running: state = .live
                case .failed: state = .failed
                default: break
                }
                flagged = unanchoredPending
            }
            // Done markers are the tape's checkpoints in order, so the previous one is `i - 1`.
            let previous = i > 0 && i <= tape.checkpoints.count ? tape.checkpoints[i - 1] : nil
            slots.append(TapeSlot(id: "\(marker.stage.rawValue)-\(marker.round)",
                                  name: Self.name(stage: marker.stage, round: marker.round),
                                  code: Self.code(stage: marker.stage, round: marker.round),
                                  state: state,
                                  duration: Self.duration(state: state, landed: checkpoint, previous: previous, tape: tape, now: now),
                                  major: marker.major, flagged: flagged,
                                  checkpointID: marker.checkpointID, group: Self.group(marker.stage)))
        }
        slots.append(TapeSlot(id: "review", name: "Review", code: "REV",
                              state: tape.status == .reachedReview ? .done : .future,
                              duration: nil, major: true, flagged: false, checkpointID: nil, group: nil))
        self.slots = slots

        let extendable = Self.extendableStages(tape: tape, config: config)
        self.groups = ["CLARIFY", "REFINE", "POLISH"].compactMap { name in
            guard let first = slots.firstIndex(where: { $0.group == name }),
                  let last = slots.lastIndex(where: { $0.group == name }) else { return nil }
            let stage: Stage? = switch name {
            case "REFINE": .refine
            case "POLISH": .polish
            default: nil
            }
            return TapeGroup(name: name, range: first...last, extendable: stage.flatMap { extendable.contains($0) ? $0 : nil })
        }

        // Placeholders so `self` is whole before the fields below read `slots` through it.
        let blank = BoardField(label: "", shortLabel: "", value: "", detail: nil)
        self.now = blank
        self.nowChip = ""
        self.inTheAir = blank
        self.stopsAt = blank
        self.callingAt = blank
        self.stopSlotID = nil
        self.pausedAtSlotID = nil

        let head = tape.head.map { Self.name(stage: $0.stage, round: $0.round) }
        // Clarify slots come first, so marker `i` is slot `i + clarifyCount`.
        let clarifyCount = slots.count - markers.count - 1
        let next = pending.map { slots[$0 + clarifyCount] }
        switch tape.status {
        case .running:
            let live = slots.first { $0.state == .live }
            let leg = slots.firstIndex { $0.state == .live }.map { $0 + 1 }
            self.now = BoardField(label: "NOW", shortLabel: "NOW", value: live?.name ?? head ?? "—",
                                  detail: leg.map { "Leg \($0) of \(slots.count)" }, shortDetail: leg.map { "Leg \($0)/\(slots.count)" })
            self.nowChip = "ON COURSE"
            // How long the round in flight has been up — the live slot's own clock, not the run's
            // total, which would read as this round having flown for eighteen minutes.
            self.inTheAir = BoardField(label: "IN THE AIR", shortLabel: "IN AIR",
                                       value: live?.duration.map(Self.clock) ?? "—", detail: nil)
        case .failed:
            self.now = BoardField(label: "NOW", shortLabel: "NOW", value: next?.name ?? head ?? "—",
                                  detail: tape.pauseDiagnosis?.detail ?? "Round failed")
            self.nowChip = "FAILED"
            if let failedAt = tape.failedAt, let failed = next {
                self.inTheAir = BoardField(label: "HALTED FOR", shortLabel: "HALTED",
                                           value: Self.clock(max(0, now.timeIntervalSince(failedAt))),
                                           detail: "since \(failed.name) failed", shortDetail: "since \(failed.code) failed")
            } else {
                // A failure written before `failedAt` existed: the head's landing is the last time on record.
                self.inTheAir = Self.sinceHead(tape, label: "HALTED FOR", short: "HALTED", now: now)
            }
        case .reachedReview:
            self.now = BoardField(label: "NOW", shortLabel: "NOW", value: "Review", detail: "Landed · ready for review",
                                  shortDetail: "Ready for review")
            self.nowChip = "NEEDS YOU"
            let total = slots.compactMap(\.duration).reduce(0, +)
            self.inTheAir = BoardField(label: "TOTAL", shortLabel: "TOTAL", value: Self.clock(total), detail: nil)
        case .idle, .paused, .stopped:
            let notes = tape.pendingNotes.count
            let noted = "\(notes) note\(notes == 1 ? "" : "s")"
            self.now = BoardField(label: "NOW", shortLabel: "NOW", value: head ?? "Not started",
                                  detail: next.map { notes == 0 ? "Next: \($0.name)" : "\(noted) will go to \($0.name)" },
                                  shortDetail: next.map { notes == 0 ? "Next: \($0.code)" : "\(noted) → \($0.code)" })
            self.pausedAtSlotID = tape.head.flatMap { head in slots.first { $0.checkpointID == head.id }?.id }
            self.nowChip = tape.status == .stopped ? "STOPPED" : head == nil ? "READY" : "PAUSED"
            self.inTheAir = Self.sinceHead(tape, label: "PAUSED FOR", short: "PAUSED", now: now)
        }

        // STOPS AT answers "where does play go from here": the hovered button's stop while
        // previewing, the live target while running, else the config's default play.
        let mode = preview ?? (tape.status == .running ? Self.mode(for: tape.target) : config.defaultPlay)
        let target = stopTarget(for: mode)
        let stop = target.flatMap { id in slots.firstIndex { $0.id == id } }
        let modeName = switch mode {
        case .step: "step"
        case .nextMajor: "next major"
        case .toReview: "to review"
        }
        self.stopsAt = BoardField(label: preview == nil ? "STOPS AT" : "WOULD STOP",
                                  shortLabel: preview == nil ? "STOPS" : "WOULD",
                                  // At review the run has arrived: it stops at Review, where it is.
                                  value: stop.map { slots[$0].name } ?? "Review",
                                  detail: stop.map { (slots[$0].major ? "major · " : "minor · ") + modeName }
                                      ?? "ready for you",
                                  shortDetail: stop.map { slots[$0].major ? "major" : "minor" } ?? "ready")
        // The spec's shape: how many major stops remain, then their names ("2 · Dedup · Review").
        let after = stop.map { Array(slots[($0 + 1)...].filter(\.major)) } ?? []
        let calling = { (words: [String]) in (["\(after.count)"] + words).joined(separator: " · ") }
        self.callingAt = BoardField(label: "CALLING AT", shortLabel: "CALLING",
                                    value: after.isEmpty ? "Release tasks · done" : calling(after.map(\.name)),
                                    detail: nil,
                                    valueCode: after.isEmpty ? nil : calling(after.map(\.code)))
        self.stopSlotID = stop.map { slots[$0].id }
        self.stopsAt.valueCode = stop.map { slots[$0].code }
        self.now.valueCode = slots.first { $0.name == self.now.value }?.code
    }

    /// Every split-flap surface the board draws (spec §5.3) and the text on it now — the one list
    /// both the board and `IntakeService`'s seeding read, so a value the service seeds as "already
    /// shown" is exactly the text the board later asks `FlapPolicy` about. Seeding a text the board
    /// never draws would leave the drawn one unseeded, and it would flap on first mount.
    ///
    /// Clocks never flap: `board.inTheAir` carries IN THE AIR's LABEL, not its value. The value is
    /// a duration that changes every second, so keyed on it every tick would be "new text" and
    /// the clock would flip continuously; the label changes only when the run's state does
    /// (IN THE AIR ↔ PAUSED FOR ↔ HALTED FOR). A tape label's surface is the slot's bare id —
    /// what `SplitFlapText` is handed, so its card lands on `card.<id>` — seeded so a slot
    /// scrolling into view doesn't flip in; only a newly added slot (an extend) does.
    var flapTexts: [String: String] {
        var texts = ["board.now": now.value, "board.inTheAir": inTheAir.label,
                     "board.stopsAt": stopsAt.value, "board.callingAt": callingAt.value]
        for slot in slots {
            texts[slot.id] = slot.name
            texts["card.\(slot.id)"] = slot.name
        }
        return texts
    }

    // MARK: - Card and accessibility

    /// The slot the tape keeps in view: the round in flight (or the one that failed), else
    /// where the run is paused, else where play would stop. The model's, not the view's, so a
    /// test pins it — late in a run on a narrow pane the live slot is screens away from the
    /// tape's start, and only this brings it into view.
    var followSlotID: String? {
        slots.first { $0.state == .live || $0.state == .failed }?.id ?? pausedAtSlotID ?? stopSlotID
    }

    /// The hover card's status line, under the slot's name in flap tiles ("landed 3:02"): what
    /// the round did and for how long, in the clock's own format.
    /// A round with no honest duration says only its status — never a made-up 0:00.
    func cardDetail(for slot: TapeSlot) -> String {
        let status = Self.status(slot.state)
        return slot.duration.map { "\(status) \(Self.clock($0))" } ?? status
    }

    /// Every slot in full words for VoiceOver (spec §14): "Refine 2, landed, 4 minutes 48
    /// seconds" — the proper name whatever the slot's width, the duration spoken rather than
    /// "4:48", then what the board marks visually (major stop, notes, selection, stop target). The pause
    /// marker isn't repeated here: NOW already says where the run is paused.
    func accessibilityLabel(for slot: TapeSlot) -> String {
        var parts = [slot.name, Self.status(slot.state)]
        if let duration = slot.duration { parts.append(Self.spokenDuration(duration)) }
        if slot.major { parts.append("major stop") }
        if slot.flagged { parts.append("has notes") }
        if slot.state == .selected { parts.append("selected") }
        if slot.id == stopSlotID { parts.append("stops here") }
        return parts.joined(separator: ", ")
    }

    private static func status(_ state: TapeSlot.State) -> String {
        switch state {
        case .done, .selected: "landed"
        case .live: "in the air"
        case .failed: "failed"
        case .future: "scheduled"
        }
    }

    /// "1 hour 2 minutes 3 seconds", dropping zero units; "0 seconds" for under a second.
    static func spokenDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let units = [(total / 3600, "hour"), (total / 60 % 60, "minute"), (total % 60, "second")]
        let words = units.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return words.isEmpty ? "0 seconds" : words.joined(separator: " ")
    }

    /// The slot `mode` would stop on if pressed now, or nil once the tape has reached review.
    /// Step stops after the next round (the live one, when running — the runner finishes it
    /// first); next major at the first major round from there; to review at Review.
    func stopTarget(for mode: PlayMode) -> String? {
        let upcoming = slots.filter { $0.id != "review" && ($0.state == .live || $0.state == .future || $0.state == .failed) }
        guard let review = slots.last, review.state != .done else { return nil }
        switch mode {
        case .step: return (upcoming.first ?? review).id
        case .nextMajor: return (upcoming.first(where: \.major) ?? review).id
        case .toReview: return review.id
        }
    }

    /// Slot widths for a tape `available` points wide. When every full name fits, each slot gets
    /// its full-name width plus an equal share of the slack; otherwise an equal share, but never
    /// less than the slot's code width. A tape that can't fit even the codes is wider than
    /// `available` by exactly the shortfall and scrolls — squeezing slots instead would make
    /// neighbouring codes overlap.
    func slotWidths(available: CGFloat, measure: (String) -> CGFloat) -> [CGFloat] {
        guard !slots.isEmpty else { return [] }
        let full = slots.map { $0.fullWidth(measure: measure) }
        let fullTotal = full.reduce(0, +)
        if fullTotal <= available {
            let slack = (available - fullTotal) / CGFloat(slots.count)
            return full.map { $0 + slack }
        }
        let code = slots.map { $0.codeWidth(measure: measure) }
        let codeTotal = code.reduce(0, +)
        guard codeTotal < available else { return code }
        let slack = (available - codeTotal) / CGFloat(slots.count)
        return code.map { $0 + slack }
    }

    // MARK: - Stage replay

    /// The tape's checkpoints, then whatever `TapePlanner` would run after them, found by
    /// replaying `next` on a scratch copy — the planner's sequence is private, and replaying it
    /// means the strip can never disagree with what the runner will actually do (extensions
    /// included). `ShapingModel.stages` is this too, so the two views can't drift apart.
    static func stages(tape: Tape, config: RoundConfig?) -> [StageMarker] {
        var markers = tape.checkpoints.enumerated().map { i, cp in
            StageMarker(order: i, stage: cp.stage, round: cp.round, label: ShapingModel.label(stage: cp.stage, round: cp.round),
                        major: cp.major, done: true, inProgress: false, checkpointID: cp.id)
        }
        guard let config else { return markers }
        var scratch = tape
        // Bounded so a planner bug can't hang the main thread; no real config comes close.
        while markers.count < 200, let next = TapePlanner.next(after: scratch, config: config) {
            markers.append(StageMarker(order: markers.count, stage: next.stage, round: next.round,
                                       label: ShapingModel.label(stage: next.stage, round: next.round), major: next.major,
                                       done: false, inProgress: false, checkpointID: nil))
            scratch.checkpoints.append(Checkpoint(id: (scratch.head?.id ?? 0) + 1, stage: next.stage, round: next.round,
                                                  major: next.major, createdAt: Date(timeIntervalSince1970: 0)))
        }
        if tape.status == .running, let first = markers.firstIndex(where: { !$0.done }) {
            markers[first].inProgress = true
        }
        return markers
    }

    /// Stages + can lengthen: ones the config actually runs and the head hasn't moved past.
    /// `TapePlanner` silently ignores an extend for a finished stage, so offering it would be a
    /// control that does nothing.
    static func extendableStages(tape: Tape, config: RoundConfig?) -> [Stage] {
        guard let config else { return [] }
        let headRank = tape.head.map { rank($0.stage) } ?? -1
        var stages: [Stage] = []
        if config.reviewer != nil, headRank <= rank(.refine) { stages.append(.refine) }
        if config.polisher != nil, headRank <= rank(.polish) { stages.append(.polish) }
        return stages
    }

    /// Stage order in the planned sequence — `Stage` is declared in that order but isn't
    /// `CaseIterable`, and IntakeKit is out of scope here.
    private static func rank(_ s: Stage) -> Int {
        [Stage.draft, .synthesis, .refine, .encode, .polish, .freshEyes, .dedup].firstIndex(of: s) ?? 0
    }

    /// `group`'s bracket title, longest first, for `DeparturesBoard.fittedBracketTitle` to take
    /// the first that fits: "REFINE 2 OF 3" while one of its rounds is in flight or failed, else
    /// "REFINE ×3"; then the code with the same count ("RF 2 OF 3"); then the name alone; then
    /// nothing. The count goes before the name does: a bare "2 OF 3" or "×2" named no cycle. A
    /// one-round group has no count at all — "CLARIFY ×1" read as a tally of nothing.
    func bracketTitles(_ group: TapeGroup) -> [String] {
        let members = slots[group.range]
        guard members.count > 1 else { return [group.name, group.code, ""] }
        let count = members.firstIndex { $0.state == .live || $0.state == .failed }
            .map { "\($0 - group.range.lowerBound + 1) OF \(members.count)" } ?? "×\(members.count)"
        return ["\(group.name) \(count)", "\(group.code) \(count)", group.name, ""]
    }

    // MARK: - Names

    static func name(stage: Stage, round: Int) -> String {
        switch stage {
        case .draft: "Draft"
        case .synthesis: "Synthesis"
        case .refine: "Refine \(round)"
        case .encode: "Encode"
        case .polish: "Polish \(round)"
        case .freshEyes: "Fresh eyes"
        case .dedup: "Dedup"
        }
    }

    static func code(stage: Stage, round: Int) -> String {
        switch stage {
        case .draft: "DRFT"
        case .synthesis: "SYN"
        case .refine: "RF\(round)"
        case .encode: "ENC"
        case .polish: "PL\(round)"
        case .freshEyes: "FRSH"
        case .dedup: "DDUP"
        }
    }

    private static func group(_ stage: Stage) -> String? {
        switch stage {
        case .refine: "REFINE"
        case .polish: "POLISH"
        default: nil
        }
    }

    /// The play mode a running tape's target amounts to. `.none` (a pause is pending) stops
    /// after the round in flight, which is where step stops too.
    static func mode(for target: TapeTarget) -> PlayMode {
        switch target {
        case .none, .nextMinor: .step
        case .nextMajor: .nextMajor
        case .review: .toReview
        }
    }

    /// The one place a slot's duration is decided, from the engine's round timestamps:
    ///
    /// - finished: `createdAt − startedAt`;
    /// - live: `now − roundStartedAt`;
    /// - failed: `failedAt − roundStartedAt`.
    ///
    /// A tape written before those timestamps existed falls back to the gap since the previous
    /// checkpoint, for finished and live rounds. That gap includes any time the tape sat paused
    /// before the round, but it is the best the old tape records. `heartbeat` is never an
    /// origin: the runner rewrites it on every beat, so it means "last seen", not "round began".
    /// With no timestamps, the first round falls back to nothing: `Intake.createdAt` would fold
    /// triage and the human's think time into Draft. A failure without both timestamps also gets
    /// nothing. Clarify slots never reach here, because exchanges carry no timestamps.
    private static func duration(state: TapeSlot.State, landed: Checkpoint?, previous: Checkpoint?,
                                 tape: Tape, now: Date) -> TimeInterval? {
        if let landed {
            guard let start = landed.startedAt ?? previous?.createdAt else { return nil }
            return landed.createdAt.timeIntervalSince(start)
        }
        switch state {
        case .live:
            guard let start = tape.roundStartedAt ?? tape.head?.createdAt else { return nil }
            return max(0, now.timeIntervalSince(start))
        case .failed:
            guard let start = tape.roundStartedAt, let end = tape.failedAt else { return nil }
            return end.timeIntervalSince(start)
        case .done, .future, .selected:
            return nil
        }
    }

    /// PAUSED FOR (and HALTED FOR on a tape without `failedAt`): time since the head landed,
    /// said as such in `detail`.
    private static func sinceHead(_ tape: Tape, label: String, short: String, now: Date) -> BoardField {
        guard let head = tape.head else {
            return BoardField(label: label, shortLabel: short, value: "—", detail: nil)
        }
        return BoardField(label: label, shortLabel: short, value: clock(max(0, now.timeIntervalSince(head.createdAt))),
                          detail: "since \(name(stage: head.stage, round: head.round)) landed",
                          shortDetail: "since \(code(stage: head.stage, round: head.round))")
    }

    /// "4:48", or "1:02:03" past the hour — counting up, never an ETA (spec §2).
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
