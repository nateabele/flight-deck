import SwiftUI
import UIKit

/// `TimelineMarkdown.theme`, rebuilt as an `NSAttributedString`.
///
/// **This is a second renderer for one design, which is a thing worth being uneasy about.** It
/// exists because a `UITextView` is the only view on this platform that can hand a custom edit
/// menu the range it was raised on, and a `UITextView` draws attributed text — so selectable
/// prose and MarkdownUI prose cannot be the same code. What keeps the two from drifting is that
/// they are drawn from the same numbers: every size here is the `em` multiplier the theme uses,
/// named after the style it came from, and a change to one is a change to the other.
///
/// **What it deliberately does not handle**, because `TimelineSegmenter` never sends it any:
/// fenced blocks, tables, lists and quotes. Those are the segments MarkdownUI keeps, for the
/// plain reason that an attributed run cannot be a table.
@MainActor
enum TimelineProseText {

    /// Multipliers lifted from `TimelineMarkdown.theme`, so the two renderers scale together.
    private enum Em {
        static let code: CGFloat = 0.92
        static let lineSpacing: CGFloat = 0.12
        static let paragraphSpacing: CGFloat = 0.7
        static let headingSpacingBefore: CGFloat = 0.8
        static let headingSpacingAfter: CGFloat = 0.25
        /// `.heading1` … `.heading6`, flattened exactly as the theme flattens them: below h3 a
        /// heading carries weight only, because a heading smaller than its own paragraph reads
        /// as a caption.
        static func heading(_ level: Int) -> CGFloat {
            switch level {
            case 1: return 1.28
            case 2: return 1.14
            default: return 1.0
            }
        }
    }

    /// Prose markdown as attributed text, sized off `base` so Dynamic Type reaches every run.
    ///
    /// **Parsed with `.full`, and the parse is the part that does the work.** The `em` sizing
    /// and the flattened headings are this file's; knowing that a line is a heading at all is
    /// `AttributedString`'s, which reports block structure as `presentationIntent` runs when
    /// asked for the full syntax. The theme's own doc comment notes that `.inlineOnly` leaves
    /// `# Heading` as a literal — that is the parse this one is not.
    ///
    /// A body that will not parse comes back as itself, unstyled. That is the same answer the
    /// row gave before any of this existed, and it is the right one: prose that cannot be
    /// interpreted is still prose, and refusing to draw it would lose the message.
    static func attributed(
        _ markdown: String,
        base: UIFont = .preferredFont(forTextStyle: .body),
        color: UIColor = .label
    ) -> NSAttributedString {
        let parsed: AttributedString
        do {
            parsed = try AttributedString(
                markdown: markdown,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return NSAttributedString(string: markdown, attributes: [.font: base, .foregroundColor: color])
        }

        let output = NSMutableAttributedString()
        var previousBlock: Int?

        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let heading = intents.compactMap { component -> Int? in
                if case .header(let level) = component.kind { return level }
                return nil
            }.first
            // A block's identity, so a paragraph break is inserted between two blocks and never
            // inside one. `AttributedString` numbers them for exactly this.
            let block = intents.first?.identity

            if let block, block != previousBlock, output.length > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            previousBlock = block

            let size = base.pointSize * Em.heading(heading ?? 0)
            let inline = run.inlinePresentationIntent ?? []
            let isCode = inline.contains(.code)
            let font = font(size: isCode ? base.pointSize * Em.code : size,
                            bold: heading != nil || inline.contains(.stronglyEmphasized),
                            italic: inline.contains(.emphasized),
                            monospaced: isCode)

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isCode ? UIColor(TimelineMarkdown.codeTint) : color,
                .paragraphStyle: paragraphStyle(base: base, heading: heading),
            ]
            if isCode { attributes[.backgroundColor] = UIColor(TimelineMarkdown.codeWash) }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            // A link keeps the accent colour the theme gives it, and stays tappable: a
            // `UITextView` that is selectable and not editable opens `.link` on a tap while a
            // press-and-drag still selects.
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = UIColor.tintColor
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }

        return output
    }

    private static func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> UIFont {
        var font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
            : UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    /// Line spacing and the gap under a block, both relative to the base size so they track
    /// Dynamic Type — the rule docs/MOBILE.md item 29 exists to enforce.
    private static func paragraphStyle(base: UIFont, heading: Int?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = base.pointSize * Em.lineSpacing
        style.paragraphSpacing = base.pointSize
            * (heading == nil ? Em.paragraphSpacing : Em.headingSpacingAfter)
        if heading != nil { style.paragraphSpacingBefore = base.pointSize * Em.headingSpacingBefore }
        return style
    }
}
