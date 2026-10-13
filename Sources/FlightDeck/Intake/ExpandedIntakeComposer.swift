import SwiftUI

/// How the composer's Markdown editor looks: the plan document's own theme at a scale, so the
/// list's composer, the popover's and the main view's are one style at different sizes
/// rather than three. The inline one's 13 pt body is the `TextEditor` it replaced.
struct ComposerStyle: Equatable {
    var scale: CGFloat
    /// No gutter lanes and no minimum height — see `PlanTextView.compact`.
    var compact: Bool

    /// Heading sizes and the room above them, replacing the scaled plan's: at the list's width a
    /// scaled `#` (about 21 pt) outweighs the request under it, so the inline box steps its
    /// headings only a little above its body and keeps them close to the line before.
    var headingSizes: [CGFloat]?
    var headingSpaceBefore: [CGFloat]?

    static let expanded = ComposerStyle(scale: 1, compact: false)
    static let inline = ComposerStyle(scale: 13 / PlanTheme.standard.body.pointSize, compact: true,
                                      headingSizes: [16, 15, 14, 13, 13, 13], headingSpaceBefore: [8, 8, 6, 4, 4, 4])

    var theme: PlanTheme {
        var theme = PlanTheme.standard.scaled(by: scale)
        if let headingSizes { theme.headingSizes = headingSizes }
        if let headingSpaceBefore { theme.headingSpaceBefore = headingSpaceBefore }
        return theme
    }
}

/// The Markdown-styled draft editor under every composer: the plan editor on `text`, committing
/// each keystroke (see `PlanTextView.commitsEachKeystroke`), in a scroll view.
struct ComposerEditor: View {
    @Binding var text: String
    var style: ComposerStyle
    var focusOnAppear = false
    let identifier: String

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                PlanTextView(text: $text, editable: true, onCommit: { _ in }, incoming: nil, onShowIncoming: {},
                             theme: style.theme, compact: style.compact, focusOnAppear: focusOnAppear, identifier: identifier)
                    .committingEachKeystroke()
                    .filling(height: proxy.size.height)
            }
        }
    }
}

/// The intake composer taking over the detail pane, for a request long enough to want room: the
/// plan document's own editor (`PlanTextView`, so headings, lists, bold and code are styled as
/// they are in a plan) at the document's margins, under "Describe what you want…". The draft is
/// the list composer's `intent`, written on every keystroke, so collapsing — or Triage, which
/// reads `intent` at once — never loses the last few characters to the plan editor's idle commit.
struct ExpandedIntakeComposer: View {
    @Binding var intent: String
    let onTriage: () -> Void
    let onCollapse: () -> Void

    /// `IntakeDetailView`'s document margin, and a cap on the column so a wide window reads as a
    /// centred page rather than a line of text running edge to edge.
    static let margin: CGFloat = 20
    static let columnWidth: CGFloat = 820

    /// Where the editor's text starts inside its view (the gutter lanes and the line's own
    /// padding): the heading, the corner button and Triage sit on the
    /// text column's edges rather than the pane's, so the button is beside the text it acts on.
    private static let columnInset = PlanGutter.width(churn: false) + 5
    private static let trailingInset = PlanGutter.trailingMargin - 5

    private var empty: Bool { intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Describe what you want…").font(.headline)
                Spacer(minLength: 0)
                IntakeComposerResizeButton(expanded: true, action: onCollapse)
            }
            .padding(.leading, Self.columnInset)
            .padding(.trailing, Self.trailingInset)
            ComposerEditor(text: $intent, style: .expanded, identifier: "intake-intent-expanded-field")
            HStack {
                Spacer()
                Button("Triage", action: onTriage)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(empty)
                    .accessibilityIdentifier("intake-triage-expanded")
            }
            .padding(.leading, Self.columnInset)
            .padding(.trailing, Self.trailingInset)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 18)
        .frame(maxWidth: Self.columnWidth + 2 * Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The corner arrow on the composer, either way: expand from the list or popover, collapse from
/// the main view (Esc too, in the main view — see `ExpandedIntakeComposer`).
struct IntakeComposerResizeButton: View {
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .modifier(CollapseShortcut(enabled: expanded))
        .help(expanded ? "Collapse the editor" : "Expand the editor")
        .accessibilityLabel(expanded ? "Collapse the editor" : "Expand the editor")
        .accessibilityIdentifier(expanded ? "intake-composer-collapse" : "intake-composer-expand")
    }

    /// Esc collapses, as it cancels the popover: the shortcut rides the button because a
    /// focused text view takes Esc itself, but a key-equivalent still reaches the button first.
    private struct CollapseShortcut: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.keyboardShortcut(.cancelAction) } else { content }
        }
    }
}
