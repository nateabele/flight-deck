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
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
        container.textView.onHover = { [weak container] in container?.revert.hover(at: $0) }
        container.revert.onRevert = { [weak coordinator] in coordinator?.revert(hunk: $0) }
        coordinator.revertButton = container.revert
        coordinator.load(text)
        return container
    }

    func updateNSView(_ container: PlanEditorContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.textView.isEditable = editable
        // While a commit's binding write is still queued, `text` is the pre-commit value; loading
        // it would put back the text the human just replaced.
        if coordinator.inFlight == 0, text != coordinator.lastBound { coordinator.load(text) }
        coordinator.receive(incoming, navigation: incomingIsNavigation)
        container.bannerVisible = coordinator.session.held != nil
        coordinator.layEditLayer(over: generated)
        container.revert.enabled = editable
        coordinator.notesBridge.attach(notes, to: container.textView)
        container.churnLane.update(churn)
        coordinator.churnChanged()
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
        weak var textView: PlanNSTextView?
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

        init(_ parent: PlanTextView) { self.parent = parent }

        func load(_ text: String) {
            lastBound = text
            session.load(text)
            guard let textView, let storage = textView.textStorage else { return }
            if textView.string != text { textView.string = text }
            undo.removeAllActions()
            blocks = MarkdownStyler.blocks(text)
            revealed = caretBlock()
            diffEditLayer(base: parent.generated, text: text)
            style(storage, indices: nil, reveal: revealed)
            pendingEdit = nil
            editCount = 0
            taking = nil
            MainActor.assumeIsolated { notesBridge.textChanged() }
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
        private func diffEditLayer(base: String?, text: String, shift: (at: Int, by: Int)? = nil) -> [Int] {
            layerBase = base
            let old = marks
            (marks, hunks) = base.map { EditLayer.marks(generated: $0, edited: text) } ?? ([], [])
            revertButton?.spans = EditLayer.spans(hunks, edited: text)
            layTints(text)
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

        /// Lays the churn highlight and then the edit tint over `text` — see `churnTint`.
        func layTints(_ text: String) {
            guard let layout = textView?.textLayoutManager else { return }
            let edits = EditLayer.tints(marks, in: text)
            churnTint.apply(churnRanges(text, avoiding: edits.map(\.0)).map { ($0, [.backgroundColor: Self.churnColor]) }, to: layout)
            editTint.apply(edits, to: layout)
        }

        /// The churn lane's input changed (a round landed): re-find the flipping sentences.
        func churnChanged() {
            guard let textView, churnVersions?.cycle != parent.churn?.cycle else { return }
            layTints(textView.string)
        }

        static let churnColor = NSColor(LCDMetrics.color(.amber)).withAlphaComponent(0.16)

        private func churnRanges(_ text: String, avoiding insertions: [NSRange]) -> [NSRange] {
            guard let churn = parent.churn else { churnVersions = nil; return [] }
            if churnVersions?.cycle != churn.cycle {
                let hot = HeatmapModel.hotSections(churn.cycle)
                churnVersions = (churn.cycle, Dictionary(uniqueKeysWithValues: hot.map { ($0, churn.versions($0)) }))
            }
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
            guard let textView, let storage = textView.textStorage, let base = layerBase, hunks.indices.contains(index),
                  let reverted = PlanLayers.revert(hunks[index], generated: base, edited: textView.string) else { return }
            let old = textView.string as NSString, new = reverted as NSString
            var front = 0
            while front < old.length, front < new.length, old.character(at: front) == new.character(at: front) { front += 1 }
            var back = 0
            while back < old.length - front, back < new.length - front,
                  old.character(at: old.length - 1 - back) == new.character(at: new.length - 1 - back) { back += 1 }
            let range = NSRange(location: front, length: old.length - front - back)
            let replacement = new.substring(with: NSRange(location: front, length: new.length - front - back))
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            timer?.invalidate()
            if let text = session.flush() { commit(text) }
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
                let fresh = MarkdownStyler.blocks(textView.string)
                let next = textView.isFocused ? MarkdownStyler.blockIndex(at: textView.selectedRange().location, in: fresh) : nil
                if editCount == 1, let edit = pendingEdit {
                    let changed = MarkdownStyler.changedBlocks(old: blocks, new: fresh, edited: edit.range, delta: edit.delta)
                    blocks = fresh
                    let layered = diffEditLayer(base: layerBase, text: textView.string,
                                                shift: (edit.range.location + max(edit.range.length - edit.delta, 0), edit.delta))
                    style(storage, indices: changed + layered + [revealed, next].compactMap { $0 }, reveal: next)
                } else {
                    blocks = fresh
                    diffEditLayer(base: layerBase, text: textView.string)
                    style(storage, indices: nil, reveal: next)
                }
                revealed = next
                pendingEdit = nil
                editCount = 0
            }
            MainActor.assumeIsolated { notesBridge.textChanged() }
            scheduleIdleCommit()
        }

        func textDidEndEditing(_ notification: Notification) {
            timer?.invalidate()
            if let text = session.endEditing() { commit(text) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
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

/// The scroll view and text view, with the "A new round landed" banner above them. The
/// banner lives here rather than in SwiftUI because only the coordinator knows whether a
/// head was held back — a SwiftUI banner keyed on `incoming` alone would flash for one frame
/// on every head the view takes at once.
final class PlanEditorContainer: NSView {
    let textView = PlanNSTextView(usingTextLayoutManager: true)
    /// The edit layer's drawing (every paragraph an `EditLayerFragment`) and its hover Revert.
    let editLayout = EditLayerLayout()
    let revert = EditRevertButton()
    /// Beside the scroll view, flush with its top; it follows the text on its own
    /// (`ChurnLaneView.attach`) and hides itself when there is nothing to mark.
    let churnLane = ChurnLaneView()
    private let scroll = NSScrollView()
    private let banner: NSHostingView<IncomingBanner>
    private let stack = NSStackView()

    var bannerVisible: Bool {
        get { !banner.isHidden }
        set { banner.isHidden = !newValue }
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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // Sized by the text view itself (`PlanNSTextView.fitContainer`), to the readable measure.
        textView.textContainer?.widthTracksTextView = false
        textView.setAccessibilityIdentifier("plan-editor")

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        banner.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // The churn lane lives in the gutter's CHURN column, inside the text view, so it
        // scrolls with the text; the column opens only while the lane has markers.
        churnLane.attach(to: textView)
        churnLane.onShown = { [weak textView] shown in textView?.showsChurn = shown }
        stack.addArrangedSubview(banner)
        stack.addArrangedSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Reports focus changes, which `NSTextViewDelegate` doesn't: `textDidBeginEditing` waits for
/// the first keystroke, so the caret block's syntax would stay hidden on a click and linger
/// after focus left. `isFocused` is settable so a test can stub focus on a detached view.
class PlanNSTextView: NSTextView {
    var isFocused = false
    var onFocusChange: (() -> Void)?
    /// The pointer over the text (view coordinates), nil when it leaves — the edit layer's
    /// hover Revert.
    var onHover: ((NSPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

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
    }

    /// The container at the readable measure (`PlanGutter.textWidth`) rather than tracking the
    /// view's width: the view still spans the pane, so the scroller stays at its edge and the
    /// room past the text is part of the editor.
    private func fitContainer() {
        guard let container = textContainer else { return }
        let width = PlanGutter.textWidth(viewWidth: frame.width, churn: showsChurn)
        guard container.size.width != width else { return }
        container.size = NSSize(width: width, height: container.size.height)
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
