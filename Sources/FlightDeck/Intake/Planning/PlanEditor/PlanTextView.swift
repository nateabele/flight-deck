import AppKit
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
/// into `text`.
struct PlanTextView: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let onCommit: (String) -> Void
    let incoming: String?
    let onShowIncoming: () -> Void
    var theme: PlanTheme = .standard

    init(text: Binding<String>, editable: Bool, onCommit: @escaping (String) -> Void, incoming: String?,
         onShowIncoming: @escaping () -> Void) {
        _text = text
        self.editable = editable
        self.onCommit = onCommit
        self.incoming = incoming
        self.onShowIncoming = onShowIncoming
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PlanEditorContainer {
        let container = PlanEditorContainer(onShow: { [weak coordinator = context.coordinator] in coordinator?.showHeld() })
        let coordinator = context.coordinator
        coordinator.textView = container.textView
        container.textView.delegate = coordinator
        container.textView.textStorage?.delegate = coordinator
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
        coordinator.receive(incoming)
        container.bannerVisible = coordinator.session.held != nil
    }

    static func dismantleNSView(_ container: PlanEditorContainer, coordinator: Coordinator) {
        // Switching to the diff, or away from the intake, must not drop the last two seconds
        // of typing.
        coordinator.timer?.invalidate()
        if let text = coordinator.session.endEditing() { coordinator.commit(text) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: PlanTextView
        var session = PlanEditSession(text: "")
        /// The last `text` binding value seen or written, so `updateNSView` can tell a load
        /// from the parent apart from its own commit echoing back.
        var lastBound = ""
        weak var textView: NSTextView?
        var timer: Timer?
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

        init(_ parent: PlanTextView) { self.parent = parent }

        func load(_ text: String) {
            lastBound = text
            session.load(text)
            guard let textView, let storage = textView.textStorage else { return }
            if textView.string != text { textView.string = text }
            blocks = MarkdownStyler.blocks(text)
            revealed = caretBlock()
            MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: revealed, theme: parent.theme)
            pendingEdit = nil
            editCount = 0
            taking = nil
        }

        func receive(_ incoming: String?) {
            guard let incoming else { return session.dropHeld() }
            guard incoming != taking, incoming != session.held else { return }
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

        private var isFirstResponder: Bool {
            guard let textView else { return false }
            return textView.window?.firstResponder === textView
        }

        private func caretBlock() -> Int? {
            guard let textView else { return nil }
            return MarkdownStyler.blockIndex(at: textView.selectedRange().location, in: blocks)
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
                let next = MarkdownStyler.blockIndex(at: textView.selectedRange().location, in: fresh)
                if editCount == 1, let edit = pendingEdit {
                    let changed = MarkdownStyler.changedBlocks(old: blocks, new: fresh, edited: edit.range, delta: edit.delta)
                    blocks = fresh
                    MarkdownStyler.restyle(storage, blocks: blocks, indices: changed + [revealed, next].compactMap { $0 },
                                           revealBlock: next, theme: parent.theme)
                } else {
                    blocks = fresh
                    MarkdownStyler.apply(to: storage, blocks: blocks, revealBlock: next, theme: parent.theme)
                }
                revealed = next
                pendingEdit = nil
                editCount = 0
            }
            scheduleIdleCommit()
        }

        func textDidEndEditing(_ notification: Notification) {
            timer?.invalidate()
            if let text = session.endEditing() { commit(text) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Mid-edit selection changes arrive before `textDidChange` re-parses; that pass
            // restyles the caret block itself.
            guard editCount == 0, let storage = textView?.textStorage else { return }
            let next = caretBlock()
            guard next != revealed else { return }
            MarkdownStyler.restyle(storage, blocks: blocks, indices: [revealed, next].compactMap { $0 },
                                   revealBlock: next, theme: parent.theme)
            revealed = next
        }

        private func scheduleIdleCommit() {
            timer?.invalidate()
            let timer = Timer(timeInterval: EditPolicy.idle, repeats: false) { [weak self] _ in
                guard let self, let text = self.session.commitIfIdle(now: Date()) else { return }
                self.commit(text)
            }
            // `.common`, so a commit still lands while the human is scrolling.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

/// The scroll view and text view, with the "A new round landed" banner above them. The
/// banner lives here rather than in SwiftUI because only the coordinator knows whether a
/// head was held back — a SwiftUI banner keyed on `incoming` alone would flash for one frame
/// on every head the view takes at once.
final class PlanEditorContainer: NSView {
    let textView = NSTextView(usingTextLayoutManager: true)
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
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("plan-editor")

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        banner.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
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
