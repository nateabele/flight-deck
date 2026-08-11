import AppKit
import SwiftUI

/// `NSTextView` subclass that intercepts ⌘↩ before AppKit's standard key-binding machinery
/// gets a chance to swallow it.
///
/// ⌘↩ commits without leaving the field. It has to be caught here rather than in
/// `NSTextViewDelegate.doCommandBy`: Command-modified keys are offered to
/// `performKeyEquivalent(with:)` up the responder chain before `keyDown:` runs, so the
/// standard key-binding dictionary (which maps unmodified Return to `insertNewline:`) never
/// produces a selector for the Command-modified case, and `doCommandBy` never sees it.
final class CommandFieldTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The command field: an `NSTextView` whose leading `lockedPrefix` cannot be edited,
/// selected into, or deleted.
///
/// The app-managed flags are always a contiguous prefix of the command
/// (`ClaudeSession.lockedPrefix`), which is what reduces "locked tokens" to "locked
/// prefix" — no attachment cells, no inline token model, just a rejected edit range.
///
/// Sync is asymmetric by design: `tail` is pushed in immediately whenever a control
/// changes, but `onCommit` only fires on blur or ⌘↩, so the field is never re-canonicalized
/// under a live cursor.
///
/// Plain Return is left alone — it inserts a literal newline into the tail, which is fine
/// since the tokenizer treats `\n` as ordinary whitespace, so a wrapped command still parses.
struct LockedPrefixCommandField: NSViewRepresentable {
    let lockedPrefix: String
    @Binding var tail: String
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = CommandFieldTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.allowsUndo = true

        let coordinator = context.coordinator
        textView.onCommandReturn = { [weak coordinator] in
            coordinator?.commit()
        }

        scrollView.documentView = textView

        coordinator.textView = textView
        coordinator.render(prefix: lockedPrefix, tail: tail)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Only re-render when the model actually differs from what is on screen, or every
        // keystroke would reset the caret to the end.
        if context.coordinator.currentTail != tail || context.coordinator.currentPrefix != lockedPrefix {
            context.coordinator.render(prefix: lockedPrefix, tail: tail)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LockedPrefixCommandField
        weak var textView: NSTextView?
        private(set) var currentPrefix = ""
        private(set) var currentTail = ""

        /// Set for the duration of `render`'s programmatic `textStorage` replacement.
        /// `textDidChange` checks this so that a future AppKit change which starts routing
        /// programmatic storage edits through the normal change notification (today it does
        /// not) can't push a re-render's own output back into the `tail` binding mid view
        /// update.
        private var isRendering = false

        init(_ parent: LockedPrefixCommandField) {
            self.parent = parent
        }

        /// The locked region is `prefix` plus the single space separating it from the tail,
        /// so the user cannot delete that separator and glue their first flag onto `--name`.
        private var lockedLength: Int { (currentPrefix as NSString).length + 1 }

        func render(prefix: String, tail: String) {
            guard let textView else { return }
            // Yanking the storage out from under an in-progress IME composition (e.g.
            // Japanese/Chinese input) would abort it. Skip this pass; `currentTail` is left
            // stale on purpose so the next `updateNSView` retries once composition ends.
            guard !textView.hasMarkedText() else { return }

            currentPrefix = prefix
            currentTail = tail

            let full = prefix + " " + tail
            let attributed = NSMutableAttributedString(string: full)
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            attributed.addAttributes(
                [.font: font, .foregroundColor: NSColor.labelColor],
                range: NSRange(location: 0, length: (full as NSString).length)
            )
            attributed.addAttributes(
                [.foregroundColor: NSColor.secondaryLabelColor],
                range: NSRange(location: 0, length: min(lockedLength, (full as NSString).length))
            )

            // The storage is replaced wholesale, so every previously registered undo action
            // refers to ranges in a string that no longer exists. Applying one would either
            // throw or rewrite inside the locked prefix.
            textView.undoManager?.removeAllActions()

            isRendering = true
            textView.textStorage?.setAttributedString(attributed)
            isRendering = false

            // The locked range ends with the separator space, and NSTextView inherits
            // typingAttributes from the character before the insertion point — so without
            // this, the first character the user types is painted as if it were locked.
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]

            clampSelection()
        }

        /// Shared by blur (`textDidEndEditing`) and ⌘↩ (`CommandFieldTextView.onCommandReturn`).
        func commit() {
            parent.onCommit(currentTail)
        }

        // MARK: NSTextViewDelegate

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            affectedCharRange.location >= lockedLength
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            clampSelection()
        }

        func textDidChange(_ notification: Notification) {
            guard !isRendering else { return }
            guard let textView else { return }
            let full = textView.string as NSString
            guard full.length >= lockedLength else { return }
            currentTail = full.substring(from: lockedLength)
            parent.tail = currentTail
        }

        func textDidEndEditing(_ notification: Notification) {
            commit()
        }

        private func clampSelection() {
            guard let textView else { return }
            let length = (textView.string as NSString).length
            let floor = min(lockedLength, length)
            let selected = textView.selectedRange()
            if selected.location < floor {
                let overshoot = max(0, selected.location + selected.length - floor)
                textView.setSelectedRange(NSRange(location: floor, length: overshoot))
            }
        }
    }
}
