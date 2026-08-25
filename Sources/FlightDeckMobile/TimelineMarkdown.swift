import MarkdownUI
import SwiftUI

/// How the timeline draws the Markdown the agents actually write.
///
/// **Why a library and not `AttributedString(markdown:)`.** 7,944 real assistant messages were
/// counted out of the transcripts on this machine: 14.9% carry a heading, a list, a fenced
/// block, a table, a quote or a rule, and 31.6% are more than one paragraph.
/// `AttributedString(markdown:)` handles *inline* markup only — a `# Heading` stays a literal
/// `# Heading`, a `- ` stays a literal `- ` — and its default parse joins paragraphs with no
/// separator at all. Both of those are the bug this file exists to fix, so the zero-dependency
/// option is not a cheaper version of this, it is the status quo with the asterisks removed
/// from one message in seven.
///
/// **The one rule this theme may not break**, and the reason it is a hand-written theme rather
/// than `.basic` or `.gitHub`: monospace is for machine text. A long answer set in monospace
/// fits about 38 characters to the line on a 393pt phone and turns into a grey wall — that was
/// measured off a render, and it is why `TimelineRow.proseFont` is the system font today. So
/// exactly two things here are monospaced, `code` and `codeBlock`, and every other style
/// inherits the ambient system font at the size its row chose.
@MainActor
enum TimelineMarkdown {

    /// The theme both the row and the detail screen draw with, so a message cannot look like
    /// two different messages two taps apart — the same reason `TimelineStyle` is one enum of
    /// pure functions rather than modifiers on each view.
    ///
    /// **`@MainActor` is a fact about the pinned version, not a preference.** This target is
    /// Swift 6, and MarkdownUI's `Theme` is a bag of `BlockStyle` view builders that only
    /// became `Sendable` in commit a9c7615 — which landed four days *after* 2.4.1 and is in no
    /// released tag at all, the package having gone into maintenance mode since. So a plain
    /// `static let` is "not concurrency-safe because non-'Sendable' type 'Theme' may have
    /// shared mutable state", and the isolation goes here rather than the pin moving to a
    /// branch. Every caller is a SwiftUI `body`, which is already on this actor. If a release
    /// ever carries that commit, this annotation is what comes off.
    ///
    /// Sizes are relative (`em`), never absolute, so every one of them tracks Dynamic Type off
    /// whatever `.font` the enclosing view set. An absolute point size here would pin a heading
    /// at 17pt while the paragraph under it grew to 53 at
    /// `.accessibilityExtraExtraExtraLarge`, which is the failure docs/MOBILE.md item 29
    /// exists to catch.
    /// Light purple, and two of them, because one value cannot be both.
    ///
    /// A tint that reads as "slightly purple" against white is too dark to read against
    /// black, and the light-on-dark value washes out to nearly invisible the other way. Each
    /// side is picked against its own background rather than derived from the other.
    static let codeTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.70, blue: 1.00, alpha: 1)
            : UIColor(red: 0.40, green: 0.26, blue: 0.70, alpha: 1)
    })

    /// The wash behind a code span. Deliberately faint — this sits inside running prose, and
    /// anything stronger turns a paragraph with three spans in it into a striped page.
    ///
    /// Neutral white on dark rather than a tinted one: over the dark background a purple wash
    /// reads as a colour cast on the text rather than as a surface behind it.
    static let codeWash = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.10)
            : UIColor(red: 0.45, green: 0.30, blue: 0.75, alpha: 0.09)
    })

    static let theme = Theme()
        // Inline code: the tool card's font, one step down, because a `git status` inside a
        // sentence is the same kind of thing as a `git status` in a command panel — now with
        // a tint and a wash behind it, so a span is findable at a glance instead of being
        // distinguishable only by letterform.
        //
        // **`BackgroundColor` here is a TEXT style, not `.background()`.** The note this
        // replaces said an inline background was impossible because it "paints the full line
        // box, so a code span in the middle of a wrapped paragraph draws a bar through the
        // lines above and below it". That is true of the view modifier and not of this: a
        // text style is an attribute on the run, so it paints the glyphs' own box and wraps
        // with them. The original conclusion was right about the tool it had tried.
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            ForegroundColor(Self.codeTint)
            BackgroundColor(Self.codeWash)
        }
        .strong { FontWeight(.semibold) }
        .emphasis { FontStyle(.italic) }
        .link { ForegroundColor(.accentColor) }
        // Headings, flattened hard. `.basic` opens at 2em, which is 34pt on a phone: a row
        // whose first line is a banner, above the answer the reader is actually here for. The
        // job of a heading in a phone-width column is to be *found*, and weight does that in
        // less vertical space than size. h4-h6 carry no size change at all, only weight —
        // below 1em a heading is smaller than the prose it introduces, which reads as a
        // caption rather than as a heading.
        .heading1 { heading($0, size: 1.28) }
        .heading2 { heading($0, size: 1.14) }
        .heading3 { heading($0, size: 1.0) }
        .heading4 { heading($0, size: 1.0) }
        .heading5 { heading($0, size: 1.0) }
        .heading6 { heading($0, size: 1.0) }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.12))
                // Less than `.basic`'s full `1em` blank line. A phone column is narrow enough
                // that a paragraph break is legible at two thirds of a line, and the rows are
                // clamped — every point spent on air is a point of the answer not shown.
                .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        // A leading rule rather than `.basic`'s 2em indent. Indentation alone is invisible
        // once a quote wraps, and 2em of a 393pt column is a lot to give up.
        .blockquote { configuration in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        // The tool card's surface, exactly: same fill, same 10pt continuous corner, same
        // monospaced footnote. A fenced block in an answer and a command panel below it are
        // the same kind of object, and the render is what says so.
        //
        // **No horizontal `ScrollView`, which is what `.basic` wraps this in.** These land
        // inside `List` rows that are `NavigationLink`s, and a scroll view in a row competes
        // with the row for the gesture. Long lines wrap instead — which is also what the
        // detail screen already does with a tool's own output, so the two agree.
        .codeBlock { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.15))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.86))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .listItem { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .em(0.15))
        }
        .list { configuration in
            configuration.label.markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: .zero, bottom: .em(0.7))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                    FontSize(.em(0.88))
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativePadding(.horizontal, length: .em(0.6))
                .relativePadding(.vertical, length: .em(0.3))
        }
        .thematicBreak {
            Divider().markdownMargin(top: .em(0.4), bottom: .em(0.9))
        }

    /// Every heading level, one shape: semibold, a little air above it and almost none below,
    /// so it sits with the block it introduces rather than floating between two.
    private static func heading(
        _ configuration: BlockConfiguration, size: CGFloat
    ) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: .em(0.8), bottom: .em(0.25))
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(size))
            }
    }
}
