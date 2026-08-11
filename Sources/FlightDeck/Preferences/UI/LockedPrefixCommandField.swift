import AppKit
import SwiftUI

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
struct LockedPrefixCommandField: NSViewRepresentable {
    let lockedPrefix: String
    @Binding var tail: String
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.allowsUndo = true

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        context.coordinator.textView = textView
        context.coordinator.render(prefix: lockedPrefix, tail: tail)
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

        init(_ parent: LockedPrefixCommandField) {
            self.parent = parent
        }

        /// The locked region is `prefix` plus the single space separating it from the tail,
        /// so the user cannot delete that separator and glue their first flag onto `--name`.
        private var lockedLength: Int { (currentPrefix as NSString).length + 1 }

        func render(prefix: String, tail: String) {
            guard let textView else { return }
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
            textView.textStorage?.setAttributedString(attributed)
            clampSelection()
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
            guard let textView else { return }
            let full = textView.string as NSString
            guard full.length >= lockedLength else { return }
            currentTail = full.substring(from: lockedLength)
            parent.tail = currentTail
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onCommit(currentTail)
        }

        /// ⌘↩ commits without leaving the field.
        func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)),
               NSEvent.modifierFlags.contains(.command) {
                parent.onCommit(currentTail)
                return true
            }
            return false
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
