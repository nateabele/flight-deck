import SwiftUI
import UIKit

/// One item the edit menu offers on a selection, beside Copy: Reply in a conversation, Note… in
/// a plan. `perform` is handed the selected text as rendered.
struct ProseAction {
    let title: String
    let systemImage: String
    let perform: (String) -> Void
}

/// A run of prose the reader can highlight, with the caller's actions (Reply, Note…) in the edit
/// menu beside Copy.
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
    /// What the edit menu adds for a selection. The view knows nothing about composers or
    /// notes. Empty when nothing is behind the text to act on (a plan the maintainer cannot annotate):
    /// the menu is then the system's own, with no item that does nothing.
    var actions: [ProseAction] = []

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
        context.coordinator.actions = actions
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

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var actions: [ProseAction]

        /// The last markdown parsed, and what it parsed to. `sizeThatFits` and `updateUIView`
        /// both need the attributed string and SwiftUI calls them in either order and more than
        /// once per change, so without this a scrolling list re-parses the same message
        /// several times a frame.
        private var cachedMarkdown: String?
        private var cachedAttributed: NSAttributedString?
        /// Invalidates the cache when the text size changes, since the base font is baked in.
        private var cachedCategory: UIContentSizeCategory?

        /// Whether `cachedAttributed` has already been handed to `view`, tracked explicitly
        /// rather than by reading `view.attributedText` back and comparing. `UITextView`
        /// normalizes what it is handed on the way into its text storage, so the getter can
        /// hand back a copy that is not `isEqual` to what was just set — confirmed unequal for
        /// link/code-bearing prose, the shape of the 3.7K-character message this was measured
        /// against, though simple prose can round-trip equal. A guard keyed on that comparison
        /// is therefore unreliable rather than merely slow: on the prose that matters it never
        /// short-circuits, so `sizeThatFits` measuring a scrolling row several times a frame was
        /// reassigning `attributedText` and forcing a relayout before the measurement it was
        /// there to speed up (3.54ms vs 2.09ms measure-only). Cleared whenever the cache above
        /// is invalidated, which is every case that legitimately needs a reassignment.
        private var appliedCachedAttributed = false

        /// How many times `apply` has actually assigned `attributedText`, kept only so a test
        /// can see the guard above short-circuit without timing anything.
        private(set) var assignmentCount = 0

        init(actions: [ProseAction]) {
            self.actions = actions
        }

        /// Put `markdown` into `view`, parsing only when it is genuinely new, and assigning
        /// only when what would be assigned has not already been.
        func apply(_ markdown: String, to view: UITextView) {
            let category = view.traitCollection.preferredContentSizeCategory
            if cachedMarkdown != markdown || cachedCategory != category || cachedAttributed == nil {
                cachedAttributed = TimelineProseText.attributed(markdown)
                cachedMarkdown = markdown
                cachedCategory = category
                appliedCachedAttributed = false
            }
            guard let attributed = cachedAttributed, !appliedCachedAttributed else { return }
            // See `appliedCachedAttributed` above for why this can't be a `view.attributedText
            // != attributed` comparison instead.
            view.attributedText = attributed
            appliedCachedAttributed = true
            assignmentCount += 1
        }

        /// **The actions are appended, not spliced in beside Copy.** The suggested actions arrive
        /// as an opaque list whose contents are the system's to change between releases, and
        /// reaching into it to find Copy is a lookup that silently does nothing the first time
        /// Apple renames it. Appended, they are the last items in the bar — which on a selection
        /// with the standard actions is the position immediately after Copy anyway.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0, !actions.isEmpty else { return nil }
            let selected = (textView.text as NSString).substring(with: range)
            let added = actions.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in
                    action.perform(selected)
                }
            }
            return UIMenu(children: suggestedActions + added)
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
