import AppKit
import IntakeKit
import SwiftUI

/// The floating toolbar over a plan selection (spec §7.3): Comment · Question · Must change ·
/// Replace · Delete · Highlight. A kind opens a draft in the notes rail; Highlight (nil) sends
/// an empty comment at once.
struct SelectionToolbar: View {
    let onChoose: (NoteKind?) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(NoteStyle.kinds, id: \.self) { kind in
                Item(title: NoteStyle.label(kind), symbol: NoteStyle.symbol(kind)) { onChoose(kind) }
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 2)
            Item(title: "Highlight", symbol: "highlighter") { onChoose(nil) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.17).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        // The same dark chrome in either appearance, like the board's glass it floats beside.
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotate the selection")
    }

    private struct Item: View {
        let title: String
        let symbol: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(hovering ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .onHover { hovering = $0 }
        }
    }
}

/// The editor's half of the toolbar: an anchor view kept over the selection inside the text
/// view, presenting `SelectionToolbar` through the board's `FloatingCardAnchor` — the same
/// non-activating child panel, closed by the same scroll, resign-key and minimise events.
@MainActor
final class SelectionToolbarPresenter {
    private let anchor: FloatingCardAnchor = {
        let anchor = FloatingCardAnchor()
        anchor.interactive = true
        anchor.prefersAbove = true
        return anchor
    }()
    /// The selection the toolbar was opened for: a new selection re-arms a toolbar that a
    /// scroll or resign-key latched shut; the same one (a re-render) leaves it closed.
    private var shownFor: NSRange?

    /// Shows the toolbar over `rect` (text-view coordinates) for `range`, or hides it for nil.
    func update(in textView: NSTextView, range: NSRange?, rect: CGRect?, onChoose: @escaping (NoteKind?) -> Void) {
        guard let range, let rect else { return hide() }
        if anchor.superview !== textView { textView.addSubview(anchor) }
        anchor.frame = rect
        if range != shownFor { anchor.present(nil) }
        shownFor = range
        anchor.present(AnyView(SelectionToolbar(onChoose: onChoose)))
    }

    func hide() {
        shownFor = nil
        anchor.present(nil)
    }

    var isShowing: Bool { anchor.hasPanel }
}

/// Everything the plan editor does for notes, kept out of `PlanTextView.Coordinator` so the
/// editor's own logic stays as it was: the highlight tints over annotated ranges, the selection
/// toolbar, line positions for the rail, and telling the rail when those positions move.
///
/// The highlights are a band under the quoted text in the note's colour, drawn by
/// `NoteBandView` — no attribute at all. Not a storage attribute: `MarkdownStyler` rewrites
/// those block by block on every keystroke. Not a background rendering attribute: the edit
/// layer owns that, and one key on the same characters shows only one layer, so a note on the
/// human's own insertion would hide the note or the edit. And not an underline rendering
/// attribute (`DecorationLayer`), which is what the edit layer's rules call for — TextKit 2
/// doesn't draw one: the note-over-insertion render showed the green tint and no underline.
@MainActor
final class PlanNotesBridge {
    private weak var textView: PlanNSTextView?
    private weak var controller: PlanNotesController?
    private lazy var toolbar = SelectionToolbarPresenter()
    private var observers: [NSObjectProtocol] = []

    private lazy var bands = NoteBandView()

    /// Nonisolated so the editor's (nonisolated) coordinator can own one.
    nonisolated init() {}

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Binds `controller` (nil: notes are off, as in the standalone editor) to `textView`.
    /// Called on every view update; only a change of controller does any work.
    func attach(_ controller: PlanNotesController?, to textView: PlanNSTextView?) {
        self.textView = textView
        guard controller !== self.controller else { return }
        detach()
        self.controller = controller
        guard let controller, let textView else { return }
        controller.lineTop = { [weak self] in self?.lineTop($0) }
        controller.onMarksChanged = { [weak self] in self?.tint() }
        let center = NotificationCenter.default
        // Any enclosing clip view scrolling — the editor's own, or the detail document it sits
        // in — moves every anchor's line, and the rail's cards must follow.
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let clip = note.object as? NSClipView, let view = self?.textView, view.isDescendant(of: clip) else { return }
                    self?.redrawBands()
                    self?.controller?.geometry.bump()
                }
            },
            // A new width re-wraps the text: the bands move with it.
            center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tint()
                    self?.controller?.geometry.bump()
                }
            },
        ]
        textChanged()
    }

    func detach() {
        toolbar.hide()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        controller?.lineTop = nil
        controller?.onMarksChanged = nil
        controller = nil
        bands.removeFromSuperview()
        bands.marks = []
    }

    /// The text was loaded or edited: anchors move with it.
    func textChanged() {
        guard let textView, let controller else { return }
        tint()
        let text = textView.string
        // Async: a load runs inside a SwiftUI view update, where publishing is not allowed.
        DispatchQueue.main.async { [weak controller] in controller?.editorChanged(text) }
    }

    /// The selection moved or focus came or went: the toolbar follows a non-empty selection in
    /// the focused editor, and is gone otherwise.
    func selectionChanged() {
        guard let textView, let controller else { return toolbar.hide() }
        let range = textView.selectedRange()
        controller.selection = range
        // The caret block's syntax just showed or hid, moving the lines under the bands.
        redrawBands()
        guard textView.isFocused, range.length > 0, !textView.hasMarkedText(), let rect = firstLineRect(range) else {
            return toolbar.hide()
        }
        toolbar.update(in: textView, range: range, rect: rect) { [weak self, weak controller] kind in
            guard let self, let controller, let textView = self.textView else { return }
            self.toolbar.hide()
            controller.choose(kind, range: range, in: textView.string)
            // Collapse the selection so the new tint shows instead of the selection colour.
            textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        }
    }

    func focusChanged() {
        if textView?.isFocused == true, let controller, !controller.planFocused { controller.planFocused = true }
        selectionChanged()
    }

    var isShowingToolbar: Bool { toolbar.isShowing }

    // MARK: Geometry

    /// The top edge of `range`'s first line in window coordinates (y up) — the rail's anchor Y.
    private func lineTop(_ range: NSRange) -> CGFloat? {
        guard let textView, textView.window != nil, let rect = firstLineRect(range) else { return nil }
        return textView.convert(rect, to: nil).maxY
    }

    /// `range`'s first line fragment, in the text view's coordinates.
    private func firstLineRect(_ range: NSRange) -> CGRect? {
        segmentRects(range, all: false).first
    }

    /// `range`'s text segments — one per line it spans — in the text view's coordinates.
    /// `ensuringLayout` false reads what is laid out already: the bands' draw pass, which must
    /// not start a layout while drawing, and only draws the visible (laid-out) lines anyway.
    private func segmentRects(_ range: NSRange, all: Bool = true, ensuringLayout: Bool = true) -> [CGRect] {
        guard let textView, let manager = textView.textLayoutManager, let textRange = textRange(range) else { return [] }
        if ensuringLayout { manager.ensureLayout(for: textRange) }
        var rects: [CGRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame)
            return all
        }
        let origin = textView.textContainerOrigin
        return rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    private func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textView?.textLayoutManager?.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: Highlights

    /// Every visible note's range banded in its kind's colour (thinner and dimmer once a round
    /// has read it), the draft's in the accent colour. Located afresh in the editor's text each
    /// time, so a band follows its quote through the human's edits — and one that can't be
    /// found marks nothing.
    private func tint() {
        guard let textView else { return }
        if bands.superview !== textView {
            textView.addSubview(bands)
            bands.segments = { [weak self] in self?.segmentRects($0, ensuringLayout: false) ?? [] }
        }
        if bands.frame != textView.bounds { bands.frame = textView.bounds }
        let text = textView.string
        bands.marks = (controller?.marks ?? []).compactMap { mark in
            guard let found = mark.anchor.locate(in: text) else { return nil }
            let color = (mark.draft ? NSColor.controlAccentColor : NoteStyle.tint(mark.kind))
                .withAlphaComponent(mark.consumed ? 0.45 : 0.95)
            return NoteBandView.Mark(range: NSRange(found, in: text), color: color, thickness: mark.consumed ? 1 : 2.5)
        }
        bands.needsDisplay = true
    }

    /// Layout moved under the bands (a scroll, a re-wrap, a restyle): redraw them in place.
    private func redrawBands() { bands.needsDisplay = true }
}

/// Draws the notes' bands over the text view's own drawing, taking no clicks. A subview of the
/// text view, so it scrolls with the text. The line rects are measured while drawing, not when
/// the marks are set: measured at load they came from TextKit 2's first estimate, before the
/// styling and the edit layer's spacing settled, and the bands sat one to three lines high.
final class NoteBandView: NSView {
    struct Mark: Equatable {
        let range: NSRange
        let color: NSColor
        let thickness: CGFloat
    }

    var marks: [Mark] = []
    /// A range's line segments in this view's (the text view's) coordinates.
    var segments: (NSRange) -> [CGRect] = { _ in [] }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            mark.color.setFill()
            for line in segments(mark.range) {
                let band = CGRect(x: line.minX, y: line.maxY - mark.thickness - 1, width: line.width, height: mark.thickness)
                guard band.intersects(dirtyRect) else { continue }
                NSBezierPath(roundedRect: band, xRadius: band.height / 2, yRadius: band.height / 2).fill()
            }
        }
    }
}
