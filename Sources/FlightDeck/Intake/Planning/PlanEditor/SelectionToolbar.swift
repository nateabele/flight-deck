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
/// The highlights are a wash under the quoted text in the one note highlight colour, drawn by
/// `NoteBandView` — no attribute at all. Not a storage attribute: `MarkdownStyler` rewrites
/// those block by block on every keystroke. Not a background rendering attribute: the edit
/// layer owns that, and one key on the same characters shows only one layer, so a note on the
/// human's own insertion would hide the note or the edit. And not an underline rendering
/// attribute (`DecorationLayer`), which is what the edit layer's rules call for — TextKit 2
/// doesn't draw one: the note-over-insertion render showed the green tint and no underline.
///
/// Where each quote is gets found once and then kept: a keystroke moves the ranges after it by
/// its length and re-finds only a note the edit touched, or a detached one whose quote the edit
/// might have brought back. Finding all of them afresh on every keystroke and every scroll beat
/// was a whole-plan search per note, per event.
@MainActor
final class PlanNotesBridge {
    private weak var textView: PlanNSTextView?
    private weak var controller: PlanNotesController?
    private lazy var toolbar = SelectionToolbarPresenter()
    private var observers: [NSObjectProtocol] = []
    /// The clip views around the editor that `scrollObservers` follow, to tell when the editor
    /// has moved into a different scroll hierarchy.
    private var observedClips: [ObjectIdentifier] = []
    private var scrollObservers: [NSObjectProtocol] = []

    private lazy var bands = NoteBandView()
    /// Each mark's quote in the editor's text, nil when it can't be found; valid for `marks`.
    private var located: [UUID: NSRange?] = [:]
    private var marks: [NoteMark] = []
    /// Character edits since the ranges were last brought up to date; nil after one that can't
    /// be followed (a whole-text replacement), which re-finds everything.
    private var edits: [TextEdit]? = []

    /// Nonisolated so the editor's (nonisolated) coordinator can own one.
    nonisolated init() {}

    deinit {
        (observers + scrollObservers).forEach(NotificationCenter.default.removeObserver)
    }

    /// Binds `controller` (nil: notes are off, as in the standalone editor) to `textView`.
    /// Called on every view update; only a change of controller does any work, besides keeping
    /// the scroll observers on the editor's current clip views.
    func attach(_ controller: PlanNotesController?, to textView: PlanNSTextView?) {
        self.textView = textView
        if self.controller != nil { observeScrolls() }
        guard controller !== self.controller else { return }
        detach()
        self.controller = controller
        guard let controller, let textView else { return }
        controller.lineTop = { [weak self] in self?.lineTop($0) }
        controller.onMarksChanged = { [weak self] in self?.marksChanged() }
        controller.undoManager = textView.undoManager
        let center = NotificationCenter.default
        observeScrolls()
        observers = [
            // A new width re-wraps the text: the bands move with it.
            center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tint()
                    self?.controller?.geometry.bump()
                }
            },
        ]
        if let storage = textView.textStorage {
            observers.append(TextEdit.observe(storage) { [weak self] edit in self?.edits?.append(edit) })
        }
        edits = nil
        textChanged()
    }

    func detach() {
        toolbar.hide()
        (observers + scrollObservers).forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollObservers = []
        observedClips = []
        controller?.lineTop = nil
        controller?.onMarksChanged = nil
        controller = nil
        bands.removeFromSuperview()
        bands.marks = []
        located = [:]
        marks = []
    }

    /// Any enclosing clip view scrolling — the editor's own, or the detail document it sits in —
    /// moves every anchor's line, and the rail's cards must follow. Observed on exactly those
    /// clips: with `object: nil` every clip-view scroll anywhere in the app woke the bridge.
    /// Re-subscribed only when the chain of clips changes (the editor moved hierarchy).
    private func observeScrolls() {
        let clips = textView.map(Self.enclosingClips(of:)) ?? []
        let ids = clips.map(ObjectIdentifier.init)
        guard ids != observedClips else { return }
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        observedClips = ids
        scrollObservers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                          queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.redrawBands()
                    self?.controller?.geometry.bump()
                }
            }
        }
    }

    /// Every clip view `view` scrolls inside, nearest first.
    static func enclosingClips(of view: NSView) -> [NSClipView] {
        var clips: [NSClipView] = []
        var scroll = view.enclosingScrollView
        while let current = scroll {
            clips.append(current.contentView)
            scroll = current.superview?.enclosingScrollView
        }
        return clips
    }

    /// The text was loaded or edited: anchors move with it.
    func textChanged() {
        guard let textView, let controller else { return }
        let text = textView.string
        relocate(in: text)
        tint()
        let located = self.located.compactMapValues { $0 }
        // Async: a load runs inside a SwiftUI view update, where publishing is not allowed.
        DispatchQueue.main.async { [weak controller] in controller?.editorChanged(text, located: located) }
    }

    /// The notes or the draft changed: every range is found afresh.
    private func marksChanged() {
        guard let textView, let controller else { return }
        edits = nil
        relocate(in: textView.string)
        tint()
        controller.editorChanged(textView.string, located: located.compactMapValues { $0 })
    }

    /// Brings `located` up to `text`: moved past the edits since, or found afresh.
    private func relocate(in text: String) {
        let marks = controller?.marks ?? []
        defer { self.marks = marks; edits = [] }
        guard let edits, marks == self.marks else {
            located = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, $0.anchor.locate(in: text).map { NSRange($0, in: text) }) })
            return
        }
        guard !edits.isEmpty else { return }
        let ns = text as NSString
        for mark in marks {
            var range = located[mark.id] ?? nil
            var touched = false
            for edit in edits {
                guard let r = range else { break }
                range = edit.shift(r)
                if range == nil { touched = true }
            }
            if range == nil, !touched, let found = located[mark.id], found == nil {
                // Detached: only an edit that could have typed its quote back can find it.
                touched = edits.contains { edit in
                    let line = ns.lineRange(for: NSRange(location: min(edit.range.location, ns.length), length: 0))
                    let pad = (mark.anchor.quote as NSString).length
                    let window = NSIntersectionRange(NSRange(location: line.location - pad, length: line.length + 2 * pad + edit.range.length),
                                                     NSRange(location: 0, length: ns.length))
                    return ns.range(of: mark.anchor.quote, options: [], range: window).location != NSNotFound
                }
            }
            located[mark.id] = touched ? mark.anchor.locate(in: text).map { NSRange($0, in: text) } : range
        }
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

    /// What the band under `point` (text-view coordinates) says — its kind, then the note —
    /// shown as the text view's tooltip. The kind is never a colour, so this is where the band
    /// itself says it.
    func hover(at point: NSPoint?) {
        guard let textView else { return }
        let text = point.flatMap(hoverText(at:))
        if textView.toolTip != text { textView.toolTip = text }
    }

    func hoverText(at point: NSPoint) -> String? {
        guard let controller else { return nil }
        for mark in marks.reversed() {
            guard let range = located[mark.id] ?? nil,
                  segmentRects(range, ensuringLayout: false).contains(where: { $0.insetBy(dx: 0, dy: -1).contains(point) }) else { continue }
            if mark.draft { return "Your draft \(NoteStyle.label(mark.kind).lowercased())" }
            let note = controller.notes.first { $0.id == mark.id }?.note.note ?? ""
            return NoteStyle.hover(kind: mark.kind, note: note)
        }
        return nil
    }

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

    /// The characters TextKit 2 has laid out for the visible part of the view (nil before the
    /// first layout) — the only ones a band can be drawn on.
    private func viewportRange() -> NSRange? {
        guard let layout = textView?.textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        return NSRange(location: start, length: content.offset(from: viewport.location, to: viewport.endLocation))
    }

    // MARK: Highlights

    /// Every visible note's range washed in the highlight colour (fainter once a round has read
    /// it), the draft's in the accent colour, at the ranges `located` keeps — so a band follows
    /// its quote through the human's edits, and one that can't be found marks nothing.
    private func tint() {
        guard let textView else { return }
        if bands.superview !== textView {
            // Below the text's own views: the wash sits under the glyphs, like a highlighter,
            // rather than over them.
            textView.addSubview(bands, positioned: .below, relativeTo: nil)
            bands.segments = { [weak self] in self?.segmentRects($0, ensuringLayout: false) ?? [] }
            bands.viewport = { [weak self] in self?.viewportRange() }
        }
        if bands.frame != textView.bounds { bands.frame = textView.bounds }
        let next = marks.compactMap { mark -> NoteBandView.Mark? in
            guard let range = located[mark.id] ?? nil else { return nil }
            let color = mark.draft ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : NoteStyle.highlight.withAlphaComponent(mark.consumed ? NoteStyle.consumedAlpha : NoteStyle.highlightAlpha)
            return NoteBandView.Mark(range: range, color: color)
        }
        if next != bands.marks { bands.marks = next }
        redrawBands()
    }

    /// Layout moved under the bands (a scroll, a re-wrap, a restyle): redraw them in place —
    /// only what is on screen; the rest draws when it scrolls in.
    private func redrawBands() { bands.setNeedsDisplay(bands.visibleRect) }
}

/// Draws the notes' washes under the text view's own drawing, taking no clicks. A subview of
/// the text view, so it scrolls with the text. The line rects are measured while drawing, not
/// when the marks are set: measured at load they came from TextKit 2's first estimate, before
/// the styling and the edit layer's spacing settled, and the bands sat one to three lines high.
final class NoteBandView: NSView {
    struct Mark: Equatable {
        let range: NSRange
        let color: NSColor
    }

    var marks: [Mark] = []
    /// A range's line segments in this view's (the text view's) coordinates.
    var segments: (NSRange) -> [CGRect] = { _ in [] }
    /// The laid-out characters; a mark outside them isn't measured at all.
    var viewport: () -> NSRange? = { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let viewport = self.viewport()
        for mark in marks {
            if let viewport, NSIntersectionRange(viewport, mark.range).length == 0, mark.range.location != viewport.location { continue }
            mark.color.setFill()
            for line in segments(mark.range) {
                let wash = line.insetBy(dx: -1, dy: 0)
                guard wash.intersects(dirtyRect) else { continue }
                NSBezierPath(roundedRect: wash, xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }
}
