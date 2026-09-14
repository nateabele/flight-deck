import Foundation

/// Bare-URL detection, shared by every renderer that draws text MarkdownUI's own parser never
/// touches.
///
/// **Why this exists at all.** `[text](url)` is Markdown syntax, and every prose renderer here
/// already understands it — MarkdownUI parses it, and `TimelineProseText.attributed` reads
/// `run.link` off the same parse. A bare `https://…` typed inline with no brackets around it is
/// different: MarkdownUI's cmark-gfm `autolink` extension (`MarkdownParser.swift`) catches it
/// for the one renderer that runs a Markdown parser at all, and nothing catches it for the
/// other two — the attributed `NSAttributedString` path (`AttributedString(markdown:)` does not
/// autolink) and the plain-text kinds (`.thinking`, `.toolResult`, `.systemNotice`, `.prompt`,
/// `.unknown`), which never reach a Markdown parser by design (`TimelineStyle`'s own doc
/// comment) and so would never autolink even if it did.
///
/// `NSDataDetector` is Foundation's own answer to "is there a URL in this string" — it already
/// knows `www.` has no scheme, and that a sentence's trailing period is not part of the address
/// it ends. No new dependency, and no parsing rules of our own to keep in step with cmark's.
enum URLLinkDetection {
    /// Built once: `NSDataDetector` compiles its type mask into a set of NSRegularExpressions
    /// on init, and that cost has no reason to be paid per call.
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Every URL `NSDataDetector` finds in `text`, in string order.
    ///
    /// Ranges are **UTF-16 `NSRange`s** — the coordinate space `NSAttributedString` and
    /// `NSRange(_:in:)`/`Range<AttributedString.Index>(_:in:)` all share — so a caller can hand
    /// one straight to `addAttribute(_:value:range:)` or to an `AttributedString` conversion
    /// with no offset arithmetic of its own.
    static func matches(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector, !text.isEmpty else { return [] }
        let full = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, options: [], range: full).compactMap { match in
            guard let url = match.url else { return nil }
            return (match.range, url)
        }
    }
}
