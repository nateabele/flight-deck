import AppKit
import IntakeKit
import SwiftUI

enum EditPolicy {
    /// Commit when editing ends or after `idle` seconds without a keystroke; never per
    /// keystroke — every commit appends the WHOLE plan to `commands.jsonl`, which never compacts.
    static let idle: TimeInterval = 2

    /// While the view is first responder with uncommitted edits, a new head is NOT swapped in;
    /// the banner offers it. Anything else is safe to replace: a focused view with nothing
    /// uncommitted has nothing to lose, and an unfocused one committed on its way out.
    static func shouldReplace(editing: Bool, dirty: Bool) -> Bool {
        !(editing && dirty)
    }
}

/// The editor's text, what was last committed, and the idle debounce — pure, with the clock
/// passed in, so "never per keystroke" and "never under an active edit" are testable without
/// a window or a timer.
struct PlanEditSession {
    private(set) var current: String
    /// The text as last loaded or committed; `current` differing from it is an uncommitted edit.
    private(set) var committed: String
    private(set) var lastKeystroke: Date?
    /// A head that arrived while replacing the text would have lost keystrokes; the banner
    /// offers it.
    private(set) var held: String?
    var editing = false

    init(text: String) {
        current = text
        committed = text
    }

    var dirty: Bool { current != committed }

    mutating func type(_ text: String, at now: Date) {
        current = text
        lastKeystroke = now
    }

    /// The text to commit once `EditPolicy.idle` has passed since the last keystroke — once
    /// per burst of typing, not once per tick after it.
    mutating func commitIfIdle(now: Date) -> String? {
        guard dirty, let last = lastKeystroke, now.timeIntervalSince(last) >= EditPolicy.idle else { return nil }
        return flush()
    }

    /// Editing ended (focus left, or the view is going away): commit now, without waiting.
    mutating func endEditing() -> String? {
        editing = false
        return flush()
    }

    /// Whatever is uncommitted, marked committed — nil when there is nothing.
    mutating func flush() -> String? {
        guard dirty else { return nil }
        committed = current
        return current
    }

    /// A new text for the editor (a round landed, or another checkpoint was chosen). Taken at
    /// once when `EditPolicy` allows, otherwise held for the banner. Returns whether it replaced.
    mutating func offer(_ text: String) -> Bool {
        guard EditPolicy.shouldReplace(editing: editing, dirty: dirty) else {
            held = text
            return false
        }
        load(text)
        return true
    }

    /// The parent withdrew its offer (the human went back to the checkpoint on screen).
    mutating func dropHeld() { held = nil }

    /// Replaces the text outright — the parent asked for it, or the human pressed "Show it".
    mutating func load(_ text: String) {
        current = text
        committed = text
        held = nil
        lastKeystroke = nil
    }
}

/// The plan as live-preview Markdown (spec §7.1): an AppKit `NSTextView` on TextKit 2, since
/// SwiftUI's `TextEditor` can't style ranges of its own text. The storage holds the raw
/// Markdown; `MarkdownStyler` renders it with attributes, revealing the syntax of the block
/// holding the caret only.
///
/// `text` is what the editor was loaded with or last committed — the parent changing it is a
/// load. `incoming` is a newer text the parent would like shown (a round landed); the view
/// takes it only when `EditPolicy` allows and otherwise shows "A new round landed · Show it".
/// Either way it calls `onShowIncoming` when it takes it, and the parent moves `incoming`
/// into `text`. An `incoming` the human asked for (`incomingIsNavigation`: they chose another
/// round) is never held: their edit is committed and the chosen text loads at once.
///
/// VoiceOver reads the raw Markdown, hidden syntax included: the hiding is a font and a
/// colour, which accessibility ignores. Accepted — the text VoiceOver reads is exactly the
/// text the human edits, and "hash hash Settings" is honest about what is stored.
struct PlanTextView: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let onCommit: (String) -> Void
    let incoming: String?
    let onShowIncoming: () -> Void
    var incomingIsNavigation = false
    var theme: PlanTheme = .standard
    /// The agents' plan under `text` — set, the human's edits over it draw as a layer
    /// (`EditLayer`); nil draws none.
    var generated: String?
    /// Highlight-and-annotate (spec §7.3): note highlights, the selection toolbar and the
    /// rail's line positions, all in `PlanNotesBridge`. Nil leaves the editor as a plain editor.
    var notes: PlanNotesController?
    /// The convergence churn lane beside the headings (spec §8.2); nil hides it.
    var churn: ChurnLaneInput?
    /// The parent's way to act through the editor — see `PlanEditorHandle`.
    var handle: PlanEditorHandle?
    /// Where the folded sections are kept — the intake's (`IntakeService.planFolds`), so they
    /// outlive this view; nil keeps them in the editor for as long as it lives.
    var folds: PlanFoldStore?

    init(text: Binding<String>, editable: Bool, onCommit: @escaping (String) -> Void, incoming: String?,
         onShowIncoming: @escaping () -> Void, incomingIsNavigation: Bool = false) {
        _text = text
        self.editable = editable
        self.onCommit = onCommit
        self.incoming = incoming
        self.onShowIncoming = onShowIncoming
        self.incomingIsNavigation = incomingIsNavigation
    }

    /// Draws the human's edits over `generated`, the agents' plan for the same checkpoint.
    func editLayer(generated: String?) -> PlanTextView {
        var copy = self
        copy.generated = generated
        return copy
    }

    /// This view with the churn lane showing `input` — a modifier rather than an init
    /// parameter, so the lane is one line at the call site.
    func churnLane(_ input: ChurnLaneInput?) -> PlanTextView {
        var view = self
        view.churn = input
        return view
    }

    /// Lets the parent act through the editor (Revert all) — see `PlanEditorHandle`.
    func handle(_ handle: PlanEditorHandle?) -> PlanTextView {
        var view = self
        view.handle = handle
        return view
    }

    /// Keeps the folded sections in `store` — see `folds`.
    func folds(_ store: PlanFoldStore?) -> PlanTextView {
        var view = self
        view.folds = store
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func annotating(_ notes: PlanNotesController?) -> PlanTextView {
        var view = self
        view.notes = notes
        return view
    }

    func makeNSView(context: Context) -> PlanEditorContainer {
        let container = PlanEditorContainer(onShow: { [weak coordinator = context.coordinator] in coordinator?.showHeld() })
        let coordinator = context.coordinator
        coordinator.textView = container.textView
        container.textView.onFocusChange = { [weak coordinator] in coordinator?.focusChanged() }
        if let folds { coordinator.foldStore = folds }
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        container.textView.onHover = { [weak container, weak coordinator] point in
            container?.revert.hover(at: point)
            coordinator?.hoverFold(at: point)
            MainActor.assumeIsolated { coordinator?.notesBridge.hover(at: point) }
        }
        container.revert.onRevert = { [weak coordinator] in coordinator?.revert(hunk: $0) }
        coordinator.revertButton = container.revert
        coordinator.load(text)
        return container
    }

    /// As tall as its text (`PlanEditorContainer.contentHeight`), at whatever width it is
    /// offered: the plan is part of the page, which scrolls it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView container: PlanEditorContainer, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? container.frame.width
        return CGSize(width: width, height: container.contentHeight)
    }

    func updateNSView(_ container: PlanEditorContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.textView.isEditable = editable
        container.textView.obscuredTop = context.environment.pageObscuredTop
        // While a commit's binding write is still queued, `text` is the pre-commit value; loading
        // it would put back the text the human just replaced.
        if coordinator.inFlight == 0, text != coordinator.lastBound { coordinator.load(text) }
        coordinator.receive(incoming, navigation: incomingIsNavigation)
        container.bannerVisible = coordinator.session.held != nil
        coordinator.layEditLayer(over: generated)
        container.revert.enabled = editable
        coordinator.notesBridge.attach(notes, to: container.textView)
        coordinator.reading = context.environment.planReading
        container.churnLane.update(churn)
        coordinator.churnChanged()
        handle?.coordinator = coordinator
    }

    static func dismantleNSView(_ container: PlanEditorContainer, coordinator: Coordinator) {
        // Switching to the diff, or away from the intake, must not drop the last two seconds
        // of typing.
        coordinator.timer?.invalidate()
        coordinator.undo.removeAllActions()
        if let text = coordinator.session.endEditing() { coordinator.commit(text) }
        coordinator.notesBridge.detach()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: PlanTextView
        var session = PlanEditSession(text: "")
        /// The last `text` binding value seen or written, so `updateNSView` can tell a load
        /// from the parent apart from its own commit echoing back.
        var lastBound = ""
        weak var textView: PlanNSTextView? {
            didSet { if textView !== oldValue { attachFolding() } }
        }
        weak var revertButton: EditRevertButton?
        var timer: Timer?
        /// The editor's own undo stack, via `undoManager(for:)`, rather than the window's. It
        /// is emptied on every load: its actions are ranges into the text they were typed
        /// into, so ⌘Z after a new head loaded would splice stale edits into it — and the idle
        /// timer would then commit the corrupted plan.
        let undo = UndoManager()
        /// The editor's notes seam (spec §7.3). Main-actor like everything the delegate
        /// callbacks it is called from do; hence `assumeIsolated` at each call.
        let notesBridge = PlanNotesBridge()
        /// Commits whose binding write hasn't run yet — see `commit`.
        private(set) var inFlight = 0
        /// The incoming text already handed to `onShowIncoming`, so a second view update
        /// before the parent swaps it in doesn't ask twice.
        private var taking: String?
        private var blocks: [MarkdownBlock] = []
        private var revealed: Int?
        /// The one character edit since the last restyle, if exactly one; nil after several
        /// (a paste-and-undo in one event), which falls back to a full restyle.
        private var pendingEdit: (range: NSRange, delta: Int)?
        private var editCount = 0
        /// The edit layer: the agents' plan it was diffed against, the marks drawn, and the
        /// hunks Revert puts back — all as of the text in the view.
        private var layerBase: String?
        private var marks: [EditMark] = []
        private(set) var hunks: [PlanHunk] = []
        /// The insertion tint, as its own decoration layer (`DecorationLayer`).
        let editTint = DecorationLayer(key: "edits")
        /// The amber highlight on the sentences a hot section keeps rewriting (spec §8.2), its
        /// own layer. Both layers paint `.backgroundColor`, and removing a rendering attribute
        /// removes it whoever set it, so the two must never share a character: the churn ranges
        /// are cut around every insertion and laid first, then the edit tint — the insertion wins.
        let churnTint = DecorationLayer(key: "churn")
        /// Each hot section's proposals for the cycle the tint was found from — read from the
        /// checkpoints' files once per cycle, not on every keystroke.
        private var churnVersions: (cycle: ConvergenceCycle, bySection: [String: [SectionVersion]])?
        /// Where the hot sections were when the churn tint was last laid, moved with each edit
        /// since. A keystroke outside them leaves the tint as it is (rendering attributes move
        /// with the text): finding the flipping sentences is a pass over the whole plan.
        private var churnSpans: [NSRange]?

        private var undoObservers: [NSObjectProtocol] = []

        init(_ parent: PlanTextView) {
            self.parent = parent
            super.init()
            // ⌘Z and ⇧⌘Z change the text without a `textDidChange` (measured: NSTextView's
            // undo of a replacement posts no NSText change), which left the edit layer, the
            // notes and the idle commit on the text from before the undo — an undone Revert
            // all showed the plan with no edits marked and never sent it.
            undoObservers = [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
                NotificationCenter.default.addObserver(forName: name, object: undo, queue: nil) { [weak self] _ in
                    guard let self, let textView = self.textView, textView.string != self.session.current else { return }
                    self.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                }
            }
        }

        deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

        func load(_ text: String) {
            lastBound = text
            session.load(text)
            guard let textView, let storage = textView.textStorage else { return }
            if textView.string != text { textView.string = text }
            undo.removeAllActions()
            blocks = MarkdownStyler.blocks(text)
            outline = nil
            // A new text (a round landed): folds follow their headings by text, and a fold
            // whose heading is gone is dropped.
            foldStore.folds.reconcile(with: headings)
            applyFolds(relayout: true)
            revealed = caretBlock()
            diffEditLayer(base: parent.generated, text: text)
            style(storage, indices: nil, reveal: revealed)
            pendingEdit = nil
            editCount = 0
            taking = nil
            MainActor.assumeIsolated { notesBridge.textChanged() }
            textView.layOutWholePlan()
        }

        func receive(_ incoming: String?, navigation: Bool) {
            guard let incoming else { return session.dropHeld() }
            guard incoming != taking else { return }
            if navigation {
                // The human chose another round: that is not news to hold back. Their edit is
                // committed to the checkpoint it was typed on, then the choice loads.
                timer?.invalidate()
                session.dropHeld()
                if let text = session.flush() { commit(text) }
                return takeIncoming(incoming)
            }
            guard incoming != session.held else { return }
            session.editing = isFirstResponder
            // Typed text identical to the new head loses nothing by being replaced by it.
            if incoming == session.current || EditPolicy.shouldReplace(editing: session.editing, dirty: session.dirty) {
                // Commit anything unfocused-but-uncommitted before it is replaced.
                if incoming != session.current, let text = session.flush() { commit(text) }
                takeIncoming(incoming)
            } else {
                _ = session.offer(incoming)
            }
        }

        /// "Show it": the human's edit so far is committed to the checkpoint it was typed on,
        /// then the new head is taken.
        func showHeld() {
            timer?.invalidate()
            guard let held = session.held else { return }
            if let text = session.flush() { commit(text) }
            takeIncoming(held)
        }

        private func takeIncoming(_ text: String) {
            taking = text
            // The parent swaps `incoming` into `text`; the next `updateNSView` loads it. Async:
            // this runs inside a view update, where writing SwiftUI state is not allowed.
            let show = parent.onShowIncoming
            DispatchQueue.main.async { show() }
        }

        /// Async because two callers run inside a SwiftUI update (`dismantleNSView`, and
        /// `receive` from `updateNSView`), where writing state is not allowed; the rest go the
        /// same way so commits and `onShowIncoming` stay in one FIFO order.
        func commit(_ text: String) {
            lastBound = text
            inFlight += 1
            let parent = parent
            DispatchQueue.main.async { [weak self] in
                parent.text = text
                parent.onCommit(text)
                self?.inFlight -= 1
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        private var isFirstResponder: Bool { textView?.isFocused ?? false }

        /// The block whose syntax shows: the caret's, and only while the editor has focus — an
        /// unfocused plan reads fully rendered, with no stray `##` where the caret last was.
        private func caretBlock() -> Int? {
            guard let textView, textView.isFocused else { return nil }
            return MarkdownStyler.blockIndex(at: textView.selectedRange().location, in: blocks)
        }

        /// Focus came or went: reveal or re-hide the caret block's syntax.
        func focusChanged() {
            MainActor.assumeIsolated { notesBridge.focusChanged() }
            guard let storage = textView?.textStorage else { return }
            let next = caretBlock()
            guard next != revealed else { return }
            style(storage, indices: [revealed, next].compactMap { $0 }, reveal: next)
            revealed = next
        }

        /// Every styler pass goes through here, so the edit layer is laid back over exactly
        /// the blocks the styler just reset (`EditLayer.apply`'s contract).
        private func style(_ storage: NSTextStorage, indices: [Int]?, reveal: Int?) {
            if let indices {
                MarkdownStyler.restyle(storage, blocks: blocks, indices: indices, revealBlock: reveal, theme: parent.theme)
                let ranges = Set(indices).filter(blocks.indices.contains).map { i -> NSRange in
                    let r = blocks[i].range
                    return NSRange(location: r.location, length: min(r.length + 1, storage.length - r.location))
                }
                EditLayer.apply(marks, to: storage, within: ranges, theme: parent.theme)
            } else {
                MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: reveal, theme: parent.theme)
                EditLayer.apply(marks, to: storage, within: nil, theme: parent.theme)
            }
        }

        // MARK: Edit layer

        /// Re-diffs the layer; returns the blocks whose marks changed, which must be restyled
        /// to take the new marks (and shed the old). `shift` moves the old marks past an edit
        /// the way the storage moved their attributes, so marks the edit didn't touch compare
        /// equal and cost nothing.
        @discardableResult
        private func diffEditLayer(base: String?, text: String, shift: (at: Int, by: Int)? = nil, edit: TextEdit? = nil) -> [Int] {
            layerBase = base
            let old = marks
            (marks, hunks) = base.map { EditLayer.marks(generated: $0, edited: text) } ?? ([], [])
            revertButton?.spans = EditLayer.spans(hunks, edited: text)
            layTints(text, edit: edit)
            func key(_ m: EditMark, moved: Bool) -> String {
                var r = m.range
                if moved, let shift, r.location >= shift.at { r.location += shift.by }
                return "\(m.kind)|\(r.location)|\(r.length)|\(m.inline)|\(m.ghost)"
            }
            let before = Set(old.map { key($0, moved: true) })
            let after = Set(marks.map { key($0, moved: false) })
            let changed = old.filter { !after.contains(key($0, moved: true)) }.map { m -> Int in
                var r = m.range
                if let shift, r.location >= shift.at { r.location += shift.by }
                return r.location
            } + marks.filter { !before.contains(key($0, moved: false)) }.map { $0.range.location }
            let length = (text as NSString).length
            return Set(changed.map { min($0, max(length - 1, 0)) }.compactMap { MarkdownStyler.blockIndex(at: $0, in: blocks) }).sorted()
        }

        /// Lays the churn highlight and then the edit tint over `text` — see `churnTint`. After
        /// one keystroke (`edit`) the churn highlight is re-found only if the edit is in a hot
        /// section or on a heading.
        func layTints(_ text: String, edit: TextEdit? = nil) {
            guard let layout = textView?.textLayoutManager else { return }
            let edits = EditLayer.tints(marks, in: text)
            if let edit, let spans = churnSpans, !touchesChurn(edit, spans: spans, in: text as NSString) {
                churnSpans = spans.map(edit.stretch)
            } else {
                churnTint.apply(churnRanges(text, avoiding: edits.map(\.0)).map { ($0, [.backgroundColor: Self.churnColor]) }, to: layout)
            }
            editTint.apply(edits, to: layout)
        }

        /// The churn lane's input changed (a round landed): re-find the flipping sentences.
        func churnChanged() {
            guard let textView, churnVersions?.cycle != parent.churn?.cycle else { return }
            layTints(textView.string)
        }

        /// Whether `edit` lands in (or at an edge of) a hot section, or on a heading line.
        private func touchesChurn(_ edit: TextEdit, spans: [NSRange], in ns: NSString) -> Bool {
            let moved = spans.map(edit.stretch)
            if moved.contains(where: { edit.range.location <= NSMaxRange($0) && NSMaxRange(edit.range) >= $0.location }) { return true }
            let line = ns.lineRange(for: NSRange(location: min(edit.range.location, ns.length), length: 0))
            return ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }

        static let churnColor = NSColor(LCDMetrics.color(.amber)).withAlphaComponent(0.16)

        /// Each of `sections` (heading lines, trimmed) from its heading to the next one.
        static func sectionSpans(_ sections: Set<String>, in ns: NSString) -> [NSRange] {
            guard !sections.isEmpty else { return [] }
            var out: [NSRange] = []
            var open: Int?
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                // `hasPrefix` on the raw line first: only a heading line is worth a substring.
                if ns.character(at: line.location) == 35 {
                    if let start = open { out.append(NSRange(location: start, length: line.location - start)); open = nil }
                    if sections.contains(ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)) { open = line.location }
                }
                location = NSMaxRange(line)
            }
            if let start = open { out.append(NSRange(location: start, length: ns.length - start)) }
            return out
        }

        private func churnRanges(_ text: String, avoiding insertions: [NSRange]) -> [NSRange] {
            guard let churn = parent.churn else { churnVersions = nil; churnSpans = []; return [] }
            if churnVersions?.cycle != churn.cycle {
                let hot = HeatmapModel.hotSections(churn.cycle)
                churnVersions = (churn.cycle, Dictionary(uniqueKeysWithValues: hot.map { ($0, churn.versions($0)) }))
            }
            churnSpans = Self.sectionSpans(Set(churnVersions?.bySection.keys.map { $0 } ?? []), in: text as NSString)
            let found = churnVersions?.bySection.flatMap { section, versions in
                ChurnLaneModel.flippingSentences(in: text, section: section, versions: versions)
            } ?? []
            return ChurnLaneModel.subtracting(found, insertions)
        }

        /// The parent's agents' plan changed under the same text (a checkpoint with the same
        /// words): re-diff and restyle what moved.
        func layEditLayer(over generated: String?) {
            guard generated != layerBase, let textView, let storage = textView.textStorage else { return }
            let changed = diffEditLayer(base: generated, text: textView.string)
            style(storage, indices: changed + [revealed].compactMap { $0 }, reveal: revealed)
        }

        /// Hover Revert: that hunk goes back to the agents' text as an ordinary edit — undoable,
        /// restyled like typing — and is committed at once, being an explicit action.
        func revert(hunk index: Int) {
            guard let textView, let base = layerBase, hunks.indices.contains(index),
                  let reverted = PlanLayers.revert(hunks[index], generated: base, edited: textView.string) else { return }
            replace(with: reverted, actionName: "Revert Edit")
        }

        /// "Revert all": every hunk back to the agents' plan as ONE undoable change — ⌘Z brings
        /// every edit back, and the typing before it stays on the stack under it. Through the
        /// editor, never a load: a load empties the undo stack, which made Revert all final.
        func revertAll() {
            guard let textView, let base = layerBase, textView.string != base else { return }
            replace(with: base, actionName: "Revert All Edits")
        }

        /// Replaces the text with `new` as the smallest single edit — undoable as one step named
        /// `actionName`, restyled like typing — and commits it at once.
        private func replace(with new: String, actionName: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let old = textView.string as NSString, new = new as NSString
            var front = 0
            while front < old.length, front < new.length, old.character(at: front) == new.character(at: front) { front += 1 }
            var back = 0
            while back < old.length - front, back < new.length - front,
                  old.character(at: old.length - 1 - back) == new.character(at: new.length - 1 - back) { back += 1 }
            let range = NSRange(location: front, length: old.length - front - back)
            let replacement = new.substring(with: NSRange(location: front, length: new.length - front - back))
            // Its own undo step: typing just before it would otherwise coalesce with it, and ⌘Z
            // would take back the typing and the revert together.
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            undo.setActionName(actionName)
            textView.breakUndoCoalescing()
            timer?.invalidate()
            if let text = session.flush() { commit(text) }
        }

        // MARK: Folding

        /// Where this editor's folds live — the parent's store when it hands one in.
        var foldStore = PlanFoldStore()
        let foldFilter = PlanFoldFilter()
        let foldGutter = PlanFoldGutter()
        /// Where the pane shows the section being read; set from the environment.
        var reading: PlanReadingPosition? {
            didSet {
                guard reading !== oldValue else { return }
                MainActor.assumeIsolated { reading?.jump = { [weak self] in self?.jumpToReadingHeading() } }
                readingMoved()
            }
        }
        /// The headings of the text in the view, found on demand and dropped on every change.
        private var outline: [PlanHeading]?

        var headings: [PlanHeading] {
            if let outline { return outline }
            let found = PlanOutline.headings(blocks, in: (textView?.string ?? "") as NSString)
            outline = found
            return found
        }

        /// Hooks the hiding filter, the chevrons and the text view's fold actions to a new view.
        private func attachFolding() {
            guard let textView else { return }
            (textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = foldFilter
            textView.onFoldClick = { [weak self] point in self?.clickFold(at: point) ?? false }
            textView.onFoldKey = { [weak self] fold in self?.foldCaretSection(fold) ?? false }
            textView.visibleProxy = { [weak self] range in self?.visibleProxy(range) ?? range }
            textView.outline = { [weak self] in self?.headings ?? [] }
            textView.onScroll = { [weak self] in self?.layOutFoldGutter() }
            foldGutter.measure = { [weak self] in self?.foldMarks() ?? [] }
            textView.addSubview(foldGutter, positioned: .below, relativeTo: nil)

            layOutFoldGutter()
        }

        /// Hides exactly the folded bodies. `relayout` re-lays the plan: needed when what is
        /// folded changed; an edit that only moved the hidden ranges moves the laid-out
        /// paragraphs with it.
        func applyFolds(relayout: Bool) {
            let hidden = foldStore.folds.hidden(in: headings)
            guard relayout || hidden != foldFilter.hidden else { return }
            let changed = hidden.count != foldFilter.hidden.count
            foldFilter.hidden = hidden
            if relayout || changed, let textView, let layout = textView.textLayoutManager {
                layout.invalidateLayout(for: layout.documentRange)
                textView.needsLayout = true
                textView.needsDisplay = true
                textView.layOutWholePlan()
            }
            layOutFoldGutter()
        }

        /// A keystroke: the folds follow their headings through it (a folded heading retyped
        /// stays folded), and the hidden ranges move with the text.
        private func foldsFollowEdit() {
            let old = outline
            outline = nil
            if foldStore.folds.isEmpty { return layOutFoldGutter() }
            let before = foldStore.folds
            if let old { foldStore.folds.carry(from: old, to: headings) } else { foldStore.folds.reconcile(with: headings) }
            applyFolds(relayout: before.folded.count != foldStore.folds.folded.count)
        }

        func toggleFold(_ key: PlanFoldKey) {
            guard let index = headings.firstIndex(where: { $0.key == key }) else { return }
            setFold(index, !foldStore.folds.isFolded(key))
        }

        /// Folds or opens heading `index`'s section. Folding with the caret inside it moves the
        /// caret to the end of the heading first: a caret left in hidden text would open it again.
        private func setFold(_ index: Int, _ fold: Bool) {
            guard let textView, headings.indices.contains(index) else { return }
            let heading = headings[index]
            guard !fold || heading.body.length > 0 else { return }
            let caret = textView.selectedRange()
            if fold, NSLocationInRange(caret.location, heading.body) || (caret.location == NSMaxRange(heading.body) && caret.location > heading.body.location) {
                textView.setSelectedRange(NSRange(location: NSMaxRange(heading.line), length: 0))
            }
            foldStore.folds.set(heading.key, folded: fold)
            applyFolds(relayout: true)
        }

        /// ⌥⌘← / ⌥⌘→: fold or open the section holding the caret. Opening also works on a
        /// folded heading's own line.
        func foldCaretSection(_ fold: Bool) -> Bool {
            guard let textView, let index = PlanOutline.innermost(containing: textView.selectedRange().location, in: headings) else { return false }
            // Folding an already-folded section, or with nothing under it, folds its parent.
            var target = index
            if fold {
                while foldStore.folds.isFolded(headings[target].key) || headings[target].body.length == 0 {
                    guard let parent = headings[..<target].lastIndex(where: { $0.level < headings[target].level }) else { return true }
                    target = parent
                }
            }
            setFold(target, fold)
            return true
        }

        /// Opens every folded section hiding any of `range`.
        func unfold(containing range: NSRange) {
            guard !foldStore.folds.isEmpty, foldFilter.hidden.contains(where: { NSLocationInRange(range.location, $0) }) else { return }
            for heading in headings where foldStore.folds.isFolded(heading.key)
                && NSLocationInRange(range.location, heading.body) {
                foldStore.folds.set(heading.key, folded: false)
            }
            applyFolds(relayout: true)
        }

        /// A range as far as the page can show it: inside a folded section, its heading line —
        /// where a note on hidden words sits in the rail, instead of among the detached ones.
        func visibleProxy(_ range: NSRange) -> NSRange {
            guard foldFilter.contains(range.location) else { return range }
            return headings.last { foldStore.folds.isFolded($0.key) && NSLocationInRange(range.location, $0.body) }?.line ?? range
        }

        private func clickFold(at point: NSPoint) -> Bool {
            guard let mark = foldGutter.hit(point) else { return false }
            toggleFold(mark.key)
            return true
        }

        func hoverFold(at point: NSPoint?) {
            foldGutter.hovered = point.flatMap { p in foldGutter.marks.first { p.y >= $0.line.minY && p.y < $0.line.maxY }?.key }
        }

        /// The chevrons and the reading position follow the text: sized to it, redrawn over what is
        /// on screen.
        func layOutFoldGutter() {
            guard let textView else { return }
            if foldGutter.frame != textView.bounds { foldGutter.frame = textView.bounds }
            readingMoved()
            foldGutter.chevronX = textView.textContainerOrigin.x + PlanGutter.chevronCenter
            foldGutter.refresh(textView.visibleRect)
        }

        /// The page's reading line — just under the pinned block — in text-container
        /// coordinates; nil outside a scroll view.
        private var readingLine: CGFloat? {
            guard let textView, let clip = textView.enclosingScrollView?.contentView else { return nil }
            return textView.convert(clip.bounds, from: clip).minY + textView.obscuredTop - textView.textContainerOrigin.y
        }

        /// The section being read: the heading of the section at the reading line, when that
        /// heading has scrolled above it; nil while it is on screen, or above the first heading.
        /// Found by position, not from TextKit's viewport range, which trails a scroll until the
        /// next layout; and from the one or two headings around the reading line, never all:
        /// measuring every heading of a long plan was a layout lookup each per keystroke.
        func readingHeading() -> (heading: PlanHeading, top: CGFloat)? {
            guard let readY = readingLine, let layout = textView?.textLayoutManager, let content = layout.textContentManager else { return nil }
            let at = layout.textLayoutFragment(for: CGPoint(x: 1, y: max(readY, 0)))
                .map { content.offset(from: content.documentRange.location, to: $0.rangeInElement.location) } ?? 0
            let visible = headings.filter { !foldFilter.contains($0.line.location) }
            guard let index = visible.lastIndex(where: { $0.line.location <= at }) else { return nil }
            func top(_ h: PlanHeading) -> CGFloat? {
                guard let start = content.location(content.documentRange.location, offsetBy: h.line.location),
                      let fragment = layout.textLayoutFragment(for: start) else { return nil }
                return fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0)
            }
            // The next heading may already be just under the reading line's slack.
            let candidates = [index, index + 1].filter(visible.indices.contains).compactMap { i in top(visible[i]).map { (visible[i], $0) } }
            guard let i = PlanOutline.current(tops: candidates.map(\.1), probe: readY + 12), candidates[i].1 < readY else { return nil }
            return candidates[i]
        }

        /// The page scrolled or the text moved: tell the pane what is being read. Async, as a
        /// frame change can arrive inside a SwiftUI update, where publishing is not allowed.
        func readingMoved() {
            guard let reading else { return }
            let title = readingHeading()?.heading.title
            guard title != MainActor.assumeIsolated({ reading.section }) else { return }
            DispatchQueue.main.async { [weak reading] in MainActor.assumeIsolated { reading?.set(title) } }
        }

        /// The crumb was clicked: the heading back just under the pinned block. Scrolling up to a
        /// point-high rect there puts it at the viewport's top, the block's height above it.
        func jumpToReadingHeading() {
            guard let textView, let (_, top) = readingHeading() else { return }
            let y = top + textView.textContainerOrigin.y
            textView.scrollToVisible(NSRect(x: 0, y: y - textView.obscuredTop - 12, width: 1, height: 1))
            readingMoved()
        }

        /// The visible foldable headings' lines, from what is laid out — nothing is laid out
        /// for this (it runs while drawing).
        private func foldMarks() -> [PlanFoldGutter.Mark] {
            guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager,
                  let viewport = layout.textViewportLayoutController.viewportRange else { return [] }
            let origin = textView.textContainerOrigin
            let ns = textView.string as NSString
            let first = content.offset(from: content.documentRange.location, to: viewport.location)
            let last = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            var marks: [PlanFoldGutter.Mark] = []
            for heading in headings where heading.body.length > 0 && heading.line.location >= first && heading.line.location <= last {
                guard let at = content.location(content.documentRange.location, offsetBy: heading.line.location),
                      let fragment = layout.textLayoutFragment(for: at), let line = fragment.textLineFragments.first,
                      let final = fragment.textLineFragments.last else { continue }
                let frame = fragment.layoutFragmentFrame
                let bounds = line.typographicBounds.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
                let end = frame.minX + origin.x + final.typographicBounds.minX + final.typographicBounds.width
                let folded = foldStore.folds.isFolded(heading.key)
                marks.append(.init(key: heading.key, line: bounds, textEnd: end, folded: folded,
                                   lines: folded ? PlanOutline.lineCount(heading.body, in: ns) : 0))
            }
            return marks
        }

        // MARK: Editing

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            editCount += 1
            pendingEdit = (editedRange, delta)
        }

        func textDidBeginEditing(_ notification: Notification) {
            session.editing = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            session.editing = true
            session.type(textView.string, at: Date())
            // Marked text (an input method mid-composition) is restyled once it is committed.
            if !textView.hasMarkedText() {
                let single = editCount == 1 ? pendingEdit : nil
                let fresh = single.map { MarkdownStyler.blocks(textView.string, after: blocks, edited: $0.range, delta: $0.delta) }
                    ?? MarkdownStyler.blocks(textView.string)
                let next = textView.isFocused ? MarkdownStyler.blockIndex(at: textView.selectedRange().location, in: fresh) : nil
                if let edit = single {
                    let changed = MarkdownStyler.changedBlocks(old: blocks, new: fresh, edited: edit.range, delta: edit.delta)
                    blocks = fresh
                    let layered = diffEditLayer(base: layerBase, text: textView.string,
                                                shift: (edit.range.location + max(edit.range.length - edit.delta, 0), edit.delta),
                                                edit: TextEdit(range: edit.range, delta: edit.delta))
                    style(storage, indices: changed + layered + [revealed, next].compactMap { $0 }, reveal: next)
                } else {
                    blocks = fresh
                    diffEditLayer(base: layerBase, text: textView.string)
                    style(storage, indices: nil, reveal: next)
                }
                revealed = next
                pendingEdit = nil
                editCount = 0
                foldsFollowEdit()
            }
            MainActor.assumeIsolated { notesBridge.textChanged() }
            scheduleIdleCommit()
        }

        func textDidEndEditing(_ notification: Notification) {
            timer?.invalidate()
            if let text = session.endEditing() { commit(text) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // The caret or a Find match landed in a folded section: it opens, rather than the
            // selection sitting in text nobody can see. Not mid-edit: the hidden ranges are the
            // text's before the keystroke until `textDidChange` moves them, and the caret after
            // text typed at a folded heading's end read as inside its old body.
            if editCount == 0, let textView { unfold(containing: textView.selectedRange()) }
            MainActor.assumeIsolated { notesBridge.selectionChanged() }
            // Mid-edit selection changes arrive before `textDidChange` re-parses; that pass
            // restyles the caret block itself.
            guard editCount == 0, let storage = textView?.textStorage else { return }
            let next = caretBlock()
            guard next != revealed else { return }
            style(storage, indices: [revealed, next].compactMap { $0 }, reveal: next)
            revealed = next
        }

        private func scheduleIdleCommit() {
            timer?.invalidate()
            let timer = Timer(timeInterval: EditPolicy.idle, repeats: false) { [weak self] _ in
                self?.idleFired(now: Date())
            }
            // `.common`, so a commit still lands while the human is scrolling.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// The idle window elapsed. An input method mid-composition (marked text) waits another
        /// window: committing now would send a half-composed character as the plan.
        func idleFired(now: Date) {
            if textView?.hasMarkedText() == true { return scheduleIdleCommit() }
            if let text = session.commitIfIdle(now: now) { commit(text) }
        }
    }
}

/// The text view, with the "A new round landed" banner above it. The banner lives here rather
/// than in SwiftUI because only the coordinator knows whether a head was held back — a SwiftUI
/// banner keyed on `incoming` alone would flash for one frame on every head the view takes at once.
///
/// **No scroll view of its own.** The plan is part of the detail pane's document: the text view
/// is as tall as its text, this view as tall as the banner and the text together
/// (`contentHeight`), and the pane's one scroll view scrolls all of it. A box scrolling inside a
/// scrolling page was two scrollers for one text — a wheel over the plan scrolled the box, and
/// the page only once the box hit its end. What an inner scroll view used to do for the text is
/// now done against the pane's:
/// - **Height.** The text view sizes itself to TextKit 2's `usageBoundsForTextContainer` (it is
///   vertically resizable). That is an estimate below the laid-out part, so after a load or a
///   re-wrap the whole plan is laid out once, in slices off the keystroke path
///   (`PlanNSTextView.layOutWholePlan`), and the height is exact; a keystroke never lays out the
///   whole plan. This view passes the height on to SwiftUI (`sizeThatFits`) — only a change of a
///   point or more, once a runloop turn (`heightChanged`), since each one relays out the pane.
/// - **Viewport.** TextKit 2 lays out only what the text view's `visibleRect` shows, which AppKit
///   clips through every enclosing clip view, so the pane's scroll bounds it and a scroll of the
///   pane re-lays it on the next display — measured (`PlanEditorOneScrollTests`), so nothing
///   here follows the pane's clip view for it. The notes' bands already do, for their own
///   redraw (`PlanNotesBridge.observeScrolls`).
/// - **Caret.** AppKit's reveal scrolls only the text view's own clip view, which it no longer
///   has, so `PlanNSTextView.scrollRangeToVisible` reveals through the page.
final class PlanEditorContainer: NSView {
    let textView = PlanNSTextView(usingTextLayoutManager: true)
    /// The edit layer's drawing (every paragraph an `EditLayerFragment`) and its hover Revert.
    let editLayout = EditLayerLayout()
    let revert = EditRevertButton()
    /// In the text view's gutter; it follows the text on its own (`ChurnLaneView.attach`) and
    /// hides itself when there is nothing to mark.
    let churnLane = ChurnLaneView()
    private let banner: NSHostingView<IncomingBanner>

    /// The shortest the text runs, so an empty or two-line plan is still a place to type into
    /// rather than a sliver — the height the boxed editor had as its minimum.
    static let minimumTextHeight: CGFloat = 240
    static let bannerGap: CGFloat = 6

    /// The height last handed to SwiftUI, and whether a hand-over is already queued this turn.
    private(set) var publishedHeight: CGFloat = 0
    private var heightQueued = false
    /// How many heights have been handed to SwiftUI — for tests of the coalescing.
    private(set) var heightPublishes = 0
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    var bannerVisible: Bool {
        get { !banner.isHidden }
        set {
            guard newValue == banner.isHidden else { return }
            banner.isHidden = !newValue
            needsLayout = true
            heightChanged()
        }
    }

    init(onShow: @escaping () -> Void) {
        banner = NSHostingView(rootView: IncomingBanner(onShow: onShow))
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Markdown is plain text: smart quotes and dashes would silently rewrite the plan.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // The gutter lanes sit left of the text (`PlanGutter`, and `textContainerOrigin`
        // below); the inset is half the two margins, since the text view splits it evenly.
        textView.textContainerInset = NSSize(width: (PlanGutter.width(churn: false) + 8) / 2, height: 8)
        textView.textLayoutManager?.delegate = editLayout
        revert.textView = textView
        // Grows to its text (see the type's comment); the width is this view's, set in `layout`.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: Self.minimumTextHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.frame.size.height = Self.minimumTextHeight
        // Sized by the text view itself (`PlanNSTextView.fitContainer`), to the pane less the gutter.
        textView.textContainer?.widthTracksTextView = false
        textView.setAccessibilityIdentifier("plan-editor")
        banner.isHidden = true

        // The churn lane lives in the gutter's CHURN column, inside the text view, so it
        // scrolls with the text; the column opens only while the lane has markers.
        churnLane.attach(to: textView)
        churnLane.onShown = { [weak textView] shown in textView?.showsChurn = shown }
        addSubview(banner)
        addSubview(textView)
        textView.postsFrameChangedNotifications = true
        observers = [
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView,
                                                   queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.heightChanged() }
            },
            NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView,
                                                   queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.editedAt = CACurrentMediaTime() }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// The banner (when shown) and the text, stacked: what this view needs to show all of it.
    var contentHeight: CGFloat {
        (banner.isHidden ? 0 : banner.fittingSize.height + Self.bannerGap) + max(textView.frame.height, Self.minimumTextHeight)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }

    override func layout() {
        super.layout()
        var top: CGFloat = 0
        if !banner.isHidden {
            let height = banner.fittingSize.height
            banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
            top = height + Self.bannerGap
        }
        if textView.frame.origin != NSPoint(x: 0, y: top) { textView.setFrameOrigin(NSPoint(x: 0, y: top)) }
        // Width only: the height is the text's own. A width change re-wraps it, and the text
        // view's resize to the new usage bounds comes back through `heightChanged`.
        if textView.frame.width != bounds.width { textView.setFrameSize(NSSize(width: bounds.width, height: textView.frame.height)) }
    }

    /// The text's height moved (it grew or shrank a line, re-wrapped, or its estimate firmed up
    /// as layout reached further down): hand SwiftUI the new height, at most once a runloop turn
    /// and only for a change of a point or more. Every hand-over relays out the pane, and a burst
    /// of estimate refinements while scrolling or a paste would otherwise each pay for one.
    func heightChanged() {
        guard !heightQueued, abs(contentHeight - publishedHeight) >= 1 else { return }
        heightQueued = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.publishHeight() }
        }
    }

    private func publishHeight() {
        heightQueued = false
        let height = contentHeight
        guard abs(height - publishedHeight) >= 1 else { return }
        // Grown by typing: the keystroke's own reveal ran while the page was still the old
        // height, so a new last line sat below the page's end, out of reach — until the page
        // has grown (`setFrameSize`), when the caret is revealed again. Only just after an edit:
        // an estimate firming up while the human scrolls must not yank the page to the caret.
        revealPending = height > publishedHeight && CACurrentMediaTime() - editedAt < Self.revealWindow
        publishedHeight = height
        heightPublishes += 1
        invalidateIntrinsicContentSize()
    }

    /// When the text last changed, and how long after it a growth still counts as the edit's.
    private var editedAt: CFTimeInterval = -.infinity
    private static let revealWindow: CFTimeInterval = 0.5
    private var revealPending = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard revealPending, newSize.height >= publishedHeight - 0.5 else { return }
        revealPending = false
        // Next turn: the page's own frame may be set after this view's in the same pass.
        DispatchQueue.main.async { [weak textView] in
            guard let textView, textView.window?.firstResponder === textView else { return }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}

/// Reports focus changes, which `NSTextViewDelegate` doesn't: `textDidBeginEditing` waits for
/// the first keystroke, so the caret block's syntax would stay hidden on a click and linger
/// after focus left. `isFocused` is settable so a test can stub focus on a detached view.
class PlanNSTextView: NSTextView {
    var isFocused = false
    var onFocusChange: (() -> Void)?
    /// How much of the page's top edge something is drawn over — the pinned control bar and
    /// board. A caret there is "visible" to AppKit and hidden from the human, so a reveal keeps
    /// this much room above it (`scrollRangeToVisible`).
    var obscuredTop: CGFloat = 0
    /// The pointer over the text (view coordinates), nil when it leaves — the edit layer's
    /// hover Revert.
    var onHover: ((NSPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?
    /// A click at a point (view coordinates): true when it hit a fold chevron or pill and was
    /// handled, so the text doesn't also take it as a caret placement.
    var onFoldClick: ((NSPoint) -> Bool)?
    /// ⌥⌘← (true, fold) / ⌥⌘→ (false, open) on the caret's section; true when handled.
    var onFoldKey: ((Bool) -> Bool)?
    /// A range as far as the page shows it — inside a folded section, its heading
    /// (`Coordinator.visibleProxy`). The notes rail places a card by this.
    var visibleProxy: ((NSRange) -> NSRange)?
    /// The plan's headings — the VoiceOver rotor.
    var outline: (() -> [PlanHeading])?
    /// The page scrolled (any enclosing clip view): what is drawn against the viewport follows.
    var onScroll: (() -> Void)?
    private var scrollObservers: [NSObjectProtocol] = []
    private var observedClips: [ObjectIdentifier] = []

    /// The text starts after the gutter lanes: the margin is all on the leading side, where
    /// an even `textContainerInset` would split it.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: PlanGutter.width(churn: showsChurn), y: super.textContainerOrigin.y)
    }

    /// Whether the gutter's CHURN column is open (`ChurnLaneView` has markers): the text moves
    /// over for it, and the container narrows to match so lines rewrap rather than clip.
    var showsChurn = false {
        didSet {
            guard showsChurn != oldValue else { return }
            textContainerInset = NSSize(width: (PlanGutter.width(churn: showsChurn) + 8) / 2, height: textContainerInset.height)
            fitContainer()
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitContainer()
        // The chevrons and the outline cue span the text view.
        onScroll?()
    }

    /// The container at the pane's width less the gutter lanes and the trailing margin
    /// (`PlanGutter.textWidth`): the plan wraps to the pane and reflows as it is resized.
    ///
    /// A resize tick costs only the lines on screen: the new width takes at once, TextKit 2
    /// re-lays the viewport on the next display, and the whole-plan pass (`layOutWholePlan`)
    /// only restarts — a tick bumps its generation, so any number of ticks in a turn leave one
    /// pass, and its slices run in `.default` mode, which a live resize (event tracking) holds
    /// off until the drag ends. Measured in `PlanEditorKeystrokeTests.testResizeReflowIsUnderAFrame`.
    private func fitContainer() {
        guard let container = textContainer else { return }
        let width = PlanGutter.textWidth(viewWidth: frame.width, churn: showsChurn)
        guard container.size.width != width else { return }
        container.size = NSSize(width: width, height: container.size.height)
        // Every line re-wraps: the height is an estimate again until it is all laid out.
        layOutWholePlan()
    }

    // MARK: Whole-plan layout

    /// The plan is part of the page, so its height is the page's end. TextKit 2 knows it
    /// exactly only for what it has laid out — the rest is an estimate, which ran short for
    /// wrapped paragraphs: the page's end moved down as the human read, six scrolls to the
    /// bottom before it stayed put. So after a load or a re-wrap the whole plan is laid out
    /// once, off the keystroke path: from the next runloop turn, in slices of
    /// `fullLayoutSlice`, a newer load or width starting it over. Typing keeps TextKit 2's
    /// incremental layout: an edit changes the height only by what its paragraph changed.
    private var fullLayoutGeneration = 0
    /// Where the pass has reached, nil when none is running.
    private var fullLayoutNext: NSTextLocation?
    /// Main-thread time the last completed pass took, all slices together, and in how many.
    private(set) var lastFullLayout: (time: Duration, slices: Int)?
    private var fullLayoutSpent: (time: Duration, slices: Int) = (.zero, 0)
    /// Under a frame at 60 Hz, so a slice never costs the human a frame of scrolling.
    static var fullLayoutSlice: Duration = .milliseconds(8)

    /// Passes run to the end — for tests of the coalescing.
    private(set) var fullLayoutPasses = 0
    /// Whether a pass is still running — for tests.
    var layingOutWholePlan: Bool { fullLayoutNext != nil }

    func layOutWholePlan() {
        guard let content = textLayoutManager?.textContentManager else { return }
        fullLayoutGeneration += 1
        fullLayoutNext = content.documentRange.location
        fullLayoutSpent = (.zero, 0)
        scheduleLayoutSlice(fullLayoutGeneration)
    }

    private func scheduleLayoutSlice(_ generation: Int) {
        // `.default` only: a slice waits out a live scroll (`.eventTracking`) rather than
        // stealing its frames.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.layOutSlice(generation) }
        }
    }

    private func layOutSlice(_ generation: Int) {
        guard generation == fullLayoutGeneration, let start = fullLayoutNext, let layout = textLayoutManager else { return }
        let clock = ContinuousClock()
        let began = clock.now
        var next: NSTextLocation?
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard clock.now - began < Self.fullLayoutSlice else {
                next = fragment.rangeInElement.endLocation
                return false
            }
            return true
        }
        fullLayoutSpent = (fullLayoutSpent.time + (clock.now - began), fullLayoutSpent.slices + 1)
        fullLayoutNext = next
        guard next == nil else { return scheduleLayoutSlice(generation) }
        lastFullLayout = fullLayoutSpent
        fullLayoutPasses += 1
        // The frame takes the now-exact usage bounds at once; the container passes it on.
        // Not `sizeToFit()`: measured, it left the frame at the estimate until a later layout.
        let height = max(minSize.height, layout.usageBoundsForTextContainer.height + 2 * textContainerInset.height)
        if abs(height - frame.height) >= 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    /// An edit made while a pass was running may have replaced the text it was walking:
    /// start over (what is laid out stays laid out, so the restart is quick).
    override func didChangeText() {
        super.didChangeText()
        if fullLayoutNext != nil { layOutWholePlan() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolls()
    }

    /// Every clip view the page scrolls this view in — observed on exactly those, re-subscribed
    /// when the chain changes (as `PlanNotesBridge.observeScrolls`).
    private func observeScrolls() {
        let clips = PlanNotesBridge.enclosingClips(of: self)
        let ids = clips.map(ObjectIdentifier.init)
        guard ids != observedClips else { return }
        scrollObservers.forEach(NotificationCenter.default.removeObserver)
        observedClips = ids
        scrollObservers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScroll?() }
            }
        }
    }

    deinit { scrollObservers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: VoiceOver

    /// The plan's outline for VoiceOver: a Headings rotor that steps through the sections and
    /// lands the caret on each — the outline cue's content, reachable without the pointer. A
    /// folded section's heading is still listed; landing inside it is a selection change,
    /// which opens it.
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: headingRotor)]
    }

    private lazy var headingRotor = HeadingRotor(view: self)

    final class HeadingRotor: NSObject, NSAccessibilityCustomRotorItemSearchDelegate {
        weak var view: PlanNSTextView?
        init(view: PlanNSTextView) { self.view = view }

        func rotor(_ rotor: NSAccessibilityCustomRotor,
                   resultFor search: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
            guard let view, let headings = view.outline?(), !headings.isEmpty else { return nil }
            let from = search.currentItem?.targetRange.location ?? (search.searchDirection == .next ? -1 : Int.max)
            let pick = search.searchDirection == .next
                ? headings.first { $0.line.location > from }
                : headings.last { $0.line.location < from }
            guard let heading = pick else { return nil }
            let item = NSAccessibilityCustomRotor.ItemResult(targetElement: view)
            item.targetRange = heading.line
            item.customLabel = heading.title
            return item
        }
    }

    override func mouseDown(with event: NSEvent) {
        if onFoldClick?(convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }

    /// ⌥⌘← folds the caret's section and ⌥⌘→ opens it — only while this view has focus. No
    /// menu item uses the chord, and Ghostty's own ⌥⌘← (goto_split) only acts in a focused
    /// terminal surface (`SurfaceView.performKeyEquivalent` returns early unfocused).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if window?.firstResponder === self, mods == [.command, .option], let key = event.specialKey,
           key == .leftArrow || key == .rightArrow, onFoldKey?(key == .leftArrow) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover?(nil) }
    }

    /// The delegate's `undoManager(for:)` first. Measured: a plain `NSTextView` never
    /// consulted it (its `undoManager` came back nil in a window), so without this ⌘Z and
    /// typing fell through to whatever stack the responder chain found — one that outlives a
    /// load.
    override var undoManager: UndoManager? {
        delegate?.undoManager?(for: self) ?? super.undoManager
    }

    /// Typing, moving the caret and Find all reveal through here. AppKit's own reveal scrolls
    /// only a clip view the text view is the document of — measured: typing at the end of a
    /// plan in the page never moved the page — so the range's first line is revealed here, with
    /// `scrollToVisible`, which walks up to the page's clip view. With `obscuredTop` of room
    /// above it, so typing near the top of the page doesn't go on under the pinned block.
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let line = caretRect(at: range.location) else { return }
        scrollToVisible(NSRect(x: line.minX, y: line.minY - obscuredTop, width: max(line.width, 1), height: line.height + obscuredTop))
    }

    /// The insertion point at `location`, in this view's coordinates — laid out on demand, for
    /// that one line. `firstRect(forCharacterRange:)` answers an empty rect for an empty range
    /// on TextKit 2.
    func caretRect(at location: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let at = content.location(content.documentRange.location, offsetBy: location) else { return nil }
        let range = NSTextRange(location: at)
        layout.ensureLayout(for: range)
        var caret: CGRect?
        layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            caret = frame
            return false
        }
        guard let caret else { return nil }
        let origin = textContainerOrigin
        return caret.offsetBy(dx: origin.x, dy: origin.y)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isFocused = true
        onFocusChange?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isFocused = false
        onFocusChange?()
        return true
    }
}

extension EnvironmentValues {
    /// How much of the top of the page (the detail pane's document) is drawn over while it
    /// scrolls — the pinned control bar and board. The editor reveals its caret below it, and
    /// Diff vs Previous lands a section's hunk under it rather than behind it.
    @Entry var pageObscuredTop: CGFloat = 0
    /// Scrolls the page to a view by its `.id`; nil outside the detail pane.
    @Entry var pageJump: PageJump?
    /// Where the pane shows the plan section being read (`PlanReadingPosition`); nil outside it.
    @Entry var planReading: PlanReadingPosition?
}

/// Scrolls the detail pane's document — the one scroller the plan is part of — to put a view
/// (by its `.id`) a given distance below the page's top edge: under the pinned block, not
/// behind it. A view inside the document can't use its own `ScrollViewReader`: a proxy only
/// scrolls the scroll views INSIDE its reader, and the page's is outside.
struct PageJump {
    let scroll: (_ id: AnyHashable, _ below: CGFloat) -> Void

    /// The `scrollTo` anchor that lands a point-high target `below` points under the top of a
    /// viewport `height` tall: the anchor is a point in BOTH the target and the viewport, so a
    /// fraction `below / height` puts the target's top there. (An id'd marker nudged up with an
    /// alignment guide was measured to land at the top regardless.)
    static func anchor(below: CGFloat, height: CGFloat) -> UnitPoint {
        height > 0 ? UnitPoint(x: 0, y: min(max(below / height, 0), 1)) : .top
    }
}

/// Review Focus 3's banner: a round landed while the human was typing, so it waits.
struct IncomingBanner: View {
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("A new round landed").font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Button("Show it", action: onShow)
                .accessibilityIdentifier("plan-show-incoming")
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-incoming-banner")
    }
}

/// The plan section's way to act through its editor, rather than around it: an action that
/// changes the text must go through the editor's own change path to be undoable — setting the
/// parent's `text` is a load, and a load empties the undo stack. Held by the parent, filled in
/// by the editor on each update.
@MainActor
final class PlanEditorHandle {
    weak var coordinator: PlanTextView.Coordinator?

    nonisolated init() {}

    /// Every edit back to the agents' plan, as one undoable change ("Revert All Edits").
    func revertAll() { coordinator?.revertAll() }
}
