import AppKit

/// The editor's side of editing tables in place. A grid row's source line is hidden text held to
/// the row's height, so everything that rests on that text — the caret, a selection, typing,
/// the arrow keys — would act on nothing visible. This takes each of them over for a caret or
/// selection that is in a table: the caret and the selection are drawn in the cells
/// (`PlanTableOverlay`), the keys and the text input are routed through `PlanTableEditing` (the
/// model, which knows nothing of views), and what the model returns is put in the text as one
/// ordinary, undoable edit. The stored plan stays the Markdown the human typed.
///
/// Held by `PlanNSTextView`, which forwards its overrides here and does nothing different when
/// the caret is not in a table.
@MainActor
final class PlanTableController {
    unowned let view: PlanNSTextView
    let overlay = PlanTableOverlay()

    /// Set while the editor itself changes a table or reverts an edit: structure edits that
    /// `resolve` would refuse a keystroke.
    var structureEditing = false
    /// The end of a selection that does not move when it is extended.
    private(set) var anchor: Int?
    /// Where a drag that began in a cell began.
    private var dragAnchor: Int?
    private(set) var caretOn = true
    private var blink: Timer?
    let menuTarget = PlanTableMenuTarget()

    init(view: PlanNSTextView) {
        self.view = view
        overlay.controller = self
    }

    // MARK: Places

    /// A table in the text, and where the offset asked about falls in it.
    struct Place {
        let ref: PlanTableRowRef
        /// The start of the offset's row.
        let lineStart: Int
        /// The table's text, from `start`.
        let start: Int
        let source: String
        let rowStarts: [Int]
        var length: Int { (source as NSString).length }
        var end: Int { start + length }
        var layout: PlanTableLayout { ref.layout }
        func relative(_ offset: Int) -> Int { offset - start }
    }

    /// The grid table holding `offset` — a row's line, its end included — or nil.
    func place(at offset: Int) -> Place? {
        guard let storage = view.textStorage, storage.length > 0, offset >= 0 else { return nil }
        let ns = storage.mutableString
        if offset >= ns.length, ns.character(at: ns.length - 1) == 10 { return nil }
        let probe = min(offset, ns.length - 1)
        guard let ref = storage.attribute(.planTableRow, at: probe, effectiveRange: nil) as? PlanTableRowRef else { return nil }
        var lineStart = ns.lineRange(for: NSRange(location: probe, length: 0)).location
        var start = lineStart
        for _ in 0..<ref.row { start = ns.lineRange(for: NSRange(location: max(start - 1, 0), length: 0)).location }
        var starts: [Int] = []
        var at = start
        var end = start
        for _ in 0..<ref.layout.rows.count {
            guard at < ns.length || starts.isEmpty else { break }
            starts.append(at)
            var s = 0, e = 0, c = 0
            ns.getLineStart(&s, end: &e, contentsEnd: &c, for: NSRange(location: at, length: 0))
            end = c
            at = e
        }
        lineStart = starts.indices.contains(ref.row) ? starts[ref.row] : lineStart
        return Place(ref: ref, lineStart: lineStart, start: start, source: ns.substring(with: NSRange(location: start, length: end - start)),
                     rowStarts: starts)
    }

    /// Every grid table a selection reaches, from either end or through the middle.
    func tables(touching selection: NSRange) -> [Place] {
        guard let storage = view.textStorage, storage.length > 0 else { return [] }
        var starts: [Int] = []
        let clipped = NSIntersectionRange(selection, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.planTableRow, in: clipped) { value, range, _ in
            if let ref = value as? PlanTableRowRef, ref.row == 0 { starts.append(range.location) }
            else if value is PlanTableRowRef, let p = place(at: range.location) { starts.append(p.start) }
        }
        for offset in [selection.location, NSMaxRange(selection)] { if let p = place(at: offset) { starts.append(p.start) } }
        var seen = Set<Int>()
        return starts.filter { seen.insert($0).inserted }.compactMap { place(at: $0) }
    }

    /// The table (if any) a selection touches at either end.
    func selectionTables() -> [Place] {
        let r = view.selectedRange()
        var out: [Place] = []
        for offset in [r.location, NSMaxRange(r)] {
            if let p = place(at: offset), !out.contains(where: { $0.start == p.start }) { out.append(p) }
        }
        return out
    }

    /// A source offset (of the document) as a place in its table's grid.
    func cell(at offset: Int, in table: Place) -> PlanTableEditing.CellPlace? {
        PlanTableEditing.place(in: table.source, at: table.relative(offset))
    }

    // MARK: Geometry

    /// The top-left corner of a table row's band, in the text view's coordinates.
    func bandOrigin(lineStart: Int) -> CGPoint? {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: lineStart),
              let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let origin = view.textContainerOrigin
        let padding = view.textContainer?.lineFragmentPadding ?? 0
        return CGPoint(x: origin.x + padding,
                       y: origin.y + fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0))
    }

    /// The caret at `offset` in a table, in the view's coordinates.
    func caretRect(at offset: Int, in table: Place) -> CGRect? {
        guard let cell = cell(at: offset, in: table), table.layout.rows.indices.contains(cell.row),
              table.layout.columns.indices.contains(cell.column),
              let origin = bandOrigin(lineStart: table.rowStarts[cell.row]) else { return nil }
        let length = table.layout.rows[cell.row].cells[cell.column].text.length
        return table.layout.caretRect(row: cell.row, column: cell.column, shown: min(cell.offset, length))
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    /// What is at `point` (view coordinates) if it is on a grid cell: the document offset the
    /// caret goes to.
    func hit(at point: NSPoint) -> (offset: Int, table: Place)? {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager else { return nil }
        let origin = view.textContainerOrigin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: local),
              let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString, paragraph.length > 0,
              let ref = paragraph.attribute(.planTableRow, at: 0, effectiveRange: nil) as? PlanTableRowRef
        else { return nil }
        let lineStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard let table = place(at: lineStart), let band = bandOrigin(lineStart: lineStart),
              let found = ref.layout.hit(row: ref.row, at: CGPoint(x: point.x - band.x, y: point.y - band.y)),
              let relative = PlanTableEditing.sourceOffset(in: table.source, of: .init(row: ref.row, column: found.column, offset: found.shown))
        else { return nil }
        return (table.start + relative, table)
    }

    // MARK: Selection

    /// The selection changed: the caret shows (and blinks) in the cells, the system's caret does
    /// not, and the anchor follows.
    func selectionChanged(_ ranges: [NSValue]) {
        guard let range = ranges.first?.rangeValue else { return }
        if range.length == 0 { anchor = range.location }
        else if anchor != range.location, anchor != NSMaxRange(range) { anchor = range.location }
        // Nothing ever sits in a delimiter row: it has no cells.
        if range.length == 0, let table = place(at: range.location), table.ref.row == PlanTable.delimiterRow,
           let cell = cell(at: range.location, in: table),
           let target = PlanTableEditing.sourceOffset(in: table.source, of: cell) {
            view.setSelectedRange(NSRange(location: table.start + target, length: 0))
            return
        }
        let inTable = !selectionTables().isEmpty
        caretOn = true
        view.insertionPointColor = inTable && range.length == 0 ? .clear : .textInsertionPointColor
        hideSystemCaret(inTable && range.length == 0)
        updateBlink()
        overlay.refresh(in: view)
    }

    private func hideSystemCaret(_ hide: Bool) {
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let indicator = sub as? NSTextInsertionIndicator { indicator.displayMode = hide ? .hidden : .automatic }
                walk(sub)
            }
        }
        walk(view)
    }

    func focusChanged() {
        selectionChanged([NSValue(range: view.selectedRange())])
    }

    private func updateBlink() {
        let wanted = view.isFocused && view.selectedRange().length == 0 && !selectionTables().isEmpty
        if wanted, blink == nil {
            let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.caretOn.toggle()
                    self.overlay.setNeedsDisplay(self.overlay.bounds)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            blink = timer
        } else if !wanted {
            blink?.invalidate()
            blink = nil
        }
    }

    // MARK: Text changes

    enum Resolution { case allow, veto, done }

    /// An edit AppKit is about to make, `range` replaced by `text`: let it through, refuse it, or
    /// (`done`) it was made here, by the model, instead.
    func resolve(_ range: NSRange, _ text: String) -> Resolution {
        let a = place(at: range.location)
        let b = range.length > 0 ? place(at: NSMaxRange(range)) : a
        let ns = view.string as NSString

        // One table: the model.
        if let a, let b {
            guard a.start == b.start else { return .veto }
            // The whole table selected: deleting it is deleting it.
            if range.location <= a.start, NSMaxRange(range) >= a.end { return .allow }
            let relative = NSRange(location: range.location - a.start, length: range.length)
            let result = text.isEmpty
                ? PlanTableEditing.delete(.backward, over: relative, in: a.source)
                : PlanTableEditing.type(text, over: relative, in: a.source)
            guard let result else { return .veto }
            let naive = (a.source as NSString).replacingCharacters(in: relative, with: text)
            if result.source == naive { return .allow }
            apply(result, to: a)
            return .done
        }
        // A selection that starts or ends in a table and reaches outside it: the outside goes as
        // it would, the cells are cleared, and the newline either side of the table stays.
        if let a {
            if range.location <= a.start { return .allow }
            let cells = NSRange(location: range.location - a.start, length: a.length - (range.location - a.start))
            guard let result = text.isEmpty ? PlanTableEditing.delete(.backward, over: cells, in: a.source)
                : PlanTableEditing.type(text, over: cells, in: a.source) else { return .veto }
            replace(NSRange(location: a.start, length: NSMaxRange(range) - a.start), with: result.source + "\n",
                    selection: NSRange(location: a.start + result.selection.location, length: result.selection.length))
            return .done
        }
        if let b {
            // A line, or a blank line, ahead of a table: the newline that ends it stays.
            let before = range.location > 0 ? ns.character(at: range.location - 1) : 10
            if range.length == 1, b.start == NSMaxRange(range), text.isEmpty, before == 10 { return .allow }
            if range.location <= b.start, NSMaxRange(range) >= b.end { return .allow }
            let cells = NSRange(location: 0, length: NSMaxRange(range) - b.start)
            guard cells.length > 0 || b.start - 1 > range.location || !text.isEmpty else { return .veto }
            let source = cells.length > 0 ? (PlanTableEditing.delete(.backward, over: cells, in: b.source)?.source ?? b.source) : b.source
            replace(NSRange(location: range.location, length: b.end - range.location), with: text + "\n" + source,
                    selection: NSRange(location: range.location + (text as NSString).length, length: 0))
            return .done
        }
        return .allow
    }

    /// `result` of the model for `table`, put in as one edit.
    func apply(_ result: PlanTableEditing.Result, to table: Place) {
        let old = table.source as NSString, new = result.source as NSString
        var front = 0
        while front < old.length, front < new.length, old.character(at: front) == new.character(at: front) { front += 1 }
        var back = 0
        while back < old.length - front, back < new.length - front,
              old.character(at: old.length - 1 - back) == new.character(at: new.length - 1 - back) { back += 1 }
        let range = NSRange(location: table.start + front, length: old.length - front - back)
        let text = new.substring(with: NSRange(location: front, length: new.length - front - back))
        replace(range, with: text, selection: NSRange(location: table.start + result.selection.location, length: result.selection.length))
    }

    /// `range` replaced by `text` and the selection set, as its own undoable step.
    func replace(_ range: NSRange, with text: String, selection: NSRange) {
        let was = structureEditing
        structureEditing = true
        defer { structureEditing = was }
        view.breakUndoCoalescing()
        guard view.shouldChangeText(in: range, replacementString: text), let storage = view.textStorage else { return }
        storage.replaceCharacters(in: range, with: text)
        view.didChangeText()
        view.setSelectedRange(selection)
        view.breakUndoCoalescing()
    }

    // MARK: Keys

    private func key(for selector: Selector) -> PlanTableEditing.Key? {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)): return .left
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveRightAndModifySelection(_:)): return .right
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)): return .up
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)): return .down
        case #selector(NSResponder.insertTab(_:)): return .tab
        case #selector(NSResponder.insertBacktab(_:)): return .backtab
        case #selector(NSResponder.insertNewline(_:)): return .return
        default: return nil
        }
    }

    /// A movement key with the caret (or the selection's moving end) in a table: handled here and
    /// true, or false for AppKit to handle.
    func handle(_ selector: Selector, extending: Bool) -> Bool {
        guard let key = key(for: selector) else { return false }
        let selection = view.selectedRange()
        let head: Int
        if selection.length == 0 { head = selection.location }
        else if anchor == selection.location { head = NSMaxRange(selection) }
        else { head = selection.location }
        guard let table = place(at: head), !(selection.length > 0 && !extending && [.tab, .backtab, .return].contains(key)) else { return false }
        // A selection collapses before it moves: left to its start, right to its end.
        if selection.length > 0, !extending, key == .left || key == .right {
            view.setSelectedRange(NSRange(location: key == .left ? selection.location : NSMaxRange(selection), length: 0))
            return true
        }
        let relative = table.relative(head)
        var target: PlanTableEditing.Move
        if key == .up || key == .down, let cell = cell(at: head, in: table), let stepped = verticalStep(cell, key == .down, table) {
            target = .caret(stepped)
        } else {
            let x = (key == .up || key == .down) ? caretRect(at: head, in: table)?.minX : nil
            target = PlanTableEditing.move(key, from: relative, in: table.source)
            if key == .up || key == .down, case .caret(let q) = target, let x, let found = PlanTableEditing.place(in: table.source, at: q),
               let origin = bandOrigin(lineStart: table.rowStarts[found.row]) {
                let shown = table.layout.shownOffset(row: found.row, column: found.column, nearX: x - origin.x, lastLine: key == .up)
                if let r = PlanTableEditing.sourceOffset(in: table.source, of: .init(row: found.row, column: found.column, offset: shown)) {
                    target = .caret(r)
                }
            }
        }
        switch target {
        case .caret(let q):
            move(head: table.start + q, extending: extending)
        case .leave(let direction):
            let ns = view.string as NSString
            var offset: Int
            if direction == .before { offset = max(table.start - 1, 0) }
            else { offset = min(table.end + 1, ns.length) }
            if key == .up || key == .down, let x = caretRect(at: head, in: table)?.minX {
                let lineY = (bandOrigin(lineStart: direction == .before ? table.rowStarts[0] : table.rowStarts[table.rowStarts.count - 1]) ?? .zero).y
                let probe = direction == .before ? lineY - 3 : lineY + table.layout.rows[table.ref.layout.lastVisible].height + 3
                    + PlanTheme.standard.tableSpaceAfter
                let found = view.characterIndexForInsertion(at: NSPoint(x: x, y: probe))
                if (direction == .before && found < table.start) || (direction == .after && found > table.end) { offset = found }
            }
            move(head: offset, extending: extending)
        case .appendRow(let column):
            guard !extending, let result = Optional(PlanTableEditing.appendRow(in: table.source, caretColumn: column)) else { return true }
            apply(result, to: table)
        }
        return true
    }

    private func verticalStep(_ cell: PlanTableEditing.CellPlace, _ down: Bool, _ table: Place) -> Int? {
        guard table.layout.rows.indices.contains(cell.row), table.layout.columns.indices.contains(cell.column),
              let shown = table.layout.verticalStep(row: cell.row, column: cell.column, shown: cell.offset, down: down),
              let relative = PlanTableEditing.sourceOffset(in: table.source, of: .init(row: cell.row, column: cell.column, offset: shown))
        else { return nil }
        return relative
    }

    private func move(head: Int, extending: Bool) {
        guard extending, let anchor else { return view.setSelectedRange(NSRange(location: head, length: 0)) }
        let a = min(anchor, head), b = max(anchor, head)
        let keep = anchor
        view.setSelectedRange(NSRange(location: a, length: b - a))
        self.anchor = keep
    }

    // MARK: Mouse

    /// A click or the start of a drag on a cell: true when it was one and is handled.
    func mouseDown(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard !event.modifierFlags.contains(.control), let found = hit(at: point) else { return false }
        view.window?.makeFirstResponder(view)
        if event.modifierFlags.contains(.shift), let anchor {
            dragAnchor = anchor
            move(head: found.offset, extending: true)
            return true
        }
        switch event.clickCount {
        case 2:
            let word = self.word(at: found.offset, in: found.table)
            view.setSelectedRange(word)
            dragAnchor = word.location
        case 3...:
            let cell = self.cellRange(at: found.offset, in: found.table)
            view.setSelectedRange(cell)
            dragAnchor = cell.location
        default:
            view.setSelectedRange(NSRange(location: found.offset, length: 0))
            dragAnchor = found.offset
        }
        return true
    }

    /// A drag that began in a cell: the selection from there to wherever the pointer is.
    func mouseDragged(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let start = dragAnchor else { return false }
        let head = hit(at: point)?.offset ?? view.characterIndexForInsertion(at: point)
        let a = min(start, head), b = max(start, head)
        view.setSelectedRange(NSRange(location: a, length: b - a))
        anchor = start
        view.autoscroll(with: event)
        return true
    }

    func mouseUp() -> Bool {
        defer { dragAnchor = nil }
        return dragAnchor != nil
    }

    private func word(at offset: Int, in table: Place) -> NSRange {
        guard let cell = cell(at: offset, in: table), table.layout.rows.indices.contains(cell.row),
              table.layout.columns.indices.contains(cell.column) else { return NSRange(location: offset, length: 0) }
        let text = table.layout.rows[cell.row].cells[cell.column].text.string as NSString
        guard text.length > 0 else { return NSRange(location: offset, length: 0) }
        let at = min(cell.offset, text.length - 1)
        func isWord(_ i: Int) -> Bool { CharacterSet.alphanumerics.contains(Unicode.Scalar(text.character(at: i)) ?? " ") }
        var from = at, to = at + 1
        if isWord(at) {
            while from > 0, isWord(from - 1) { from -= 1 }
            while to < text.length, isWord(to) { to += 1 }
        }
        let word = NSRange(location: from, length: to - from)
        return shownRange(word, cell: cell, table)
    }

    private func cellRange(at offset: Int, in table: Place) -> NSRange {
        guard let cell = cell(at: offset, in: table), table.layout.rows.indices.contains(cell.row),
              table.layout.columns.indices.contains(cell.column) else { return NSRange(location: offset, length: 0) }
        let length = table.layout.rows[cell.row].cells[cell.column].text.length
        return shownRange(NSRange(location: 0, length: length), cell: cell, table)
    }

    /// The document range of shown characters `range` of the cell.
    private func shownRange(_ range: NSRange, cell: PlanTableEditing.CellPlace, _ table: Place) -> NSRange {
        let from = PlanTableEditing.sourceOffset(in: table.source, of: .init(row: cell.row, column: cell.column, offset: range.location))
        let to = PlanTableEditing.sourceOffset(in: table.source, of: .init(row: cell.row, column: cell.column, offset: NSMaxRange(range)))
        guard let from, let to else { return NSRange(location: table.start, length: 0) }
        return NSRange(location: table.start + from, length: max(to - from, 0))
    }

    /// The caret's x in the view, for a vertical move that lands in a table.
    func caretX() -> CGFloat? {
        let location = view.selectedRange().location
        if let table = place(at: location) { return caretRect(at: location, in: table)?.minX }
        return view.caretRect(at: location)?.minX
    }

    /// A vertical move by AppKit ended in a table: the caret goes to the cell at `x` in the row it
    /// came in at, not wherever the hidden text put it.
    func entered(atX x: CGFloat?, movingDown: Bool) {
        let location = view.selectedRange().location
        guard let x, view.selectedRange().length == 0, let table = place(at: location) else { return }
        let row = movingDown ? 0 : table.layout.lastVisible
        guard let origin = bandOrigin(lineStart: table.rowStarts[row]),
              let column = table.layout.column(atX: x - origin.x) ?? Optional(table.layout.columns.count - 1) else { return }
        let shown = table.layout.shownOffset(row: row, column: column, nearX: x - origin.x, lastLine: !movingDown)
        if let q = PlanTableEditing.sourceOffset(in: table.source, of: .init(row: row, column: column, offset: shown)) {
            view.setSelectedRange(NSRange(location: table.start + q, length: 0))
        }
    }

    /// AppKit's own drag, from outside a table, ended: if the pointer ended on a cell, the selection
    /// ends there rather than at the row's hidden text.
    func finishDrag(from start: NSPoint, selectionBefore: NSRange) {
        let selection = view.selectedRange()
        guard selection.length > 0, let window = view.window,
              let end = hit(at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        let origin = view.characterIndexForInsertion(at: start)
        let fixed = origin <= selection.location ? selection.location : NSMaxRange(selection)
        let a = min(fixed, end.offset), b = max(fixed, end.offset)
        view.setSelectedRange(NSRange(location: a, length: b - a))
        anchor = fixed
    }

    // MARK: Copy

    /// What a selection that touches a table copies as: its rows as a Markdown table, or one
    /// cell's text. Nil leaves the copy to AppKit.
    func copyText() -> String? {
        let selection = view.selectedRange()
        guard selection.length > 0, let table = place(at: selection.location), let end = place(at: NSMaxRange(selection)),
              table.start == end.start else { return nil }
        return PlanTableEditing.copyText(of: NSRange(location: selection.location - table.start, length: selection.length), in: table.source)
    }
}

/// The caret and the selection of a table, drawn in its cells. A view of its own under the text
/// (like the notes' bands), because a grid row's text is hidden and the text view draws its
/// selection and caret by it.
final class PlanTableOverlay: NSView {
    weak var controller: PlanTableController?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @MainActor
    func refresh(in textView: PlanNSTextView) {
        if superview !== textView { textView.addSubview(self, positioned: .below, relativeTo: nil) }
        if frame != textView.bounds { frame = textView.bounds }
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
            let view = controller.view
            let selection = view.selectedRange()
            let focused = view.isFocused
            if selection.length == 0 {
                guard focused, controller.caretOn, let table = controller.place(at: selection.location),
                      let rect = controller.caretRect(at: selection.location, in: table) else { return }
                NSColor.textInsertionPointColor.setFill()
                context.fill(CGRect(x: rect.minX - 0.5, y: rect.minY, width: 1, height: rect.height))
                return
            }
            (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).withAlphaComponent(0.45).setFill()
            for table in controller.tables(touching: selection) {
                for fill in controller.selectionFills(selection, in: table) { context.fill(fill) }
            }
        }
    }
}

extension PlanTableController {
    /// The cells a selection covers, or the text within one, in the view's coordinates, for the
    /// table holding its start.
    func selectionFills(_ selection: NSRange, in table: Place) -> [CGRect] {
        let lo = max(selection.location, table.start), hi = min(NSMaxRange(selection), table.end)
        guard hi > lo || selection.length > 0, let from = cell(at: lo, in: table), let to = cell(at: max(hi, lo), in: table) else { return [] }
        let layout = table.layout
        func origin(_ row: Int) -> CGPoint? { table.rowStarts.indices.contains(row) ? bandOrigin(lineStart: table.rowStarts[row]) : nil }
        if from.row == to.row, from.column == to.column {
            guard let o = origin(from.row), layout.rows.indices.contains(from.row) else { return [] }
            return layout.textRects(row: from.row, column: from.column, shown: NSRange(location: from.offset, length: max(to.offset - from.offset, 0)))
                .map { $0.insetBy(dx: -1, dy: 0).offsetBy(dx: o.x, dy: o.y) }
        }
        var out: [CGRect] = []
        let afterSelection = NSMaxRange(selection) >= table.end
        for row in from.row...max(to.row, from.row) where row != PlanTable.delimiterRow && layout.rows.indices.contains(row) {
            guard let o = origin(row) else { continue }
            for column in 0..<layout.columns.count {
                if row == from.row, column < from.column { continue }
                if row == to.row, column > to.column { continue }
                // A cell only touched at its very start has nothing of it selected.
                if row == to.row, column == to.column, to.offset == 0, !afterSelection, !(from.row == to.row && from.column == to.column) { continue }
                out.append(layout.cellRect(row: row, column: column).insetBy(dx: 1, dy: 1).offsetBy(dx: o.x, dy: o.y))
            }
        }
        return out
    }
}

// MARK: - Context menu

/// What a cell's context menu offers, and does: the only structure edits there are.
@MainActor
final class PlanTableMenuTarget: NSObject {
    weak var controller: PlanTableController?
    /// A place in the table the menu was opened on, and the cell.
    var offset = 0
    var row = 0
    var column = 0

    static let items: [(title: String, operation: PlanTableEditing.Structure, id: String)] = [
        ("Insert Row Above", .insertRow(above: true), "plan-table-insert-row-above"),
        ("Insert Row Below", .insertRow(above: false), "plan-table-insert-row-below"),
        ("Insert Column Left", .insertColumn(left: true), "plan-table-insert-column-left"),
        ("Insert Column Right", .insertColumn(left: false), "plan-table-insert-column-right"),
        ("Delete Row", .deleteRow, "plan-table-delete-row"),
        ("Delete Column", .deleteColumn, "plan-table-delete-column"),
    ]

    @objc func choose(_ item: NSMenuItem) {
        guard let index = Self.items.firstIndex(where: { $0.title == item.title }) else { return }
        controller?.perform(Self.items[index].operation, row: row, column: column, at: offset, actionName: item.title)
    }
}

extension PlanTableController {
    /// The structure items for the cell under `found`, below `menu`'s own.
    func addStructureItems(to menu: NSMenu, at found: (offset: Int, table: Place)) {
        guard let cell = cell(at: found.offset, in: found.table) else { return }
        menuTarget.controller = self
        menuTarget.offset = found.offset
        menuTarget.row = cell.row
        menuTarget.column = cell.column
        menu.addItem(.separator())
        for entry in PlanTableMenuTarget.items {
            let item = NSMenuItem(title: entry.title, action: #selector(PlanTableMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.isEnabled = PlanTableEditing.allows(entry.operation, row: cell.row, column: cell.column, in: found.table.source)
            item.identifier = NSUserInterfaceItemIdentifier(entry.id)
            menu.addItem(item)
        }
    }

    /// Insert or delete a row or column at a cell, as one undoable edit.
    func perform(_ operation: PlanTableEditing.Structure, row: Int, column: Int, at offset: Int, actionName: String) {
        guard let table = place(at: offset),
              let result = PlanTableEditing.apply(operation, row: row, column: column, in: table.source) else { return }
        apply(result, to: table)
        view.undoManager?.setActionName(actionName)
    }
}

// MARK: - Accessibility

/// A table as VoiceOver reads it: rows of cells, a header row, each cell its shown words.
final class PlanTableAXTable: NSAccessibilityElement {
    var rowElements: [NSAccessibilityElement] = []
    var headerCells: [NSAccessibilityElement] = []
    var columnCount = 0

    override func accessibilityRows() -> [Any]? { rowElements }
    override func accessibilityColumnHeaderUIElements() -> [Any]? { headerCells }
    override func accessibilityChildren() -> [Any]? { rowElements }
}

final class PlanTableAXCell: NSAccessibilityElement {
    var rows = NSRange(location: 0, length: 1)
    var columns = NSRange(location: 0, length: 1)
    override func accessibilityRowIndexRange() -> NSRange { rows }
    override func accessibilityColumnIndexRange() -> NSRange { columns }
}

extension PlanTableController {
    /// Every grid table in the text, as accessibility elements in the text view's space.
    func accessibilityTables() -> [NSAccessibilityElement] {
        guard let storage = view.textStorage else { return [] }
        var starts: [Int] = []
        storage.enumerateAttribute(.planTableRow, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let ref = value as? PlanTableRowRef, ref.row == 0 { starts.append(range.location) }
        }
        return starts.compactMap { start -> NSAccessibilityElement? in
            guard let table = place(at: start), let top = bandOrigin(lineStart: table.rowStarts[0]) else { return nil }
            let layout = table.layout
            let element = PlanTableAXTable()
            element.setAccessibilityRole(.table)
            element.setAccessibilityLabel("Table, \(layout.rows.filter { !$0.isHidden }.count) rows, \(layout.columns.count) columns")
            element.setAccessibilityParent(view)
            element.setAccessibilityFrameInParentSpace(CGRect(x: top.x, y: top.y, width: layout.width, height: layout.height))
            var shownRow = 0
            for (r, row) in layout.rows.enumerated() where !row.isHidden {
                guard let origin = bandOrigin(lineStart: table.rowStarts[r]) else { continue }
                let rowElement = NSAccessibilityElement()
                rowElement.setAccessibilityRole(.row)
                rowElement.setAccessibilityParent(element)
                rowElement.setAccessibilityFrameInParentSpace(CGRect(x: origin.x, y: origin.y, width: layout.width, height: row.height))
                var cells: [NSAccessibilityElement] = []
                for (c, cell) in row.cells.enumerated() {
                    let ax = PlanTableAXCell()
                    ax.setAccessibilityRole(.cell)
                    ax.setAccessibilityLabel(cell.text.string)
                    ax.setAccessibilityIdentifier("plan-table-cell-\(shownRow)-\(c)")
                    ax.setAccessibilityParent(rowElement)
                    ax.rows = NSRange(location: shownRow, length: 1)
                    ax.columns = NSRange(location: c, length: 1)
                    ax.setAccessibilityFrameInParentSpace(layout.cellRect(row: r, column: c).offsetBy(dx: origin.x, dy: origin.y))
                    cells.append(ax)
                }
                rowElement.setAccessibilityChildren(cells)
                if r == 0 { element.headerCells = cells }
                element.rowElements.append(rowElement)
                shownRow += 1
            }
            element.columnCount = layout.columns.count
            return element
        }
    }
}
