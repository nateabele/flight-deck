import AppKit

/// What the editor needs to remember a reading position and put it back (`PlanScrollMemory`).
final class PlanScrollState {
    /// Where the position is kept; nil keeps none (an editor outside the plan pane).
    var memory: PlanScrollMemory?
    /// The first text has been loaded, so a load after it is a new text replacing one.
    var loaded = false
    /// The layout is the human's, so what it shows is worth saving. Off while a restore is in
    /// flight (the page is still on its way to the position) and once the editor is leaving.
    var live = false
    /// The position being put back, until the page is there.
    var target: PlanReadingAnchor?
    var deadline = Date.distantPast
    /// Where the restore last put the page, to tell the human's scroll from its own.
    var appliedY: CGFloat?
    /// Steps in a row that found the page where the restore put it, and steps taken since the
    /// text was all laid out without the page being able to reach the position.
    var held = 0
    var unreachable = 0
    var polling = false
    var restoreFocus = false
    /// A range to flash once the page is there: "Show in that version" arriving at its quote.
    var flash: NSRange?
    /// The scroll view kept invisible until the position is reachable, so the page never shows
    /// the top of the document for the frames it takes to grow.
    weak var hidden: NSScrollView?
    var lastTick: CFTimeInterval = 0
    var saveScheduled = false
    /// How many times a restore moved the page — for tests of "no visible jump".
    private(set) var applications = 0
    func applied() { applications += 1 }
}

extension PlanTextView.Coordinator {
    /// A scroll must be this quiet before the position is read from the layout.
    static let readingQuiet: TimeInterval = 0.25
    /// A restore gives up this long after it began, wherever the page has got to.
    static let restoreWindow: TimeInterval = 1.5
    private static let restoreStep: TimeInterval = 0.016

    var readingMemory: PlanScrollMemory? {
        get { scrolling.memory }
        set { scrolling.memory = newValue }
    }

    // MARK: Reading the layout

    /// The page's top edge in text-container coordinates; nil outside a scroll view. The anchor is
    /// taken at the edge, not at the reading line under the pinned block (`readingLine`): how much
    /// the block covers is decided by the pane after the page is back, and a position measured
    /// from it would land a block's height off.
    var viewportTop: CGFloat? {
        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return nil }
        return textView.convert(clip.bounds, from: clip).minY - textView.textContainerOrigin.y
    }

    /// The line at the top of the page, as an anchor; nil when nothing is laid out there.
    func readingAnchor() -> PlanReadingAnchor? {
        guard let textView, let readY = viewportTop, let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: max(readY, 0))) else { return nil }
        let top = fragment.layoutFragmentFrame.minY
        guard let line = fragment.textLineFragments.last(where: { top + $0.typographicBounds.minY <= readY })
                ?? fragment.textLineFragments.first else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return .at(start + line.characterRange.location, within: readY - (top + line.typographicBounds.minY),
                   in: textView.string as NSString, headings: headings)
    }

    /// Where the line starting at `offset` is, in text-container coordinates — the plan laid out
    /// from its top to that line first, so the answer is exact rather than an estimate that
    /// moves when the lines above it are laid out.
    func lineTop(at offset: Int) -> CGFloat? {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        let start = content.documentRange.location
        let length = (textView.string as NSString).length
        // Inside a folded section there is no line: its heading is where it shows.
        let location = visibleProxy(NSRange(location: min(max(offset, 0), length), length: 0)).location
        guard let at = content.location(start, offsetBy: location),
              let range = NSTextRange(location: start, end: content.location(at, offsetBy: 1) ?? at) else { return nil }
        layout.ensureLayout(for: range)
        guard let fragment = layout.textLayoutFragment(for: at) else { return nil }
        let relative = location - content.offset(from: start, to: fragment.rangeInElement.location)
        let line = fragment.textLineFragments.last { $0.characterRange.location <= relative } ?? fragment.textLineFragments.first
        return fragment.layoutFragmentFrame.minY + (line?.typographicBounds.minY ?? 0)
    }

    // MARK: Saving

    /// The page scrolled or the text moved: when it has been still for `readingQuiet`, the layout
    /// is read once and the position saved. A scroll tick costs a timestamp, never a layout.
    func scrollTick() {
        if scrolling.target != nil {
            // The human scrolling before the page got there takes the position out of the restore's hands.
            if let applied = scrolling.appliedY, let clip = textView?.enclosingScrollView?.contentView,
               abs(clip.bounds.minY - applied) > 1.5 { finishReadingRestore() }
            return
        }
        guard scrolling.live, scrolling.memory != nil else { return }
        scrolling.lastTick = CACurrentMediaTime()
        guard !scrolling.saveScheduled else { return }
        scrolling.saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readingQuiet) { [weak self] in self?.readingQuietCheck() }
    }

    private func readingQuietCheck() {
        let still = CACurrentMediaTime() - scrolling.lastTick
        guard still >= Self.readingQuiet - 0.01 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readingQuiet - still) { [weak self] in self?.readingQuietCheck() }
            return
        }
        scrolling.saveScheduled = false
        rememberReading()
    }

    /// Reads the position from the layout into the memory now.
    func rememberReading() {
        guard scrolling.live, let memory = scrolling.memory, scrolling.target == nil, let anchor = readingAnchor() else { return }
        if memory.anchor != anchor { memory.anchor = anchor }
    }

    /// The editor is leaving its window (the project view is being replaced): the last position
    /// and the caret go to the memory before the layout goes. A restore that never finished
    /// leaves the saved position as it was.
    func leavingReading() {
        guard scrolling.memory != nil else { return }
        if scrolling.target != nil { return finishReadingRestore(live: false) }
        guard scrolling.live, let textView else { return }
        rememberReading()
        scrolling.memory?.selection = textView.selectedRange()
        scrolling.memory?.focused = textView.isFocused
        scrolling.live = false
    }

    /// The caret moved, or the keyboard came or went.
    func rememberCaret() {
        guard scrolling.live, let memory = scrolling.memory, let textView else { return }
        memory.selection = textView.selectedRange()
        memory.focused = textView.isFocused
    }

    // MARK: Restoring

    /// Puts the page back at `anchor` once the plan is laid out as far as it, and the page tall
    /// enough to scroll there. Tried now, when the editor reaches a window, and every frame until
    /// it lands or `restoreWindow` is out.
    func beginReadingRestore(_ anchor: PlanReadingAnchor) {
        scrolling.target = anchor
        scrolling.live = false
        scrolling.deadline = Date().addingTimeInterval(Self.restoreWindow)
        scrolling.appliedY = nil
        scrolling.held = 0
        scrolling.unreachable = 0
        stepReadingRestore()
        pollReadingRestore()
    }

    private func pollReadingRestore() {
        guard scrolling.target != nil, !scrolling.polling else { return }
        scrolling.polling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreStep) { [weak self] in
            guard let self else { return }
            self.scrolling.polling = false
            self.stepReadingRestore()
            self.pollReadingRestore()
        }
    }

    func stepReadingRestore() {
        guard let target = scrolling.target else {
            // Back in a window with nothing to restore (the view was only moved): the layout is the human's.
            scrolling.live = scrolling.loaded
            return
        }
        guard let textView else { return finishReadingRestore() }
        let expired = Date() > scrolling.deadline
        guard textView.window != nil, let scroll = textView.enclosingScrollView, textView.frame.width > 1,
              let top = lineTop(at: target.offset) else {
            if expired { finishReadingRestore() }
            return
        }
        restoreKeyboard(in: textView)
        let clip = scroll.contentView
        let wanted = textView.convert(NSPoint(x: 0, y: top + target.within + textView.textContainerOrigin.y), to: clip)
        let desired = NSRect(origin: NSPoint(x: clip.bounds.minX, y: wanted.y), size: clip.bounds.size)
        let landed = clip.constrainBoundsRect(desired)
        var reachable = abs(landed.minY - desired.minY) < 0.5
        if !reachable, !textView.layingOutWholePlan {
            // All laid out and the page still shorter than the position: the plan is shorter now, or
            // SwiftUI has yet to take its height. Give it a few frames, then take the nearest.
            scrolling.unreachable += 1
            reachable = scrolling.unreachable >= 4
        }
        guard reachable || expired else {
            // Not there yet: hold the pane out of sight rather than show the top of the document.
            if scrolling.hidden == nil, scroll.alphaValue > 0, abs(clip.bounds.minY - desired.minY) > 1 {
                scrolling.hidden = scroll
                scroll.alphaValue = 0
            }
            return
        }
        if abs(clip.bounds.minY - landed.minY) > 0.5 {
            clip.scroll(to: landed.origin)
            scroll.reflectScrolledClipView(clip)
            scrolling.applied()
            scrolling.held = 0
        } else {
            scrolling.held += 1
        }
        scrolling.appliedY = clip.bounds.minY
        scrolling.hidden?.alphaValue = 1
        scrolling.hidden = nil
        // Held in place while the rest of the plan is laid out and the pane settles: the lines
        // above the position keep their height, but whatever sits above the plan may not.
        if expired || (!textView.layingOutWholePlan && scrolling.held >= 3) { finishReadingRestore() }
    }

    /// The page is where it should be, or the restore gave up or was overtaken: the editor's
    /// layout is the human's again.
    func finishReadingRestore(live: Bool = true) {
        scrolling.target = nil
        scrolling.hidden?.alphaValue = 1
        scrolling.hidden = nil
        if live { scrolling.live = true }
        if let range = scrolling.flash {
            scrolling.flash = nil
            if range.upperBound <= (textView?.string as NSString?)?.length ?? 0 { textView?.showFindIndicator(for: range) }
        }
    }

    /// Takes the page to `range` (opening any fold that hides it) and flashes it when it lands:
    /// the quote a note was written on, a little below the pinned block rather than under it.
    func reveal(_ range: NSRange) {
        guard let textView else { return }
        unfold(containing: range)
        scrolling.flash = range
        beginReadingRestore(.at(range.location, within: -((textView.obscuredTop) + Self.revealMargin),
                                in: textView.string as NSString, headings: headings))
    }

    private static let revealMargin: CGFloat = 48

    /// The keyboard back in the editor that had it, before the page is put back: with the caret's
    /// block showing its syntax the lines are the height they were when the position was read.
    private func restoreKeyboard(in textView: PlanNSTextView) {
        guard scrolling.restoreFocus else { return }
        scrolling.restoreFocus = false
        // Not from another editor that has the keyboard already (the composer opened to type in).
        guard textView.isEditable, let window = textView.window, !(window.firstResponder is NSText) else { return }
        // Taking the keyboard must not move the page: AppKit reveals the caret as it does.
        let clip = textView.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        window.makeFirstResponder(textView)
        if let clip, let origin, clip.bounds.origin != origin {
            clip.scroll(to: origin)
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// A text is being loaded: what the editor shows is remembered first if it is a text being
    /// replaced, then the position is put back in the new one — the same paragraph if it is still
    /// there, else the same section's heading, else the top of the plan (`relocated`).
    func readingBeforeLoad() -> PlanReadingAnchor? {
        guard scrolling.memory != nil else { return nil }
        guard scrolling.loaded else { return scrolling.memory?.anchor }
        return scrolling.target ?? readingAnchor() ?? scrolling.memory?.anchor
    }

    func resumeReading(_ reading: PlanReadingAnchor?, in text: String, firstLoad: Bool) {
        scrolling.loaded = true
        // "Show in that version" has the page go to the note's quote, not to where it was reading.
        if let range = MainActor.assumeIsolated({ notesBridge.takeReveal(in: text) }) { return reveal(range) }
        guard let memory = scrolling.memory else { return }
        if firstLoad, memory.focused, let selection = memory.selection, NSMaxRange(selection) <= (text as NSString).length {
            textView?.setSelectedRange(selection)
            scrolling.restoreFocus = true
        }
        guard let reading else {
            scrolling.live = true
            return
        }
        var (anchor, match) = reading.relocated(in: text as NSString, headings: headings)
        // A heading, or the top, goes just under the pinned block rather than behind it.
        if match == .section || match == .top { anchor.within = -(textView?.obscuredTop ?? 0) }
        beginReadingRestore(anchor)
    }
}
