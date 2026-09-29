import CoreGraphics
import Foundation
import IntakeKit

/// One cell of the control bar's LCD (spec §4): a value over a small-caps caption. `shortValue`
/// is what the cell falls back to when `value` doesn't fit its measured slot (§5.3's rule, the
/// same one the board's labels follow).
struct LCDCell: Equatable, Identifiable {
    enum Kind: String { case round, elapsed, seatsDone, soFar, billed, convergence, coverage, stopsAt }
    /// Colour for exceptions only (spec §2): accent is the live target, amber wants attention,
    /// red is a failure. A paused tape is none of those, so PAUSED is a caption, not a colour.
    enum Tone: Equatable { case normal, accent, amber, red }
    var id: Kind { kind }
    let kind: Kind
    var value: String
    var shortValue: String
    var caption: String
    var tone: Tone

    /// The cell for VoiceOver, in full words (spec §14): the value first, then what it is, the
    /// caption's " · " read as a pause. "—" (nothing to show yet) is said as "none" rather
    /// than read out as a dash.
    var accessibilityLabel: String {
        let spoken = value == "—" ? "none" : value
        return "\(spoken), \(caption.replacingOccurrences(of: " · ", with: ", "))"
    }
}

/// Everything the LCD shows, derived from the tape, its config, the board (which already knows
/// which slot is live and where each play mode stops), the round's seat rows and the caller's
/// clock — no SwiftUI, so what each state says is pinned by `LCDModelTests`.
///
/// The caller rebuilds this on its 1 Hz tick together with the `BoardModel` it passes in, and
/// passes the same `preview` to both: STOPS AT here and on the board must never disagree.
struct LCDModel: Equatable {
    /// Full order: round, elapsed, seatsDone, soFar, billed, convergence, coverage, stopsAt.
    /// Convergence is absent until a Refine/Polish cycle has a series (`convergence == nil`);
    /// coverage is absent for a config that doesn't cross-check and has no reading
    /// (`coverage == nil`); STOPS AT is absent at review, where nothing is left to run and ROUND
    /// already says "ready for you".
    var cells: [LCDCell]
    /// The mode STOPS AT describes — the hovered button's while previewing — so the cell can
    /// draw that button's glyph beside the stop. Nil once there's nothing left to run.
    var stopMode: PlayMode?

    /// The order cells leave as the bar narrows (spec §4): BILLED, then SO FAR, then STOPS AT,
    /// then COVERAGE — STOPS AT is repeated by the board below; nothing repeats COVERAGE. AGENTS
    /// DONE goes last, leaving the compact set.
    static let dropOrder: [LCDCell.Kind] = [.billed, .soFar, .stopsAt, .coverage]
    private static let compactDrop: [LCDCell.Kind] = [.seatsDone]

    init(tape: Tape, config: RoundConfig, board: BoardModel, seats: [SeatRowModel], convergence: ConvergenceCellModel?,
         coverage: CoverageCellModel? = nil, preview: PlayMode?, now: Date) {
        let mode = preview ?? (tape.status == .running ? BoardModel.mode(for: tape.target) : config.defaultPlay)
        let stop = board.slots.first { $0.id == board.stopTarget(for: mode) }
        self.stopMode = stop == nil ? nil : mode
        var cells = [
            Self.round(tape: tape, board: board),
            Self.elapsed(tape: tape, board: board),
            Self.seatsDone(seats),
            Self.soFar(tape: tape),
            Self.billed(seats),
        ]
        if let convergence {
            cells.append(LCDCell(kind: .convergence, value: convergence.word,
                                 shortValue: Self.arrowAndCount(convergence.word, latest: convergence.latest),
                                 caption: "\(convergence.latest) change\(convergence.latest == 1 ? "" : "s")",
                                 tone: convergence.tone))
        }
        if let coverage {
            cells.append(LCDCell(kind: .coverage, value: coverage.word, shortValue: coverage.shortWord,
                                 caption: coverage.caption, tone: coverage.tone))
        }
        if let stop {
            cells.append(LCDCell(kind: .stopsAt, value: board.stopsAt.value, shortValue: stop.code,
                                 caption: (preview == nil ? "stops at" : "would stop") + " · " + Self.modeName(mode),
                                 // White while previewing, as the mockup has it: the accent marks the
                                 // live target, and a hovered "what if" isn't it yet.
                                 tone: preview == nil ? .accent : .normal))
        }
        self.cells = cells
    }

    /// The cells that fit `width`, dropping whole cells in `dropOrder` and then down to the
    /// compact set. `cellWidth` measures a cell at its FULL value: a cell leaves before any
    /// value abbreviates, and only the compact set falls back to short values — which is why
    /// nothing leaves past it, however narrow.
    func visible(width: CGFloat, cellWidth: (LCDCell) -> CGFloat) -> [LCDCell] {
        var shown = cells
        for kind in Self.dropOrder + Self.compactDrop where shown.map(cellWidth).reduce(0, +) > width {
            shown.removeAll { $0.kind == kind }
        }
        return shown
    }

    /// Whether `visible` came down to the compact set — the bar then folds its round tools
    /// into a ⋯ menu to give the LCD the room.
    static func isCompact(_ visible: [LCDCell]) -> Bool {
        !visible.contains { $0.kind == .seatsDone }
    }

    /// The LCD's split-flap surfaces and their text now — its text values only. The clocks and
    /// counters never flap (a ticking value would flap every second), so they're not here, and
    /// `IntakeService.seedFlaps` seeds exactly this list alongside the board's.
    var flapTexts: [String: String] {
        Dictionary(uniqueKeysWithValues: cells.compactMap { cell in Self.flapSurface(cell.kind).map { ($0, cell.value) } })
    }

    /// The split-flap surface a cell's value is drawn on, nil for a value that must not flap.
    static func flapSurface(_ kind: LCDCell.Kind) -> String? {
        switch kind {
        case .round: "lcd.round"
        case .stopsAt: "lcd.stopsAt"
        case .convergence: "lcd.convergence"
        case .coverage: "lcd.coverage"
        case .elapsed, .seatsDone, .soFar, .billed: nil
        }
    }

    // MARK: - Cells

    /// ROUND · OF N: the live round (or the one that failed, or the head a paused tape sits
    /// on), with "of N" only inside a cycle, where N is real — the cycle's length on the tape.
    private static func round(tape: Tape, board: BoardModel) -> LCDCell {
        if tape.status == .reachedReview {
            return LCDCell(kind: .round, value: "REVIEW", shortValue: "REV", caption: "ready for you", tone: .amber)
        }
        let index: Int?
        let status: String
        switch tape.status {
        case .running:
            index = board.slots.firstIndex { $0.state == .live }
            status = "running"
        case .failed:
            index = board.slots.firstIndex { $0.state == .failed }
            status = "failed"
        case .idle, .paused, .stopped, .reachedReview:
            let head = board.slots.lastIndex { $0.checkpointID != nil }
            index = head ?? board.slots.firstIndex { $0.state == .future }
            status = tape.status == .stopped ? "stopped" : head == nil ? "ready" : "paused"
        }
        guard let index else {
            return LCDCell(kind: .round, value: "—", shortValue: "—", caption: status, tone: tape.status == .failed ? .red : .normal)
        }
        let slot = board.slots[index]
        let cycle = board.groups.first { $0.range.contains(index) && $0.name != "CLARIFY" }
        return LCDCell(kind: .round, value: slot.name.uppercased(), shortValue: slot.code,
                       caption: cycle.map { "\(status) · of \($0.range.count)" } ?? status,
                       tone: tape.status == .failed ? .red : .normal)
    }

    /// ELAPSED counts the round in flight up from its own start while running; otherwise it's
    /// the board's own clock for the state (paused for, halted for, total), captioned in words.
    private static func elapsed(tape: Tape, board: BoardModel) -> LCDCell {
        let value: String
        let caption: String
        switch tape.status {
        case .running:
            value = board.slots.first { $0.state == .live }?.duration.map(BoardModel.clock) ?? "—"
            caption = "elapsed"
        case .failed:
            value = board.inTheAir.value
            caption = "halted"
        case .reachedReview:
            value = board.inTheAir.value
            caption = "total"
        case .idle, .paused, .stopped:
            value = board.inTheAir.value
            caption = tape.status == .stopped ? "stopped" : "paused"
        }
        return LCDCell(kind: .elapsed, value: value, shortValue: value, caption: caption, tone: .normal)
    }

    /// Agents done over agents in the round — one of the few honest fractions (spec §2). A
    /// failed seat has finished too; it counts, and its row says how.
    private static func seatsDone(_ seats: [SeatRowModel]) -> LCDCell {
        let done = seats.filter { $0.glyph == .done || $0.glyph == .failed }.count
        let value = seats.isEmpty ? "—" : "\(done)/\(seats.count)"
        return LCDCell(kind: .seatsDone, value: value, shortValue: value, caption: "agents done", tone: .normal)
    }

    /// Lines the rounds have changed in the plan so far. The draft is left out: it wrote the
    /// plan from nothing, and its hundreds of added lines would drown every change after it.
    /// On a failed tape the cell carries the diagnosis instead (spec §4), since a failure makes
    /// the churn beside the point.
    private static func soFar(tape: Tape) -> LCDCell {
        if tape.status == .failed {
            let detail = tape.pauseDiagnosis?.detail ?? "Round failed"
            return LCDCell(kind: .soFar, value: detail, shortValue: tape.pauseDiagnosis.map { code($0.category) } ?? "FAILED",
                           caption: "failed", tone: .red)
        }
        let changed = tape.checkpoints.filter { $0.stage != .draft }
        let added = changed.map(\.record.linesAdded).reduce(0, +)
        let removed = changed.map(\.record.linesRemoved).reduce(0, +)
        let value = "+\(added) −\(removed)"
        return LCDCell(kind: .soFar, value: value, shortValue: value, caption: "so far", tone: .normal)
    }

    /// What the round's finished seats say they cost. `SeatRowModel.cost` is set only once a
    /// seat finishes, and only claude states one, so this is what has been billed — never a
    /// live estimate (spec §2), and a dash when no seat has said.
    private static func billed(_ seats: [SeatRowModel]) -> LCDCell {
        let costs = seats.filter { $0.glyph == .done || $0.glyph == .failed }.compactMap(\.cost)
        let value = costs.isEmpty ? "—" : String(format: "$%.2f", costs.reduce(0, +))
        return LCDCell(kind: .billed, value: value, shortValue: value, caption: "billed", tone: .normal)
    }

    // MARK: - Words

    static func modeName(_ mode: PlayMode) -> String {
        switch mode {
        case .step: "step"
        case .nextMajor: "next major"
        case .toReview: "to review"
        }
    }

    /// "↘ 5" for "CONVERGING ↘" with 5 changes: what a squeezed CONVERGENCE cell shows. A state
    /// word is never cut short — "CONV" and "DIVE" read as other words — so the fallback is the
    /// word's own arrow and the count, with the whole word on the flap card and in the
    /// accessibility label. "TOO EARLY" has no arrow, so it falls back to the count alone.
    private static func arrowAndCount(_ word: String, latest: Int) -> String {
        let arrows: Set<Character> = ["↘", "→", "↗", "↓", "↑"]
        guard let arrow = word.last(where: { arrows.contains($0) }) else { return "\(latest)" }
        return "\(arrow) \(latest)"
    }

    private static func code(_ category: DiagnosisCategory) -> String {
        switch category {
        case .rateLimited: "RATE LIMIT"
        case .authExpired: "SIGN IN"
        case .timeout: "TIMEOUT"
        case .harnessError: "ERROR"
        case .invalidOutput: "BAD OUTPUT"
        }
    }
}

/// A pause or stop the human sent, by its command sequence number. The control bar says
/// "Pausing…"/"Stopping…" until the runner acknowledges it (`tape.ackedCommandSeq`), because
/// the runner only halts at a safe point and the button must not look like it did nothing.
struct HaltRequest: Equatable {
    enum Kind: Equatable { case pause, stop }
    let kind: Kind
    let seq: Int

    /// Nil once acknowledged. A pause only waits on a running tape: with no runner nothing
    /// reads it until the next play (which supersedes it), so "Pausing…" would never end. A
    /// stop always has a reader — `IntakeService.send` starts a runner to consume it.
    func label(for tape: Tape) -> String? {
        guard tape.ackedCommandSeq < seq else { return nil }
        switch kind {
        case .pause: return tape.status == .running ? "Pausing…" : nil
        case .stop: return "Stopping…"
        }
    }
}
