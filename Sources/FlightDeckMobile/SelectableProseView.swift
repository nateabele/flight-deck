import SwiftUI
import UIKit

/// A run of prose the reader can highlight, with **Reply** in the edit menu beside Copy.
///
/// **Why a `UITextView` and not `Text`.** `.textSelection(.enabled)` makes prose selectable and
/// gives the caller nothing back: no selected substring, no place to hang an action.
/// `.contextMenu(forSelectionType:)` is `List`/`Table` row selection, not text ranges. The
/// delegate callback below is the only hook on this platform that is handed the range an edit
/// menu was raised on, so the view that owns prose has to be one that has a delegate.
///
/// It draws `TimelineProseText.attributed`, which is `TimelineMarkdown.theme` expressed in
/// attributes — see that file for why one design ends up with two renderers.
struct SelectableProseView: UIViewRepresentable {
    let markdown: String
    /// What Reply does with the highlighted text. The view knows nothing about composers.
    let onReply: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let view = TextView()
        view.delegate = context.coordinator
        // Not editable, but selectable: the combination that gives a caretless selection with
        // the system's own menu, and lets a tap open a link rather than place a cursor.
        view.isEditable = false
        view.isSelectable = true
        // **Scrolling off is what makes it size itself**, and what keeps it out of a fight with
        // the `List` it lives in: a scrollable text view inside a scroll view captures the pan
        // and the conversation stops moving under the finger.
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        // The row owns its own padding. Left in, these two inset the text from everything
        // beside it and prose stops lining up with the code blocks above and below.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onReply = onReply
        context.coordinator.apply(markdown, to: view)
    }

    /// SwiftUI's sizing question, answered by the text view's own layout at the offered width.
    /// Without this the row gets an intrinsic height measured against the wrong width, which is
    /// the classic self-sizing-text-view-in-a-cell defect: a paragraph that wraps to six lines
    /// drawn in the space for one.
    ///
    /// **The text is applied here, before the measurement, and that is not belt-and-braces.**
    /// SwiftUI may size a representable before `updateUIView` has run against the current
    /// value, and a text view still holding the previous string answers for the previous
    /// string. The first render of this view measured one line short and clipped its last line
    /// — visible only in a render, which is exactly how a sizing bug ships.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width < .greatestFiniteMagnitude else { return nil }
        context.coordinator.apply(markdown, to: uiView)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onReply: onReply) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onReply: (String) -> Void

        /// The last markdown parsed, and what it parsed to. `sizeThatFits` and `updateUIView`
        /// both need the attributed string and SwiftUI calls them in either order and more than
        /// once per change, so without this a scrolling list re-parses the same message
        /// several times a frame.
        private var cachedMarkdown: String?
        private var cachedAttributed: NSAttributedString?
        /// Invalidates the cache when the text size changes, since the base font is baked in.
        private var cachedCategory: UIContentSizeCategory?

        init(onReply: @escaping (String) -> Void) {
            self.onReply = onReply
        }

        /// Put `markdown` into `view`, parsing only when it is genuinely new.
        func apply(_ markdown: String, to view: UITextView) {
            let category = view.traitCollection.preferredContentSizeCategory
            if cachedMarkdown != markdown || cachedCategory != category || cachedAttributed == nil {
                cachedAttributed = TimelineProseText.attributed(markdown)
                cachedMarkdown = markdown
                cachedCategory = category
            }
            guard let attributed = cachedAttributed else { return }
            if view.attributedText != attributed { view.attributedText = attributed }
        }

        /// **Reply is appended, not spliced in beside Copy.** The suggested actions arrive as an
        /// opaque list whose contents are the system's to change between releases, and reaching
        /// into it to find Copy is a lookup that silently does nothing the first time Apple
        /// renames it. Appended, Reply is the last item in the bar — which on a selection with
        /// the standard actions is the position immediately after Copy anyway.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let selected = (textView.text as NSString).substring(with: range)
            let reply = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) {
                [weak self] _ in
                self?.onReply(selected)
            }
            return UIMenu(children: suggestedActions + [reply])
        }
    }

    /// A text view that refuses to be scrolled by anything, including the system: an
    /// `attributedText` assignment or a menu dismissal can nudge `contentOffset`, and in a
    /// zero-inset non-scrolling view that shows up as prose sitting a few points too high.
    private final class TextView: UITextView {
        override var contentOffset: CGPoint {
            get { super.contentOffset }
            set { super.contentOffset = .zero }
        }
    }
}
