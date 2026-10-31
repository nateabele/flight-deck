import AppKit
import IntakeKit
import SwiftUI

/// A proposed edit in the plan as the gutter-bar style draws it (D17, option B): at rest a 3 pt
/// green bar in the margin beside the passage and a small ✦ after it; under the pointer a card
/// with the old text struck through above the new, and ✓ Accept, ✗, Edit and ✦. No header bar,
/// whatever the diff's size.
///
/// **The editor keeps the text it has.** The bar marks the passage the diff would replace, where
/// that passage is in the text on screen; the proposed words appear in the hover card, not in the
/// text. Swapping them into the text view would make the editor show characters the plan does not
/// contain, and a keystroke on them would edit a version that does not exist.
enum DiffGutterStyle {
    static let barWidth: CGFloat = 3
    static let green = NSColor.systemGreen
    /// The ✦ after the passage.
    static let spark = "✦"
    static let sparkColor = NSColor.controlAccentColor
}

/// Draws the bars and sparks under the text view's own subviews, taking no clicks. Like
/// `NoteBandView`, a subview of the text view, so it scrolls with the text; line rects are measured
/// while drawing for the same reason (a layout done at load came from TextKit's first estimate).
final class DiffGutterView: NSView {
    struct Mark: Equatable {
        let range: NSRange
        /// The pointer is on it: its card is up, and the bar thickens a touch to say which.
        let hovered: Bool
    }

    var marks: [Mark] = []
    var segments: (NSRange) -> [CGRect] = { _ in [] }
    var viewport: () -> NSRange? = { nil }
    /// The bar's x, in this view's coordinates: the edit lane (`PlanGutter`), so a human's own
    /// edit bars and a proposed one line up in one column.
    var barX: () -> CGFloat = { PlanGutter.span(.edit, churn: false).x }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let viewport = self.viewport()
        for mark in marks {
            if let viewport, NSIntersectionRange(viewport, mark.range).length == 0, mark.range.location != viewport.location { continue }
            let lines = segments(mark.range)
            guard let first = lines.first, let last = lines.last else { continue }
            let bar = CGRect(x: barX(), y: first.minY, width: DiffGutterStyle.barWidth, height: last.maxY - first.minY)
            guard bar.intersects(dirtyRect) || last.insetBy(dx: -24, dy: 0).intersects(dirtyRect) else { continue }
            DiffGutterStyle.green.withAlphaComponent(mark.hovered ? 1 : 0.9).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            // A superscript-ish spark, after the last word: where the eye finishes the passage.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: DiffGutterStyle.sparkColor,
            ]
            (DiffGutterStyle.spark as NSString).draw(at: NSPoint(x: last.maxX + 3, y: last.minY), withAttributes: attributes)
        }
    }
}

/// The hover card: the old text struck through above the new, and the compact toolbar.
struct DiffHoverCard: View {
    let diff: ThreadDiff
    let accept: () -> Void
    let reject: () -> Void
    let edit: () -> Void
    let openThread: () -> Void
    /// Reports the pointer entering or leaving the card, so the controller keeps it up while the
    /// pointer is on it, though the text view no longer sees the pointer.
    let hovering: (Bool) -> Void
    /// From the card's leading edge to the plan's text, so the words line up with the paragraph.
    var textInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                Button(action: accept) { Text("✓ Accept").fontWeight(.semibold).foregroundStyle(.green) }
                    .help("Apply this edit to the plan")
                Button(action: reject) { Text("✗").foregroundStyle(.red) }
                    .help("Reject this edit")
                Button(action: edit) { Text("Edit").foregroundStyle(.tint) }
                    .help("Put the new text in the plan to change by hand")
                Button(action: openThread) { Text("✦").foregroundStyle(.tint) }
                    .help("Open the thread that proposed this")
            }
            .buttonStyle(ToolbarButtonStyle())
            .font(.system(size: 12))
            .padding(2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
            if !diff.old.isEmpty {
                Text(diff.old)
                    .strikethrough(true, color: .red.opacity(0.6))
                    .foregroundStyle(.red.opacity(0.85))
                    .opacity(0.8)
                    .font(.system(size: 13))
            }
            Text(diff.new)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .padding(.leading, textInset)
        // Opaque, in SwiftUI so it follows the window's appearance (a layer colour is resolved once).
        .background(Color.primary.opacity(0.045))
        .background(Color(nsColor: .windowBackgroundColor))
        // The passage's bar, redrawn: the card hides the gutter's own beneath it.
        .overlay(alignment: .leading) { Rectangle().fill(Color.green).frame(width: DiffGutterStyle.barWidth).padding(.leading, 6).padding(.vertical, 4) }
        .onHover(perform: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diff-hover-card")
    }

    private struct ToolbarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(configuration.isPressed ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
    }
}

/// The editor's side of proposed edits: finds each pending diff's passage, keeps the bars drawn,
/// and shows the hover card. Owned by `PlanNotesBridge`, which hands it the text view's geometry.
@MainActor
final class DiffGutterController {
    private weak var textView: PlanNSTextView?
    let view = DiffGutterView()
    private var diffs: [ThreadDiff] = []
    private(set) var located: [UUID: NSRange] = [:]
    private(set) var shownCard: UUID?
    private var host: NSHostingView<DiffHoverCard>?
    private var overCard = false
    private var hideWork: DispatchWorkItem?

    /// A range's line rects in the text view's coordinates, from the bridge.
    var segments: (NSRange) -> [CGRect] = { _ in [] }
    var viewport: () -> NSRange? = { nil }
    var onDecide: (ThreadDiff, Bool) -> Void = { _, _ in }
    var onEdit: (ThreadDiff, NSRange) -> Void = { _, _ in }
    var onOpenThread: (ThreadID) -> Void = { _ in }

    /// How long the card outlives the pointer leaving the passage: time to cross the gap to it.
    static let linger: TimeInterval = 0.25

    var diffCount: Int { diffs.count }

    func attach(_ textView: PlanNSTextView) {
        self.textView = textView
        view.segments = { [weak self] in self?.segments($0) ?? [] }
        view.viewport = { [weak self] in self?.viewport() }
        view.barX = { [weak textView] in (textView?.textContainerOrigin.x).map { $0 - PlanGutter.textGap - DiffGutterStyle.barWidth } ?? 0 }
    }

    func detach() {
        hideCard()
        view.removeFromSuperview()
        view.marks = []
        diffs = []
        located = [:]
    }

    /// The pending diffs to draw, found in `text`. A diff whose passage is no longer there is not
    /// drawn: it is stale, and the thread's card says so.
    func update(_ next: [ThreadDiff], in text: String) {
        guard let textView else { return }
        diffs = next
        located = Dictionary(uniqueKeysWithValues: next.compactMap { diff in
            diff.anchor.locate(in: text).map { (diff.id, NSRange($0, in: text)) }
        })
        if let shownCard, located[shownCard] == nil { hideCard() }
        if view.superview !== textView { textView.addSubview(view, positioned: .below, relativeTo: nil) }
        if view.frame != textView.bounds { view.frame = textView.bounds }
        redraw()
    }

    func redraw() {
        if let textView, view.superview === textView, view.frame != textView.bounds { view.frame = textView.bounds }
        let marks = diffs.compactMap { diff in located[diff.id].map { DiffGutterView.Mark(range: $0, hovered: diff.id == shownCard) } }
        if marks != view.marks { view.marks = marks }
        view.setNeedsDisplay(view.visibleRect)
    }

    // MARK: Hover

    /// Where the pointer can rest to ask for a diff's card: its lines, widened left to the bar and
    /// right past the spark.
    private func region(of id: UUID) -> [CGRect] {
        guard let range = located[id] else { return [] }
        let barX = view.barX()
        return segments(range).map { line in
            CGRect(x: min(barX - 4, line.minX), y: line.minY, width: max(line.maxX + 24, line.maxX) - min(barX - 4, line.minX), height: line.height)
        }
    }

    /// The pointer moved to `point` (text-view coordinates), nil when it left the text view.
    func hover(at point: NSPoint?) {
        if let point, let hit = diffs.first(where: { region(of: $0.id).contains { $0.contains(point) } }) {
            hideWork?.cancel()
            if shownCard != hit.id { showCard(for: hit) }
        } else if shownCard != nil, !overCard {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.overCard == false { self?.hideCard() } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    func showCard(for diff: ThreadDiff) {
        guard let textView, let range = located[diff.id], let first = segments(range).first else { return }
        hideCard()
        // The text column: from the bar to the trailing margin. The card is as tall as it needs.
        let x = view.barX() - 6
        let width = max(textView.bounds.width - x - PlanGutter.trailingMargin / 2, 160)
        let card = DiffHoverCard(
            diff: diff,
            accept: { [weak self] in self?.decide(diff, accept: true) },
            reject: { [weak self] in self?.decide(diff, accept: false) },
            edit: { [weak self] in self?.edit(diff) },
            openThread: { [weak self] in
                self?.hideCard()
                self?.onOpenThread(diff.thread)
            },
            hovering: { [weak self] inside in
                self?.overCard = inside
                if inside { self?.hideWork?.cancel() } else { self?.scheduleHide() }
            },
            textInset: textView.textContainerOrigin.x - x)
        let host = NSHostingView(rootView: card)
        // `fittingSize` ignores the width, so the height is asked for at the width the card has.
        let height = NSHostingController(rootView: card).sizeThatFits(in: CGSize(width: width, height: 2000)).height
        host.frame = NSRect(x: x, y: first.minY - 2, width: width, height: height)
        host.wantsLayer = true
        // Opaque, over the passage it stands in for: the old text is drawn again inside the card,
        // struck, so showing the editor's own beneath it would print every word twice. The plan's
        // page is the window colour under a faint wash, which the card's SwiftUI side adds.
        host.layer?.cornerRadius = 6
        textView.addSubview(host, positioned: .above, relativeTo: nil)
        self.host = host
        shownCard = diff.id
        redraw()
    }

    func hideCard() {
        hideWork?.cancel()
        host?.removeFromSuperview()
        host = nil
        overCard = false
        if shownCard != nil {
            shownCard = nil
            redraw()
        }
    }

    private func decide(_ diff: ThreadDiff, accept: Bool) {
        hideCard()
        onDecide(diff, accept)
    }

    private func edit(_ diff: ThreadDiff) {
        let range = located[diff.id]
        hideCard()
        if let range { onEdit(diff, range) }
    }
}
