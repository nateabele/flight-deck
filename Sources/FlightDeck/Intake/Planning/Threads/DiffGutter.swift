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

/// ✓ Accept, ✗, Edit and ✦: the compact toolbar both hover forms carry.
struct DiffToolbar: View {
    let accept: () -> Void
    let reject: () -> Void
    let edit: () -> Void
    let openThread: () -> Void

    var body: some View {
        HStack(spacing: 2) {
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
        .accessibilityIdentifier("diff-toolbar")
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

/// The hover card for a diff the editor cannot draw in place (a table, a code fence, a passage
/// across blocks): the old text struck through above the new, in the plan's serif, and the toolbar.
/// A paragraph's diff needs none of this: its old text opens above the proposed text itself.
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
            DiffToolbar(accept: accept, reject: reject, edit: edit, openThread: openThread)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !diff.old.isEmpty {
                Text(diff.old)
                    .strikethrough(true, color: .red.opacity(0.6))
                    .foregroundStyle(.red.opacity(0.85))
                    .font(Font(PlanTheme.standard.body))
            }
            Text(diff.new)
                .font(Font(PlanTheme.standard.body))
                .foregroundStyle(.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .padding(.leading, textInset)
        .background(Color.primary.opacity(0.045))
        // Opaque, in SwiftUI so it follows the window's appearance (a layer colour is resolved once).
        .background(Color(nsColor: .windowBackgroundColor))
        // The passage's bar, redrawn: the card hides the gutter's own beneath it.
        .overlay(alignment: .leading) { Rectangle().fill(Color.green).frame(width: DiffGutterStyle.barWidth).padding(.leading, 6).padding(.vertical, 4) }
        .onHover(perform: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diff-hover-card")
    }
}

/// "Accept edited / Cancel": the strip over a passage the human took a proposal into to change by
/// hand (Edit). Accept edited records the plan as it now stands; Cancel undoes the insert.
struct DiffEditStrip: View {
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text("Editing proposal").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 6)
            Button(action: cancel) { Text("Cancel").foregroundStyle(.red) }
                .help("Undo the insert and leave the proposal pending")
            Button(action: accept) { Text("Accept edited").fontWeight(.semibold).foregroundStyle(.green) }
                .help("Apply the plan as it reads now")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .font(.system(size: 12))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
        .fixedSize()
        .accessibilityIdentifier("diff-edit-strip")
    }
}

/// The editor's side of proposed edits: finds each pending diff's passage, keeps the bars drawn for
/// the ones the editor cannot draw in place, and runs the hover and the Edit flow. Owned by
/// `PlanNotesBridge`, which hands it the text view's geometry and the coordinator's proposals.
///
/// A paragraph or list item's diff is drawn by the editor itself (`PlanProposal`): the controller
/// then only opens the room above it under the pointer and floats the toolbar there. Any other
/// diff gets the bar in the margin and a card.
@MainActor
final class DiffGutterController {
    private weak var textView: PlanNSTextView?
    let view = DiffGutterView()
    private var diffs: [ThreadDiff] = []
    private(set) var located: [UUID: NSRange] = [:]
    private(set) var shownCard: UUID?
    private var shownInline = false
    private var host: NSHostingView<DiffHoverCard>?
    private var toolbarHost: NSHostingView<DiffToolbar>?
    private var overCard = false
    private var hideWork: DispatchWorkItem?

    /// The diff being changed by hand, until Accept edited or Cancel (or it goes away).
    ///
    /// `original` is what the passage said before Edit replaced it, and `anchor` is where the
    /// inserted words are now: moved by every edit since (`textEdited`), so Cancel can put the
    /// original back by range, whatever was typed in between, and the strip can sit over the words.
    struct EditSession {
        let diff: ThreadDiff
        let original: String
        var anchor: NSRange
        let checkpoint: Int?
        /// The whole plan before Edit: reading as this again (⌘Z took the insert back out), there
        /// is no edit left to accept.
        let before: String
    }
    private(set) var editing: EditSession?
    private var checkpoint: Int?
    private var stripHost: NSHostingView<DiffEditStrip>?

    /// A range's line rects in the text view's coordinates, from the bridge.
    var segments: (NSRange) -> [CGRect] = { _ in [] }
    var viewport: () -> NSRange? = { nil }
    /// The plan's text as it stands: what Accept edited records.
    var currentText: () -> String = { "" }
    /// The block a diff is drawn in place of, and whether it is drawn now (`PlanTextView.Coordinator`).
    var inlineBlock: (UUID) -> (range: NSRange, drawn: Bool)? = { _ in nil }
    var onHoverProposal: (UUID?) -> Void = { _ in }
    var onDecide: (ThreadDiff, Bool, String?) -> Void = { _, _, _ in }
    /// Puts the proposed words into the plan over `range`, selected.
    var onEdit: (ThreadDiff, NSRange) -> Void = { _, _ in }
    /// Puts `original` back over `range` as one replacement (Cancel).
    var onRestore: (NSRange, String) -> Void = { _, _ in }
    var onOpenThread: (ThreadID) -> Void = { _ in }

    /// How long the card outlives the pointer leaving the passage: time to cross the gap to it.
    static let linger: TimeInterval = 0.25

    var diffCount: Int { diffs.count }

    /// The diffs found in the text, with where: what the editor is asked to draw in place.
    var locatedDiffs: [(diff: ThreadDiff, range: NSRange)] {
        diffs.compactMap { diff in located[diff.id].map { (diff, $0) } }
    }

    func attach(_ textView: PlanNSTextView) {
        self.textView = textView
        view.segments = { [weak self] in self?.segments($0) ?? [] }
        view.viewport = { [weak self] in self?.viewport() }
        view.barX = { [weak textView] in (textView?.textContainerOrigin.x).map { $0 - PlanGutter.textGap - DiffGutterStyle.barWidth } ?? 0 }
    }

    func detach() {
        hideCard()
        finishEdit()
        view.removeFromSuperview()
        view.marks = []
        diffs = []
        located = [:]
    }

    /// The pending diffs to draw, found in `text`. A diff whose passage is no longer there is not
    /// drawn: it is stale, and the thread's card says so.
    func update(_ next: [ThreadDiff], in text: String, checkpoint: Int? = nil) {
        self.checkpoint = checkpoint
        diffs = next
        // The Edit is let go when the plan moved on under it (a round landed), or its diff is no
        // longer pending (resolved, decided elsewhere, withdrawn): its strip would offer to accept
        // something that is no longer there.
        if let session = editing, session.checkpoint != checkpoint || !next.contains(where: { $0.id == session.diff.id }) {
            finishEdit()
        }
        located = Dictionary(uniqueKeysWithValues: next.compactMap { diff in
            diff.anchor.locate(in: text).map { (diff.id, NSRange($0, in: text)) }
        })
        if let shownCard, located[shownCard] == nil { hideCard() }
        if let textView {
            if view.superview !== textView { textView.addSubview(view, positioned: .below, relativeTo: nil) }
            if view.frame != textView.bounds { view.frame = textView.bounds }
        }
        redraw()
    }

    /// Whether the editor draws `id`'s proposal itself right now.
    func isInline(_ id: UUID) -> Bool { inlineBlock(id)?.drawn ?? false }

    func redraw() {
        if let textView, view.superview === textView, view.frame != textView.bounds { view.frame = textView.bounds }
        // Only the diffs the editor does not draw: a proposal drawn in place brings its own bar.
        let marks = diffs.compactMap { diff in
            located[diff.id].flatMap { isInline(diff.id) ? nil : DiffGutterView.Mark(range: $0, hovered: diff.id == shownCard) }
        }
        if marks != view.marks { view.marks = marks }
        view.setNeedsDisplay(view.visibleRect)
        placeToolbar()
        placeStrip()
    }

    // MARK: Hover

    /// Where the pointer can rest to ask for a diff's hover. Drawn in place: the whole block, from
    /// the bar to the trailing edge (its source is hidden, so its lines say only where it is). Else the
    /// passage's lines, widened left to the bar and right past the spark.
    private func region(of id: UUID) -> [CGRect] {
        let barX = view.barX()
        if let block = inlineBlock(id), block.drawn {
            let lines = segments(block.range)
            guard let top = lines.map(\.minY).min(), let bottom = lines.map(\.maxY).max() else { return [] }
            let right = textView?.bounds.width ?? 10_000
            return [CGRect(x: barX - 4, y: top, width: right - barX + 4, height: bottom - top)]
        }
        guard let range = located[id] else { return [] }
        return segments(range).map { line in
            CGRect(x: min(barX - 4, line.minX), y: line.minY, width: max(line.maxX + 24, line.maxX) - min(barX - 4, line.minX), height: line.height)
        }
    }

    /// The pointer moved to `point` (text-view coordinates), nil when it left the text view.
    func hover(at point: NSPoint?) {
        if let point, let hit = diffs.first(where: { region(of: $0.id).contains { $0.contains(point) } }) {
            hideWork?.cancel()
            if shownCard != hit.id { show(hit) }
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

    func show(_ diff: ThreadDiff) {
        hideCard()
        shownCard = diff.id
        if isInline(diff.id) {
            shownInline = true
            onHoverProposal(diff.id)
            showToolbar(for: diff)
        } else {
            showCard(for: diff)
        }
        redraw()
    }

    private func toolbar(for diff: ThreadDiff) -> DiffToolbar {
        DiffToolbar(accept: { [weak self] in self?.decide(diff, accept: true) },
                    reject: { [weak self] in self?.decide(diff, accept: false) },
                    edit: { [weak self] in self?.edit(diff) },
                    openThread: { [weak self] in
                        self?.hideCard()
                        self?.onOpenThread(diff.thread)
                    })
    }

    private func showToolbar(for diff: ThreadDiff) {
        guard let textView else { return }
        let host = NSHostingView(rootView: toolbar(for: diff))
        host.setFrameSize(host.fittingSize)
        textView.addSubview(host, positioned: .above, relativeTo: nil)
        toolbarHost = host
        placeToolbar()
        // The room above the block opens on the next layout: place again once it has.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.placeToolbar() } }
    }

    /// Top-right of the shown block, in the row the proposal keeps for it.
    private func placeToolbar() {
        guard let textView, let toolbarHost, let id = shownCard, let block = inlineBlock(id),
              let first = segments(block.range).first else { return }
        let x = textView.bounds.width - PlanGutter.trailingMargin / 2 - toolbarHost.frame.width
        let origin = NSPoint(x: x, y: first.minY + 2)
        if toolbarHost.frame.origin != origin { toolbarHost.setFrameOrigin(origin) }
    }

    private func showCard(for diff: ThreadDiff) {
        guard let textView, let range = located[diff.id], let first = segments(range).first else { return }
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
        host.layer?.cornerRadius = 6
        textView.addSubview(host, positioned: .above, relativeTo: nil)
        self.host = host
    }

    func hideCard() {
        hideWork?.cancel()
        host?.removeFromSuperview()
        host = nil
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        overCard = false
        if shownInline {
            shownInline = false
            onHoverProposal(nil)
        }
        if shownCard != nil {
            shownCard = nil
            redraw()
        }
    }

    // MARK: Deciding and editing

    func decide(_ diff: ThreadDiff, accept: Bool) {
        hideCard()
        onDecide(diff, accept, nil)
    }

    /// Edit: the proposed words go into the plan, selected, and the strip asks whether to keep them.
    func edit(_ diff: ThreadDiff) {
        let range = located[diff.id]
        hideCard()
        guard let range else { return }
        finishEdit()
        let text = currentText() as NSString
        guard NSMaxRange(range) <= text.length else { return }
        let original = text.substring(with: range)
        onEdit(diff, range)
        // After the insert, so the insert's own edit notification does not move the anchor.
        editing = EditSession(diff: diff, original: original,
                              anchor: NSRange(location: range.location, length: (diff.new as NSString).length), checkpoint: checkpoint,
                              before: text as String)
        showStrip()
    }

    /// Keeps the edited range on the inserted words as the plan changes (the bridge feeds every
    /// character edit here): an edit above moves it, one inside or touching either end grows it.
    ///
    /// Two edits end the session, words left as typed: one that brings the plan back to what it
    /// read before Edit (⌘Z took the insert out — Accept edited would record an unchanged plan),
    /// and one over the passage's edge (a paste half before it, half inside), after which where
    /// the passage starts is a guess — and Cancel, which restores by range, would eat the pasted
    /// words outside it.
    func textEdited(_ edit: TextEdit) {
        guard var session = editing else { return }
        let a = session.anchor
        if edit.range.location >= a.location, edit.oldEnd <= NSMaxRange(a) {
            session.anchor = NSRange(location: a.location, length: max(a.length + edit.delta, 0))
        } else if let moved = edit.shift(a) {
            session.anchor = moved
        } else {
            return finishEdit()
        }
        if currentText() == session.before { return finishEdit() }
        editing = session
        placeStrip()
    }

    /// Accept edited: the plan as it reads now is the accepted edit.
    func acceptEdited() {
        guard let session = editing else { return }
        finishEdit()
        onDecide(session.diff, true, currentText())
    }

    /// Cancel: the passage is put back as it was, by range, as one replacement — however much was
    /// typed since, and without touching whatever else the undo stack holds.
    func cancelEdit() {
        guard let session = editing else { return }
        finishEdit()
        let length = (currentText() as NSString).length
        guard NSMaxRange(session.anchor) <= length else { return }
        onRestore(session.anchor, session.original)
    }

    /// The panel moved to another thread: the Edit on the last one is let go, its words left as typed.
    func panelSwitchedThread() { finishEdit() }

    private func finishEdit() {
        editing = nil
        stripHost?.removeFromSuperview()
        stripHost = nil
    }

    private func showStrip() {
        guard let textView else { return }
        let host = NSHostingView(rootView: DiffEditStrip(accept: { [weak self] in self?.acceptEdited() },
                                                        cancel: { [weak self] in self?.cancelEdit() }))
        host.setFrameSize(host.fittingSize)
        textView.addSubview(host, positioned: .above, relativeTo: nil)
        stripHost = host
        placeStrip()
    }

    /// Above the edited passage, at the trailing edge: over the gap, not over the words.
    private func placeStrip() {
        guard let textView, let stripHost, let session = editing else { return }
        let length = (currentText() as NSString).length
        guard NSMaxRange(session.anchor) <= length, let first = segments(session.anchor).first else { return }
        let origin = NSPoint(x: textView.bounds.width - PlanGutter.trailingMargin / 2 - stripHost.frame.width,
                             y: max(first.minY - stripHost.frame.height - 2, 0))
        if stripHost.frame.origin != origin { stripHost.setFrameOrigin(origin) }
    }
}
