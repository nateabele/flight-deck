import AppKit
import IntakeKit
import SwiftUI

/// The Logic-style control bar at the top of the shaping live card (spec §4): the transport in
/// three clusters (Back · Pause | Step · Next major · To review | Stop), the LCD, and the round
/// tools (Extend, Annotate) on the trailing edge.
///
/// It draws; it doesn't tick. The caller rebuilds `lcd` (and the board's model, with the same
/// `preview`) on its 1 Hz clock, so the bar and the board below can never read different times
/// or different stops.
struct ControlBar: View {
    let lcd: LCDModel
    /// The cell's sparkline; its words are already in `lcd`.
    let convergence: ConvergenceCellModel?
    let actions: PlanningActions
    let status: RunnerStatus
    let defaultPlay: PlayMode
    /// "Pausing…"/"Stopping…" while a halt is unacknowledged (`HaltRequest.label`).
    let halting: String?
    let policy: FlapPolicy
    /// Shared with `DeparturesBoard`: hovering a play button previews its stop on both.
    @Binding var preview: PlayMode?
    /// Clicking a play button also makes it the default (spec §4) — `IntakeService.setDefaultPlay`.
    let setDefaultPlay: (PlayMode) -> Void
    /// "Back to the last checkpoint". The contract: the caller (the detail pane) passes a
    /// closure that moves the plan viewer's selection back one checkpoint, and passes nil when
    /// there is nowhere to go back to — before the first checkpoint lands, or with the first
    /// one already selected — which dims the key. It never moves the tape: the engine has no
    /// rewind (that needs branching), so Back is navigation, not a transport command.
    var onBack: (() -> Void)?
    /// What the next round is sent of the human's — "Sends your 3 edits and 4 notes"
    /// (`NotesRailModel.summary`) — added to every play key's tooltip, since any of them starts
    /// that round. Nil when there is nothing to send.
    var nextRound: String?

    static let barHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let lcdWidth = geo.size.width - Metrics.chrome - transportWidth - Metrics.toolsWidth
            let shown = lcd.visible(width: lcdWidth, cellWidth: LCDMetrics.cellWidth)
            let compact = LCDModel.isCompact(shown)
            HStack(spacing: Metrics.gap) {
                transport
                LCDView(cells: shown, widths: LCDMetrics.widths(shown, available: lcdWidth),
                        convergence: convergence, stopMode: lcd.stopMode, policy: policy)
                tools(compact: compact)
            }
            .padding(.horizontal, Metrics.padding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.barHeight)
        // A button that goes dark under the pointer gets no exit hover, so its preview would
        // otherwise outlive it.
        .onChange(of: actions.enabled) {
            if let preview, !actions.enabled.contains(button(for: preview)) { self.preview = nil }
        }
        .background(
            LinearGradient(colors: [Color(white: 0.184), Color(white: 0.165)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }
        )
    }

    // MARK: - Transport

    private var transport: some View {
        Cluster {
            TransportKey(glyph: .symbol("backward.end.fill"), help: "Back to the last checkpoint",
                         enabled: onBack != nil) { onBack?() }
            haltable(.pause) {
                // Pressed-in while the tape isn't moving; clicking it then resumes with the
                // default play, as Logic's pause does.
                TransportKey(glyph: .symbol("pause.fill"), help: status == .running ? "Pause after this round (⇧⌘.)" : "Paused · resume with the default play",
                             enabled: status == .running ? actions.enabled.contains(.pause) : actions.enabled.contains(button(for: defaultPlay)),
                             on: status != .running) {
                    status == .running ? actions.perform(.pause) : play(defaultPlay)
                }
            }
            ClusterStyle.separator
            playKey(.step, glyph: .symbol("forward.end.fill"), help: "Step: run to the next checkpoint (⌘')")
            playKey(.nextMajor, glyph: .symbol("forward.end.alt.fill"), help: "Next major: run to the next major checkpoint (⇧⌘')")
            playKey(.toReview, glyph: .toReview, help: "To review: run every remaining round (⌥⌘')")
            ClusterStyle.separator
            haltable(.stop) {
                TransportKey(glyph: .symbol("stop.fill"), help: "Stop the run (⌘.)",
                             enabled: actions.enabled.contains(.stop)) { actions.perform(.stop) }
            }
        }
    }

    /// Swaps the pause or stop key for an inline spinner and its "…ing" word until the runner
    /// reaches a safe point — the one control the human just pressed, so it can't look inert.
    @ViewBuilder
    private func haltable(_ button: TransportButton, @ViewBuilder key: () -> some View) -> some View {
        if let halting, halting.hasPrefix(button == .pause ? "Pausing" : "Stopping") {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(halting).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Metrics.keyHeight)
            .accessibilityElement(children: .combine)
        } else {
            key()
        }
    }

    private func playKey(_ mode: PlayMode, glyph: TransportKey.Glyph, help: String) -> some View {
        TransportKey(glyph: glyph, help: nextRound.map { "\(help) · \($0)" } ?? help, enabled: actions.enabled.contains(button(for: mode)),
                     defaultMark: mode == defaultPlay) { play(mode) }
            .onHover { inside in
                preview = Self.hoverPreview(mode: mode, inside: inside, enabled: actions.enabled.contains(button(for: mode)),
                                            current: preview)
            }
    }

    /// The preview after the pointer enters or leaves `mode`'s key. A dark key previews
    /// nothing: it can't be pressed, so showing where it would stop is a promise the bar can't
    /// keep. Leaving clears only the preview this key set, never a neighbour's.
    static func hoverPreview(mode: PlayMode, inside: Bool, enabled: Bool, current: PlayMode?) -> PlayMode? {
        if inside && enabled { return mode }
        return current == mode ? nil : current
    }

    private func play(_ mode: PlayMode) {
        let button = button(for: mode)
        guard actions.enabled.contains(button) else { return }
        actions.perform(button)
        if mode != defaultPlay { setDefaultPlay(mode) }
    }

    private func button(for mode: PlayMode) -> TransportButton {
        switch mode {
        case .step: .step
        case .nextMajor: .nextMajor
        case .toReview: .toReview
        }
    }

    /// Room the transport takes, for the LCD's width budget. A halting key is wider than the
    /// glyph it replaces; measured, like every other fit here.
    private var transportWidth: CGFloat {
        let extra = halting.map { LabelFit.measureWith(.systemFont(ofSize: 12, weight: .medium))($0) + 42 - Metrics.keyWidth } ?? 0
        return 6 * Metrics.keyWidth + 2 * ClusterStyle.separatorWidth + 2 * ClusterStyle.inset + extra
    }

    // MARK: - Round tools

    @ViewBuilder
    private func tools(compact: Bool) -> some View {
        if compact {
            // The narrow pane gives the LCD this room; both tools stay one click away, and
            // keep their Run-menu chords.
            Menu {
                Button("Extend the Current Cycle") { actions.perform(.extend) }.disabled(!actions.enabled.contains(.extend))
                Button("Annotate") { actions.perform(.annotate) }.disabled(!actions.enabled.contains(.annotate))
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Metrics.keyWidth, height: Metrics.keyHeight)
            .padding(ClusterStyle.inset)
            .background(ClusterStyle.background)
            .help("Extend, Annotate")
        } else {
            Cluster {
                TransportKey(glyph: .symbol("arrow.clockwise.circle"), help: "Extend the current cycle by a round (⌘=)",
                             enabled: actions.enabled.contains(.extend)) { actions.perform(.extend) }
                TransportKey(glyph: .symbol("pencil"), help: "Annotate (⌥⌘A)",
                             enabled: actions.enabled.contains(.annotate)) { actions.perform(.annotate) }
            }
        }
    }

    private enum Metrics {
        static let keyWidth: CGFloat = 36
        static let keyHeight: CGFloat = 34
        static let gap: CGFloat = 10
        static let padding: CGFloat = 12
        static var toolsWidth: CGFloat { 2 * keyWidth + 2 * ClusterStyle.inset }
        /// Padding on both ends plus the two gaps between the three parts.
        static var chrome: CGFloat { 2 * padding + 2 * gap }
    }
}

// MARK: - Transport parts

/// A rounded well holding a run of keys, like Logic's transport.
private struct Cluster<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(ClusterStyle.inset)
            .background(ClusterStyle.background)
    }
}

private enum ClusterStyle {
    static let inset: CGFloat = 4
    /// The separator's 1 pt rule plus its padding either side.
    static let separatorWidth: CGFloat = 9

    static var separator: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    static var background: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(Color.black.opacity(0.24))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// One transport key: a glyph, pressed-in when `on`, with the accent dot under it when it's
/// the default play mode.
private struct TransportKey: View {
    enum Glyph {
        case symbol(String)
        /// ▶▶◇ — there's no SF Symbol for "run to review", so it's drawn from two.
        case toReview
    }

    let glyph: Glyph
    let help: String
    let enabled: Bool
    var on = false
    var defaultMark = false
    let action: () -> Void

    @State private var hovering = false

    init(glyph: Glyph, help: String, enabled: Bool, on: Bool = false, defaultMark: Bool = false,
         action: @escaping () -> Void) {
        self.glyph = glyph
        self.help = help
        self.enabled = enabled
        self.on = on
        self.defaultMark = defaultMark
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
                .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.25))
                .frame(width: 36, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
                .overlay(alignment: .bottom) {
                    if defaultMark {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var fill: Color {
        if on { return Color.white.opacity(0.15) }
        return hovering && enabled ? Color.white.opacity(0.09) : .clear
    }

    @ViewBuilder
    private var icon: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 16, weight: .semibold))
        case .toReview:
            HStack(spacing: 1) {
                Image(systemName: "forward.fill").font(.system(size: 14, weight: .semibold))
                Image(systemName: "diamond.fill").font(.system(size: 7, weight: .bold))
            }
        }
    }
}

// MARK: - LCD

/// The LCD's fonts and the one measure `LCDModel.visible` is given — the width a cell takes at
/// its FULL value, so cells leave before any value abbreviates.
enum LCDMetrics {
    static let phosphor = SplitFlapCard.phosphor
    static let valueNS = NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
    static let clockNS = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .medium)
    static let captionNS = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let captionTracking: CGFloat = 1.1
    static let cellPadding: CGFloat = 12
    static let sparkWidth: CGFloat = 54
    static let lcdHeight: CGFloat = 58

    static func isClock(_ kind: LCDCell.Kind) -> Bool {
        switch kind {
        case .elapsed: true
        case .round, .seatsDone, .soFar, .billed, .convergence, .stopsAt: false
        }
    }

    static func valueFont(_ kind: LCDCell.Kind) -> NSFont { isClock(kind) ? clockNS : valueNS }

    static func captionWidth(_ caption: String) -> CGFloat {
        LabelFit.measureWith(captionNS)(caption.uppercased()) + CGFloat(caption.count) * captionTracking
    }

    static func cellWidth(_ cell: LCDCell) -> CGFloat {
        wordWidth(cell) + (cell.kind == .convergence ? sparkWidth + 10 : 0)
    }

    /// The cell with its whole value and caption but no sparkline — the first thing a squeezed
    /// CONVERGENCE cell gives up (`widths`), so its word survives longest.
    static func wordWidth(_ cell: LCDCell) -> CGFloat {
        // `SplitFlapText` keeps 8 pt of breathing room before it calls a name a fit; without it
        // here a cell sized to its name would still be handed its code.
        let breathing: CGFloat = LCDModel.flapSurface(cell.kind) == nil ? 0 : 8
        let value = LabelFit.measureWith(valueFont(cell.kind))(cell.value) + (cell.kind == .stopsAt ? 24 : 0) + breathing
        return ceil(max(value, captionWidth(cell.caption)) + 2 * cellPadding)
    }

    /// The narrowest a cell may be squeezed once the compact set still doesn't fit: a text
    /// value at its code, its caption down to the first word, the sparkline gone. Clocks and
    /// counters never squeeze — a clipped time is worse than a code.
    static func minWidth(_ cell: LCDCell) -> CGFloat {
        guard LCDModel.flapSurface(cell.kind) != nil else { return cellWidth(cell) }
        let value = LabelFit.measureWith(valueNS)(cell.shortValue) + (cell.kind == .stopsAt ? 24 : 0) + 8
        return ceil(max(value, captionWidth(shortCaption(cell))) + 2 * cellPadding)
    }

    /// What a squeezed cell's caption falls back to: "running" for "running · of 3", and
    /// "changes" for CONVERGENCE's "5 changes", whose count its short value already shows.
    static func shortCaption(_ cell: LCDCell) -> String {
        if cell.kind == .convergence {
            return cell.caption.split(separator: " ").dropFirst().joined(separator: " ")
        }
        return cell.caption.components(separatedBy: " · ").first ?? cell.caption
    }

    /// Each visible cell's width in `available` points (less the hairlines between them): its
    /// full width while everything fits, else the text cells give up the overflow in proportion
    /// to how much each can give. `SplitFlapText` then picks name or code for the width it got
    /// — a width, not a breakpoint, so names come back the moment there's room.
    static func widths(_ cells: [LCDCell], available: CGFloat) -> [CGFloat] {
        let full = cells.map(cellWidth)
        let room = available - CGFloat(max(cells.count - 1, 0))
        var widths = full
        var over = full.reduce(0, +) - room
        guard over > 0 else { return full }
        // First the sparkline, and only the sparkline: the convergence word outlives it.
        if let conv = cells.firstIndex(where: { $0.kind == .convergence }) {
            let spark = full[conv] - wordWidth(cells[conv])
            widths[conv] -= min(over, spark)
            over -= min(over, spark)
        }
        guard over > 0 else { return widths }
        let give = zip(widths, cells.map(minWidth)).map { max($0 - $1, 0) }
        let canGive = give.reduce(0, +)
        guard canGive > 0 else { return widths }
        let taken = min(over, canGive)
        return zip(widths, give).map { $0 - $1 / canGive * taken }
    }

    static func color(_ tone: LCDCell.Tone) -> Color {
        switch tone {
        case .normal: phosphor
        case .accent: Color(red: 124 / 255, green: 188 / 255, blue: 1)
        case .amber: Color(red: 1, green: 179 / 255, blue: 64 / 255)
        case .red: Color(red: 1, green: 123 / 255, blue: 114 / 255)
        }
    }
}

/// The dark-glass instrument: phosphor values over small-caps captions, cells divided by
/// hairlines, packed from the leading edge.
private struct LCDView: View {
    let cells: [LCDCell]
    let widths: [CGFloat]
    let convergence: ConvergenceCellModel?
    let stopMode: PlayMode?
    let policy: FlapPolicy

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                LCDCellView(cell: cell, width: widths[index], convergence: cell.kind == .convergence ? convergence : nil,
                            stopMode: stopMode, policy: policy)
                if index < cells.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: LCDMetrics.lcdHeight, maxHeight: LCDMetrics.lcdHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 0.071, green: 0.078, blue: 0.094),
                                              Color(red: 0.051, green: 0.059, blue: 0.071)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}

private struct LCDCellView: View {
    let cell: LCDCell
    let width: CGFloat
    let convergence: ConvergenceCellModel?
    let stopMode: PlayMode?
    let policy: FlapPolicy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            // The sparkline is the first thing a squeezed cell gives up; the word stays.
            if let convergence, width >= LCDMetrics.cellWidth(cell) { Sparkline(points: convergence.spark, tone: cell.tone) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if cell.kind == .stopsAt, let stopGlyph {
                        Image(systemName: stopGlyph).font(.system(size: 13, weight: .bold))
                    }
                    value
                }
                .foregroundStyle(LCDMetrics.color(cell.tone))
                ViewThatFits(in: .horizontal) {
                    caption(cell.caption)
                    caption(LCDMetrics.shortCaption(cell))
                }
                .foregroundStyle(cell.kind == .convergence ? LCDMetrics.color(cell.tone) : LCDMetrics.phosphor.opacity(0.45))
            }
        }
        .padding(.horizontal, LCDMetrics.cellPadding)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        // Full words, never the code (spec §14).
        .accessibilityLabel("\(cell.caption): \(cell.value)")
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Font(LCDMetrics.captionNS))
            .tracking(LCDMetrics.captionTracking)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var value: some View {
        if let surface = LCDModel.flapSurface(cell.kind) {
            // Text values flap once per new text; the policy is keyed on the full value, so a
            // resize that swaps it for its code doesn't replay.
            SplitFlapText(full: cell.value, code: cell.shortValue, surface: surface, policy: policy,
                          font: Font(LCDMetrics.valueNS), nsFont: LCDMetrics.valueNS)
        } else {
            // Clocks and counters never flap: they tick in place with a numeric roll, or a plain
            // swap under Reduce Motion.
            Text(cell.value)
                .font(Font(LCDMetrics.valueFont(cell.kind)))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: cell.value)
        }
    }

    private var stopGlyph: String? {
        stopMode.map { mode in
            switch mode {
        case .step: "forward.end.fill"
        case .nextMajor: "forward.end.alt.fill"
            case .toReview: "forward.fill"
            }
        }
    }
}

/// Changes per round in the current cycle as a phosphor line ending in a lit point (spec §8.1).
/// A minimal drawing: Task 13's cell adds the discontinuity marks and the hover card.
private struct Sparkline: View {
    let points: [Double]
    let tone: LCDCell.Tone

    var body: some View {
        Canvas { context, size in
            guard points.count > 0, let top = points.max(), top > 0 else { return }
            let step = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0
            let at = { (i: Int) in
                CGPoint(x: points.count > 1 ? CGFloat(i) * step : size.width,
                        y: size.height - 2 - CGFloat(points[i] / top) * (size.height - 4))
            }
            var line = Path()
            line.move(to: at(0))
            for i in points.indices.dropFirst() { line.addLine(to: at(i)) }
            let color = LCDMetrics.color(tone)
            context.addFilter(.shadow(color: color.opacity(0.45), radius: 2.5))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            let last = at(points.count - 1)
            context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(color))
        }
        .frame(width: LCDMetrics.sparkWidth, height: 24)
        .accessibilityHidden(true)
    }
}
