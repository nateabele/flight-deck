import AppKit
import IntakeKit
import SwiftUI

// The three convergence surfaces (spec §8): the LCD cell's sparkline and hover card, the section
// heatmap that opens under the tape, and the plan's churn lane. Each says one thing — whether the
// cycle is settling, which section is not, and where in the plan that section is — and each is
// drawn from the engine's verdict (`ConvergenceCycle`) through the models in
// `ConvergenceCellModel.swift`, so none of them can tell a different story from the others.

private enum Tone {
    static let ph = SplitFlapCard.phosphor
    static let ph2 = ph.opacity(0.66)
    static let ph3 = ph.opacity(0.4)
    static let amber = LCDMetrics.color(.amber)
    static let accent = LCDMetrics.color(.accent)
    static let caption = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
}

// MARK: - Sparkline

/// Changes per round in the current cycle as a phosphor line ending in a lit point (spec §8.1),
/// over the dashed floor the engine calls settled. Where the numbers stop being comparable — the
/// reviewer's model changed, or an Extend added the round — the line breaks into a dotted leg
/// and a tick marks the point, so a drop across a model swap can't read as convergence
/// (Review Focus 5). The card says what the tick was.
struct ConvergenceSparkline: View {
    let points: [Double]
    let tone: LCDCell.Tone
    var discontinuities: [Int] = []
    var floor: Double?

    var body: some View {
        Canvas { context, size in
            guard let top = (points + [floor ?? 0]).max(), top > 0 else { return }
            let step = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0
            let y = { (v: Double) in size.height - 2 - CGFloat(v / top) * (size.height - 4) }
            let at = { (i: Int) in CGPoint(x: points.count > 1 ? CGFloat(i) * step : size.width, y: y(points[i])) }
            let color = LCDMetrics.color(tone)
            if let floor {
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y(floor)))
                rule.addLine(to: CGPoint(x: size.width, y: y(floor)))
                context.stroke(rule, with: .color(Tone.ph.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            for i in discontinuities where i > 0 && i < points.count {
                var tick = Path()
                tick.move(to: CGPoint(x: at(i).x, y: 0))
                tick.addLine(to: CGPoint(x: at(i).x, y: size.height))
                context.stroke(tick, with: .color(Tone.ph.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
            }
            var solid = Path(), dotted = Path()
            if !points.isEmpty { solid.move(to: at(0)) }
            for i in points.indices.dropFirst() {
                if discontinuities.contains(i) {
                    dotted.move(to: at(i - 1))
                    dotted.addLine(to: at(i))
                    solid.move(to: at(i))
                } else {
                    solid.addLine(to: at(i))
                }
            }
            var glow = context
            glow.addFilter(.shadow(color: color.opacity(0.45), radius: 2.5))
            glow.stroke(solid, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            glow.stroke(dotted, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 3]))
            if let last = points.indices.last {
                let p = at(last)
                glow.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
        .frame(width: LCDMetrics.sparkWidth, height: 24)
        .accessibilityHidden(true)
    }
}

// MARK: - Hover card

/// The CONVERGENCE cell's card: the word in flap tiles and the count with the verdict's reason
/// (the board's own card, `SplitFlapCard`, on surface `card.convergence`), then the numbers, any
/// discontinuity, and the suggested action — always "a signal, not a promise".
struct ConvergenceCard: View {
    let model: ConvergenceCellModel
    let policy: FlapPolicy

    private static let width: CGFloat = 340

    var body: some View {
        SplitFlapCard(full: model.word, detail: model.detail, surface: "card.convergence", policy: policy,
                      tint: model.tone == .amber ? Tone.amber : nil, accessory: AnyView(accessory))
    }

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.cardLines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(i == 0 ? Tone.ph.opacity(0.9) : Tone.ph2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let headline = model.actionHeadline {
                Rectangle().fill(Tone.ph.opacity(0.1)).frame(height: 1).padding(.vertical, 4)
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.tone == .amber ? Tone.amber : Tone.ph)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = model.actionDetail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Tone.ph2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Click for the section heatmap · a signal, not a promise")
                .font(.system(size: 11))
                .foregroundStyle(Tone.ph3)
                .padding(.top, 2)
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.top, 4)
    }
}

// MARK: - Heatmap

/// The heatmap is open, at `section` when a churn marker opened it (nil: from the LCD cell).
struct HeatmapFocus: Equatable {
    var section: String?
}

/// The section heatmap (spec §8.3): an inline disclosure in the board's glass, directly under
/// the tape — not a popover, so it survives clicks into the plan and never covers the plan it
/// describes. Rows are sections, columns the cycle's rounds, each column under its own tape
/// slot (`columns`), with the round's proposal count and agreement above it. A cell selects
/// that round and shows the plan's Diff vs Previous at the section; Esc or close shuts it.
struct ConvergenceHeatmap: View {
    let model: HeatmapModel
    let cell: ConvergenceCellModel?
    /// Each round's horizontal extent in this view, given its width: under the round's tape slot.
    /// Nil when the tape is scrolling (its codes don't fit) — the columns then lay out on their own.
    let columns: (CGFloat) -> [ClosedRange<CGFloat>]?
    /// The section a churn marker opened the map at: outlined, so the eye lands on it.
    var focusSection: String?
    var selectedCheckpoint: Int?
    let onSelect: (_ checkpoint: Int, _ section: String?) -> Void
    var onAnnotate: ((String) -> Void)?
    let onClose: () -> Void

    @State private var width: CGFloat = 0
    @FocusState private var focused: Bool

    private enum M {
        static let inset: CGFloat = 18
        static let header: CGFloat = 40
        static let roundRow: CGFloat = 20
        static let countRow: CGFloat = 18
        static let agreeRow: CGFloat = 26
        static let row: CGFloat = 30
        static let cellHeight: CGFloat = 24
        static let bottom: CGFloat = 16
        static let panelMin: CGFloat = 250
        static let nameMin: CGFloat = 170
    }

    private var gridTop: CGFloat { M.header + M.roundRow + M.countRow + M.agreeRow }
    private var gridHeight: CGFloat { gridTop + CGFloat(max(model.sections.count, 1)) * M.row }

    var body: some View {
        let layout = Layout(model: model, width: width, columns: columns(width))
        ZStack(alignment: .topLeading) {
            Color.clear
            header
            grid(layout)
            if let cell { panel(cell, layout: layout) }
        }
        .frame(height: layout.panelBelow ? gridHeight + 150 + M.bottom : gridHeight + M.bottom)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w }
        })
        .environment(\.colorScheme, .dark)
        // Esc closes it (spec §8.3). Focus is taken when it opens so Esc works at once; the ring
        // would outline the whole map, which the cells' own rings already cover.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onExitCommand(perform: onClose)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section churn heatmap")
        .accessibilityIdentifier("convergence-heatmap")
    }

    /// Where everything goes at `width`: the round columns (under the tape's slots when the tape
    /// isn't scrolling and leaves room for the section names, else packed after the names), the
    /// name column before them, and the verdict panel after them — or below, when too narrow.
    private struct Layout {
        var columns: [ClosedRange<CGFloat>]
        var names: ClosedRange<CGFloat>
        var panelBelow: Bool
        var panelX: CGFloat

        init(model: HeatmapModel, width: CGFloat, columns aligned: [ClosedRange<CGFloat>]?) {
            if let aligned, aligned.count == model.rounds.count, let first = aligned.first, first.lowerBound - 12 - M.inset >= M.nameMin {
                columns = aligned.map { ($0.lowerBound + 2)...($0.upperBound - 2) }
            } else {
                let start = M.inset + 230
                columns = model.rounds.indices.map { i in (start + CGFloat(i) * 66)...(start + CGFloat(i) * 66 + 62) }
            }
            names = M.inset...((columns.first?.lowerBound ?? M.inset + 230) - 14)
            let after = (columns.last?.upperBound ?? 0) + 28
            panelBelow = width - M.inset - after < M.panelMin
            panelX = panelBelow ? M.inset : after
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.title)
                .font(Font(Tone.caption))
                .tracking(1.5)
                .foregroundStyle(Tone.ph)
            Text("lines changed per section, per round · click a cell to read that round's diff")
                .font(.system(size: 12))
                .foregroundStyle(Tone.ph3)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Text("close").font(.system(size: 11.5, design: .monospaced))
                    Text("esc")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Tone.ph.opacity(0.1)))
                }
                .foregroundStyle(Tone.ph2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the heatmap (Esc)")
            .accessibilityLabel("Close the heatmap")
        }
        .padding(.horizontal, M.inset)
        .frame(height: M.header)
    }

    // MARK: Grid

    private func grid(_ layout: Layout) -> some View {
        let names = layout.names
        let proposed = model.stage == .refine ? "CHANGES PROPOSED" : "OPS CHANGED"
        return ZStack(alignment: .topLeading) {
            rowCaption(proposed).offset(x: names.lowerBound, y: M.header + M.roundRow)
            if model.agree.contains(where: { $0 != nil }) {
                rowCaption("AGREED").offset(x: names.lowerBound, y: M.header + M.roundRow + M.countRow + 6)
            }
            ForEach(model.rounds.indices, id: \.self) { r in
                roundHeader(r, column: layout.columns[r])
            }
            if model.sections.isEmpty {
                Text("No plan section changed in this cycle.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tone.ph3)
                    .offset(x: names.lowerBound, y: gridTop + 6)
            }
            ForEach(model.sections.indices, id: \.self) { s in
                sectionRow(s, layout: layout)
            }
        }
    }

    private func rowCaption(_ text: String) -> some View {
        Text(text).font(Font(Tone.caption)).tracking(1.5).foregroundStyle(Tone.ph3).fixedSize()
    }

    private func roundHeader(_ r: Int, column: ClosedRange<CGFloat>) -> some View {
        let w = column.upperBound - column.lowerBound
        let agree = model.agree[r]
        let fell = r > 0 && agree != nil && model.agree[r - 1] != nil
            && model.agree[r - 1]! - agree! >= ConvergenceThresholds.default.agreeDrop
        return VStack(spacing: 0) {
            Text(model.rounds[r])
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Tone.ph)
                .frame(height: M.roundRow)
            Text("\(model.counts[r])")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Tone.ph3)
                .frame(height: M.countRow)
            if let agree {
                VStack(spacing: 3) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tone.ph.opacity(0.12))
                        Capsule().fill(fell ? Tone.amber : Tone.ph2).frame(width: max(2, (w - 20) * agree))
                    }
                    .frame(width: w - 20, height: 3)
                    Text("\(Int((agree * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(fell ? Tone.amber : Tone.ph2)
                }
                .frame(height: M.agreeRow)
            }
        }
        .frame(width: w)
        .offset(x: column.lowerBound, y: M.header)
        .accessibilityElement(children: .combine)
    }

    private func sectionRow(_ s: Int, layout: Layout) -> some View {
        let section = model.sections[s]
        let y = gridTop + CGFloat(s) * M.row
        let hot = model.hot.contains(section)
        let span = (layout.columns.first!.lowerBound - 4)...(layout.columns.last!.upperBound + 4)
        return ZStack(alignment: .topLeading) {
            // The caption goes before the name is cut short: the row's cells and the churn lane
            // both say it again, and "Dispatch ru…" names nothing.
            ViewThatFits(in: .horizontal) {
                nameRow(s, hot: hot, caption: model.captions[s])
                nameRow(s, hot: hot, caption: nil)
            }
            .frame(width: layout.names.upperBound - layout.names.lowerBound, height: M.cellHeight)
            .offset(x: layout.names.lowerBound, y: y)

            if hot || section == focusSection {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hot ? Tone.amber : Tone.accent, lineWidth: 1.5)
                    .shadow(color: (hot ? Tone.amber : Tone.accent).opacity(0.35), radius: 5)
                    .frame(width: span.upperBound - span.lowerBound, height: M.cellHeight + 6)
                    .offset(x: span.lowerBound, y: y - 3)
            }
            ForEach(model.rounds.indices, id: \.self) { r in
                heatCell(section: s, round: r, column: layout.columns[r]).offset(x: layout.columns[r].lowerBound, y: y)
            }
        }
    }

    private func nameRow(_ s: Int, hot: Bool, caption: String?) -> some View {
        HStack(spacing: 8) {
            Text(model.labels[s])
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(hot ? Tone.amber : Tone.ph3)
                .frame(width: 30, alignment: .leading)
            Text(model.names[s]).font(.system(size: 13)).foregroundStyle(hot ? Tone.amber : Tone.ph).lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if let caption {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(hot ? Tone.amber : Tone.ph3).lineLimit(1).fixedSize()
            }
        }
    }

    private func heatCell(section s: Int, round r: Int, column: ClosedRange<CGFloat>) -> some View {
        let lines = model.lines[s][r]
        let lum = model.cells[s][r]
        let checkpoint = model.checkpoints[r]
        let selected = checkpoint == selectedCheckpoint && model.sections[s] == focusSection
        let shape = RoundedRectangle(cornerRadius: 5)
        return Button { onSelect(checkpoint, model.sections[s]) } label: {
            ZStack {
                if lines == 0 {
                    shape.strokeBorder(Tone.ph.opacity(0.08), lineWidth: 1)
                    Text("·").font(.system(size: 12, weight: .bold)).foregroundStyle(Tone.ph3)
                } else {
                    shape.fill(Tone.ph.opacity(0.07 + 0.6 * lum))
                    Text("\(lines)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(lum > 0.55 ? Color(white: 0.08) : Tone.ph)
                }
                if selected { shape.strokeBorder(Tone.accent, lineWidth: 1.5) }
            }
            .frame(width: column.upperBound - column.lowerBound, height: M.cellHeight)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("\(model.labels[s]) in \(model.rounds[r]): \(lines) line\(lines == 1 ? "" : "s") changed · show the diff")
        .accessibilityLabel("\(model.labels[s]) \(model.names[s]), \(model.rounds[r]): \(lines) lines changed")
    }

    // MARK: Verdict panel

    private func panel(_ cell: ConvergenceCellModel, layout: Layout) -> some View {
        let amber = cell.tone == .amber
        let hot = cell.hotSection.map(HeatmapModel.label)
        let panelWidth = max(M.panelMin, width - M.inset - layout.panelX)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(cell.word)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(amber ? Tone.amber : Tone.ph)
                Text(cell.detail.components(separatedBy: " · ").dropFirst().joined(separator: " · ").uppercased())
                    .font(Font(Tone.caption))
                    .tracking(1.5)
                    .foregroundStyle(Tone.ph2)
            }
            if let series = cell.cardLines.first {
                Text(series).font(.system(size: 12.5)).foregroundStyle(Tone.ph2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(cell.cardLines.dropFirst(2).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(Tone.ph3).fixedSize(horizontal: false, vertical: true)
            }
            if let headline = cell.actionHeadline {
                Text(headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(amber ? Tone.amber : Tone.ph)
                    .padding(.top, 4)
                if let detail = cell.actionDetail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Tone.ph2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if let section = cell.hotSection, let hot, let last = model.checkpoints.last {
                    Button("Review \(hot) Diffs") { onSelect(last, section) }
                    if let onAnnotate { Button("Annotate \(hot)…") { onAnnotate(section) } }
                }
                Text("a signal, not a promise").font(.system(size: 11)).foregroundStyle(Tone.ph3)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        // Beside the grid, behind a hairline; below it when the pane is too narrow for both.
        .frame(width: panelWidth - (layout.panelBelow ? 0 : 20), alignment: .leading)
        .padding(.leading, layout.panelBelow ? 0 : 20)
        .overlay(alignment: .leading) {
            if !layout.panelBelow { Rectangle().fill(Tone.ph.opacity(0.08)).frame(width: 1) }
        }
        .offset(x: layout.panelX, y: layout.panelBelow ? gridHeight + 8 : M.header + 4)
    }
}

// MARK: - Churn lane

/// What the plan's churn lane needs from its owner: the cycle it describes, how to read a
/// section's proposals round by round (for the amber marker's hover), and what a click does —
/// open the heatmap at that section.
struct ChurnLaneInput {
    let cycle: ConvergenceCycle
    let versions: (String) -> [SectionVersion]
    let onOpen: (String) -> Void
}

/// The plan's churn lane (spec §8.2): beside each heading the cycle changed, a quiet caption and
/// one small bar per round; amber, with a rule down the section's length, for the section the
/// verdict names. Hovering an amber marker lists that section's proposals per round; clicking any
/// marker opens the heatmap at its section.
///
/// It is the plan gutter's CHURN column (`PlanGutter`): a subview of the text view, so it
/// scrolls with the text, spanning the document's height at the column's x. It finds each
/// heading's line with TextKit 2, redraws as the text reflows or changes, and reports through
/// `onShown` whether it has anything to mark — the column opens and closes on that.
final class ChurnLaneView: NSView {
    static let width: CGFloat = 132
    /// Whether any heading has a marker — the text view opens the CHURN column for it.
    var onShown: ((Bool) -> Void)?

    private weak var textView: NSTextView?
    private var input: ChurnLaneInput?
    private var markers: [Marker] = []
    /// UTF-16 offsets of every heading line, so a marked section's rule ends at the next heading.
    private var headingOffsets: [Int] = []
    /// What the markers were last found from, so a view update that changed neither doesn't
    /// rescan the plan (the pane re-renders on every service publish, about once a second).
    private var scanned: (text: String, cycle: ConvergenceCycle?)?
    private var hovered: String?
    private let card = FloatingCardAnchor()
    private var observers: [NSObjectProtocol] = []

    private struct Marker {
        let section: String
        let offset: Int
        let model: ChurnLaneModel
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        // Off by default since macOS 14: a marker must never draw outside its own column.
        clipsToBounds = true
        autoresizingMask = [.height]
        addSubview(card)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Section churn")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Moves into `textView`'s CHURN column and follows its reflow and edits.
    func attach(to textView: NSTextView) {
        guard textView !== self.textView else { return }
        self.textView = textView
        textView.addSubview(self)
        let column = PlanGutter.span(.churn, churn: true)
        frame = NSRect(x: column.x, y: 0, width: column.width, height: textView.bounds.height)
        observers.forEach(NotificationCenter.default.removeObserver)
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.needsDisplay = true } }
        let edited: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.reread() } }
        let center = NotificationCenter.default
        textView.postsFrameChangedNotifications = true
        observers = [
            center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: nil, using: redraw),
            center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil, using: edited),
        ]
        reread()
    }

    /// Clicks outside a marker belong to the text view (a click in the margin places the caret).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, marker(at: convert(point, from: superview)) != nil else { return nil }
        return super.hitTest(point)
    }

    /// New input from the view update; nil hides the lane.
    func update(_ input: ChurnLaneInput?) {
        self.input = input
        guard scanned?.text != textView?.string || scanned?.cycle != input?.cycle else { return }
        reread()
    }

    /// The headings the cycle changed, found in the text as it is now. Keys match
    /// `PlanMetrics`'s: a heading line, trimmed.
    private func reread() {
        let text = textView?.string ?? ""
        scanned = (text, input?.cycle)
        var offsets: [Int] = []
        var found: [Marker] = []
        let ns = text as NSString
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("#") {
                offsets.append(line.location)
                if let input {
                    let model = ChurnLaneModel(cycle: input.cycle, section: content)
                    if !model.isEmpty { found.append(Marker(section: content, offset: line.location, model: model)) }
                }
            }
            location = NSMaxRange(line)
        }
        headingOffsets = offsets
        markers = found
        isHidden = found.isEmpty
        onShown?(!found.isEmpty)
        needsDisplay = true
        setAccessibilityChildren(found.map { MarkerElement(marker: $0, lane: self) })
    }

    /// A heading line's rect in this view, from the text view's TextKit 2 layout.
    private func lineRect(at offset: Int) -> NSRect? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        var frame: CGRect?
        layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            frame = fragment.layoutFragmentFrame
            return false
        }
        guard let frame else { return nil }
        let origin = textView.textContainerOrigin
        return convert(frame.offsetBy(dx: origin.x, dy: origin.y), from: textView)
    }

    private func markerRects() -> [(Marker, NSRect)] {
        markers.compactMap { m in lineRect(at: m.offset).map { (m, NSRect(x: 0, y: $0.minY, width: bounds.width, height: $0.height)) } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let amber = NSColor(LCDMetrics.color(.amber))
        let barsRight = bounds.width - 12
        for (marker, rect) in markerRects() where rect.intersects(dirtyRect.insetBy(dx: 0, dy: -24)) {
            let model = marker.model
            let hot = model.hot
            let baseline = rect.midY + 6
            // One bar per round, bottom-aligned; a round that left the section alone is a dash.
            let barsWidth = CGFloat(model.bars.count) * 6 - 2
            for (i, bar) in model.bars.enumerated() {
                let x = barsRight - barsWidth + CGFloat(i) * 6
                let color = hot ? amber : NSColor.secondaryLabelColor
                if bar == 0 {
                    NSColor.quaternaryLabelColor.setFill()
                    NSRect(x: x, y: baseline - 1.5, width: 4, height: 1.5).fill()
                } else {
                    color.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: baseline - max(3, 14 * bar), width: 4, height: max(3, 14 * bar)),
                                 xRadius: 1, yRadius: 1).fill()
                }
            }
            if let caption = model.caption {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: hot ? .semibold : .regular),
                    .foregroundColor: hot ? amber : (marker.section == hovered ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor),
                ]
                let size = (caption as NSString).size(withAttributes: attributes)
                (caption as NSString).draw(at: NSPoint(x: barsRight - barsWidth - 8 - size.width, y: baseline - size.height + 2),
                                           withAttributes: attributes)
            }
            if hot {
                // The section the verdict names: a rule down its whole length, to the next heading.
                let end = headingOffsets.first { $0 > marker.offset }.flatMap(lineRect(at:))?.minY
                    ?? (textView.map { convert($0.bounds, from: $0).maxY } ?? rect.maxY)
                amber.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: bounds.width - 4, y: rect.minY + 2, width: 2, height: max(rect.height, end - rect.minY - 8)),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    // MARK: Pointer

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func marker(at point: NSPoint) -> (Marker, NSRect)? {
        markerRects().first { $0.1.insetBy(dx: 0, dy: -3).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        hover(marker(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { hover(nil) }

    override func mouseDown(with event: NSEvent) {
        guard let (marker, _) = marker(at: convert(event.locationInWindow, from: nil)) else { return }
        hover(nil)
        input?.onOpen(marker.section)
    }

    /// The versions card only for an amber marker (spec §8.2): a quiet section has nothing to
    /// explain, and a card on every heading would be noise.
    /// Opens `section`'s versions card as a hover would — for offscreen renders, which can't hover.
    func presentVersions(for section: String) {
        hover(markerRects().first { $0.0.section == section })
    }

    private func hover(_ hit: (Marker, NSRect)?) {
        let section = hit?.0.section
        if section != hovered {
            hovered = section
            needsDisplay = true
        }
        (hit == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        guard let (marker, rect) = hit, marker.model.hot, let input else { return card.present(nil) }
        // Beside the marker, off the gutter's trailing edge and top-aligned with the heading —
        // below it, the card sat over the very section it explains.
        card.placement = .trailing
        card.frame = rect
        card.present(AnyView(SectionVersionsCard(section: marker.section, model: marker.model,
                                                 versions: input.versions(marker.section)).fixedSize()))
    }

    /// One marker for VoiceOver: its section and caption, pressable like a click.
    private final class MarkerElement: NSAccessibilityElement {
        private let section: String
        private weak var lane: ChurnLaneView?

        init(marker: Marker, lane: ChurnLaneView) {
            section = marker.section
            self.lane = lane
            super.init()
            setAccessibilityRole(.button)
            let label = HeatmapModel.label(marker.section) + " " + HeatmapModel.name(marker.section)
            setAccessibilityLabel("\(label): \(marker.model.caption ?? "changed"). Opens the section heatmap.")
            setAccessibilityParent(lane)
        }

        override func accessibilityFrame() -> NSRect {
            guard let lane, let rect = lane.markerRects().first(where: { $0.0.section == section })?.1,
                  let window = lane.window else { return .zero }
            return window.convertToScreen(lane.convert(rect, to: nil))
        }

        override func accessibilityPerformPress() -> Bool {
            lane?.input?.onOpen(section)
            return lane != nil
        }
    }
}

/// The amber marker's hover: what the reviewer proposed for the section, round by round, with
/// the integrator's verdict — the evidence behind "keeps changing".
struct SectionVersionsCard: View {
    let section: String
    let model: ChurnLaneModel
    let versions: [SectionVersion]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(HeatmapModel.label(section)) keeps changing").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tone.ph)
                Text(model.caption.map { $0.hasPrefix("changed") ? $0 + " rounds" : $0 } ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(Tone.amber)
            }
            if versions.isEmpty {
                Text("The reviewers' proposals for this section weren't kept for these rounds.")
                    .font(.system(size: 12)).foregroundStyle(Tone.ph3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(versions.enumerated()), id: \.offset) { i, version in
                if i > 0 { Rectangle().fill(Tone.ph.opacity(0.08)).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(version.round).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Tone.ph3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.text).font(.system(size: 12)).foregroundStyle(Tone.ph2).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        if let verdict = version.verdict {
                            Text(Self.word(verdict)).font(.system(size: 10.5)).foregroundStyle(Tone.ph3)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [Color(red: 0.102, green: 0.118, blue: 0.145), Color(red: 0.059, green: 0.071, blue: 0.086)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Tone.ph.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 17, y: 14)
        )
        .environment(\.colorScheme, .dark)
    }

    private static func word(_ verdict: Verdict) -> String {
        switch verdict {
        case .agree: "integrator agreed"
        case .somewhat: "integrator partly agreed"
        case .disagree: "integrator declined"
        }
    }
}
