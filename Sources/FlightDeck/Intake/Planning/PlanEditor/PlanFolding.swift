import AppKit

/// Hides folded sections' bodies from layout, and only from layout: TextKit 2 asks its content
/// storage's delegate whether to enumerate each paragraph, and a paragraph it skips is never laid
/// out or drawn — while the storage, the plan, every edit, note anchor and diff offset stay
/// exactly as they are. The mechanism TextKit 2 offers for hiding text (WWDC21's hidden
/// comments), rather than a zero-height layout fragment, which TextKit still lays out, hit-tests
/// and places the caret in.
final class PlanFoldFilter: NSObject, NSTextContentStorageDelegate {
    /// The folded bodies, sorted and disjoint (`PlanFolds.hidden`), in UTF-16 offsets.
    var hidden: [NSRange] = []

    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        // Nothing folded — the normal case — costs one check per paragraph.
        guard !hidden.isEmpty, let start = textElement.elementRange?.location else { return true }
        return !contains(textContentManager.offset(from: textContentManager.documentRange.location, to: start))
    }

    /// Whether a paragraph starting at `offset` is hidden. Binary search: TextKit asks for every
    /// paragraph it lays out.
    func contains(_ offset: Int) -> Bool {
        var lo = 0, hi = hidden.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = hidden[mid]
            if offset < r.location { hi = mid - 1 } else if offset >= NSMaxRange(r) { lo = mid + 1 } else { return true }
        }
        return false
    }
}

/// The heading chevrons and a folded section's "⋯ 12 lines", drawn in the gutter's chevron
/// column and after the heading's words. A subview of the text view (so it scrolls with the
/// text) that takes no clicks: the text view routes a click on a chevron or the pill to
/// `onToggle` (`PlanNSTextView.mouseDown`). Obsidian's behaviour: a heading's chevron shows
/// while the pointer is on its line, and always while it is folded.
final class PlanFoldGutter: NSView {
    struct Mark: Equatable {
        let key: PlanFoldKey
        /// The heading's first line, in the text view's coordinates.
        let line: CGRect
        /// Where the heading's words end on that line — the pill follows them.
        let textEnd: CGFloat
        let folded: Bool
        /// "12 lines" for a folded one.
        let lines: Int
    }

    /// The visible headings' marks as of the last draw — what a click or hover is tested against.
    private(set) var marks: [Mark] = []
    /// Measures the marks. Called while drawing, like the notes' bands (`NoteBandView`): the
    /// viewport's lines are laid out by then, where measured on a scroll beat they were not yet.
    var measure: () -> [Mark] = { [] }
    var hovered: PlanFoldKey? {
        didSet {
            guard hovered != oldValue else { return }
            for key in [oldValue, hovered].compactMap({ $0 }) {
                if let mark = marks.first(where: { $0.key == key }) { setNeedsDisplay(chevronRect(mark)) }
            }
        }
    }
    /// The chevron column's centre, from the view's leading edge.
    var chevronX: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let chevronSize: CGFloat = 9

    /// Redraws only what this view draws within `visible`: the chevron column and the folded
    /// headings' pills. Invalidating all of `visible` made the text view under this
    /// transparent view redraw every visible line, on every keystroke.
    func refresh(_ visible: NSRect) {
        setNeedsDisplay(NSRect(x: chevronX - 10, y: visible.minY, width: 20, height: visible.height))
        for mark in marks where mark.folded { setNeedsDisplay(pillRect(mark).insetBy(dx: -2, dy: -2)) }
    }
    static let pillFont = NSFont.systemFont(ofSize: 11)

    /// A chevron's hit box for `mark`, generous vertically: the whole heading line.
    func chevronRect(_ mark: Mark) -> CGRect {
        CGRect(x: chevronX - 8, y: mark.line.minY, width: 16, height: mark.line.height)
    }

    func pillRect(_ mark: Mark) -> CGRect {
        let size = (Self.pillLabel(mark.lines) as NSString).size(withAttributes: [.font: Self.pillFont])
        return CGRect(x: mark.textEnd + 8, y: mark.line.midY - 9, width: ceil(size.width) + 14, height: 18)
    }

    static func pillLabel(_ lines: Int) -> String { "⋯  \(lines) line\(lines == 1 ? "" : "s")" }

    /// The mark whose chevron or pill is under `point`.
    func hit(_ point: NSPoint) -> Mark? {
        marks.first { mark in
            (mark.folded || mark.key == hovered) && chevronRect(mark).contains(point) || mark.folded && pillRect(mark).contains(point)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        marks = measure()
        for mark in marks where mark.folded || mark.key == hovered {
            guard mark.line.insetBy(dx: -400, dy: -2).intersects(dirtyRect) else { continue }
            drawChevron(mark)
            if mark.folded { drawPill(mark) }
        }
    }

    private func drawChevron(_ mark: Mark) {
        let s = Self.chevronSize
        let c = CGPoint(x: chevronX, y: mark.line.midY)
        let path = NSBezierPath()
        if mark.folded {
            // ›, pointing at the words it hides.
            path.move(to: CGPoint(x: c.x - s * 0.22, y: c.y - s * 0.45))
            path.line(to: CGPoint(x: c.x + s * 0.28, y: c.y))
            path.line(to: CGPoint(x: c.x - s * 0.22, y: c.y + s * 0.45))
        } else {
            // ⌄, open.
            path.move(to: CGPoint(x: c.x - s * 0.45, y: c.y - s * 0.2))
            path.line(to: CGPoint(x: c.x, y: c.y + s * 0.28))
            path.line(to: CGPoint(x: c.x + s * 0.45, y: c.y - s * 0.2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (mark.folded ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    private func drawPill(_ mark: Mark) {
        let rect = pillRect(mark)
        NSColor.secondaryLabelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        let label = NSAttributedString(string: Self.pillLabel(mark.lines),
                                       attributes: [.font: Self.pillFont, .foregroundColor: NSColor.secondaryLabelColor])
        let size = label.size()
        label.draw(at: CGPoint(x: rect.minX + 7, y: rect.midY - size.height / 2))
    }
}
