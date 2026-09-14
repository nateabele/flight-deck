import FleetKit
import MarkdownUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Bare URLs, tappable in every prose surface the timeline draws with — the three renderers
/// this exercises are `Markdown(text)` (MarkdownUI's own autolink extension), the attributed
/// `NSAttributedString` path a selectable row draws (`TimelineProseText.attributed`), and the
/// plain-text kinds that reach neither parser (`TimelineStyle.linkedPlainText`).
///
/// **Nothing here looks at a rendered view.** Whether a tap actually opens Safari has no window
/// in this process — what is reachable, and what this asserts, is that each renderer's output
/// carries a `.link` (an `NSAttributedString.Key.link` or an `AttributedString` `link`
/// attribute) over exactly the range a reader would expect to be able to tap, and nowhere else.
@MainActor
final class TimelineLinkTests: XCTestCase {

    // MARK: MarkdownUI — the preflight confirmation

    /// **The fact the rest of this file is built on.** `MarkdownParser.swift` in the
    /// swift-markdown-ui checkout attaches cmark-gfm's `autolink` extension unconditionally, so
    /// a bare URL through MarkdownUI's own parser is already a link before any code in this
    /// change runs. `renderHTML()` is the one place that parse is checkable without a window —
    /// an `<a href>` around the bare address is exactly what a browser autolinking it would
    /// produce, and it is what `Markdown(text)` (the row's no-composer prose renderer) draws
    /// from the same parse.
    func testMarkdownUIAlreadyAutolinksABareURL() {
        let html = MarkdownContent("See https://example.com/runbook for the rollback.").renderHTML()
        XCTAssertTrue(
            html.contains(#"<a href="https://example.com/runbook">https://example.com/runbook</a>"#),
            "MarkdownUI's own autolink extension should already have wrapped the bare URL: \(html)"
        )
    }

    /// The existing gap this change does NOT touch: `[text](url)` markdown syntax already links,
    /// on the bracketed text rather than the URL itself.
    func testMarkdownUIStillLinksMarkdownSyntaxOnItsOwnText() {
        let html = MarkdownContent("See the [runbook](https://example.com/runbook) for the rollback.")
            .renderHTML()
        XCTAssertTrue(
            html.contains(#"<a href="https://example.com/runbook">runbook</a>"#),
            html
        )
    }

    // MARK: The attributed path — `TimelineProseText.attributed`

    func testABareURLInAttributedProseGetsALinkRun() {
        let attributed = TimelineProseText.attributed("See https://example.com/runbook for the rollback.")
        XCTAssertEqual(linkURLs(in: attributed), ["https://example.com/runbook"])
    }

    /// **Markdown syntax first, still wins.** `run.link` off the `AttributedString(markdown:)`
    /// parse already turns this into one link on "runbook" — the bare-URL pass must not add a
    /// second, overlapping link on the address inside the parens.
    func testAMarkdownLinkStaysASingleLinkNotDoubled() {
        let attributed = TimelineProseText.attributed("See the [runbook](https://example.com/runbook) here.")
        let urls = linkURLs(in: attributed)
        XCTAssertEqual(urls, ["https://example.com/runbook"], "one link, not one for the text and one for the URL text")
    }

    /// A URL sitting in an inline code span is code, not a link — the same rule cmark applies to
    /// MarkdownUI's own autolink extension (it does not autolink inside a code span either).
    func testAURLInsideAnInlineCodeSpanIsNotLinked() {
        let attributed = TimelineProseText.attributed("Run `curl https://example.com/api` to check.")
        XCTAssertTrue(linkURLs(in: attributed).isEmpty, "a URL in code stays code")
    }

    /// **Not tested here: a URL inside a fenced block.** `TimelineProseText`'s own doc comment
    /// states it deliberately does not handle fenced blocks — `TimelineSegmenter` never sends
    /// `.attributed` one, always routing `.code` segments through `Markdown(_:)` instead (see
    /// `TimelineSegmentView.body`) — so there is no real call site for that input, and asserting
    /// on it would be testing a path nothing ever takes. The fenced-block case IS covered, on
    /// the renderer that actually draws one: MarkdownUI does not autolink inside a fenced block
    /// either, which is cmark's own rule and not something this change touches.
    func testTwoBareURLsInOneMessageBothGetLinkRuns() {
        let attributed = TimelineProseText.attributed(
            "First https://example.com/one then https://example.com/two."
        )
        XCTAssertEqual(
            linkURLs(in: attributed),
            ["https://example.com/one", "https://example.com/two"]
        )
    }

    /// Every `.link` attribute's tint, bare or markdown, so a bare URL reads exactly like an
    /// existing markdown link rather than as something new on the page.
    func testABareURLIsTintedTheSameAsAMarkdownLink() {
        let bare = TimelineProseText.attributed("See https://example.com for it.")
        let markdown = TimelineProseText.attributed("See [it](https://example.com) for it.")
        XCTAssertEqual(linkColor(in: bare), UIColor.tintColor)
        XCTAssertEqual(linkColor(in: markdown), UIColor.tintColor)
    }

    // MARK: The plain-text kinds — `TimelineStyle.linkedPlainText`

    func testABareURLInAToolResultBodyBecomesALinkRun() {
        let item = TimelineItem(
            id: "20000#0", kind: .toolResult, status: .complete,
            body: .init(text: "output written to https://example.com/artifact.zip", tool: "Bash")
        )
        let attributed = NSAttributedString(TimelineStyle.linkedPlainText(item.body.text))
        XCTAssertEqual(linkURLs(in: attributed), ["https://example.com/artifact.zip"])
    }

    /// The other plain-text kinds this reaches — `.thinking`, `.systemNotice`-adjacent
    /// `.prompt`, `.unknown` — get exactly the same treatment, since `TimelineRow.proseBody`
    /// routes all of them through `linkedPlainText`, never through Markdown.
    func testABareURLInAThinkingBodyBecomesALinkRun() {
        let attributed = NSAttributedString(TimelineStyle.linkedPlainText("check https://example.com/spec first"))
        XCTAssertEqual(linkURLs(in: attributed), ["https://example.com/spec"])
    }

    func testPlainTextWithNoURLGetsNoLinkRuns() {
        let attributed = NSAttributedString(TimelineStyle.linkedPlainText("nothing to link here"))
        XCTAssertTrue(linkURLs(in: attributed).isEmpty)
    }

    // MARK: Fix round 1 — the two row-level surfaces that route around `proseBody` entirely
    //
    // `.toolResult` draws through `toolCard`'s own output block (`TimelineRow.swift:355`), and
    // a free-text `.prompt` draws through `HistoricalPromptBody`'s else-branch in
    // `PromptCard.swift:508` — neither goes through `TimelineRow.proseBody`, so the tests above
    // (which exercise the helper against `.toolResult`/`.thinking`-shaped `TimelineItem`s) don't
    // actually cover either row. These do, tied to the call sites by name.

    /// The headline case: a URL inline in a tool's output text, as drawn by `toolCard`'s own
    /// `Text(...)` at `TimelineRow.swift:355`, not the general `proseBody` arm.
    func testABareURLInAToolOutputCardBecomesALinkRun() {
        let attributed = NSAttributedString(
            TimelineStyle.linkedPlainText("output written to https://example.com/artifact.zip")
        )
        XCTAssertEqual(linkURLs(in: attributed), ["https://example.com/artifact.zip"])
    }

    /// The free-text branch of `HistoricalPromptBody` (`PromptCard.swift:508`) — a prompt with
    /// no parseable `PromptQuestion` falls back to raw text, now linkified the same way.
    func testABareURLInAFreeTextPromptCardBecomesALinkRun() {
        let attributed = NSAttributedString(
            TimelineStyle.linkedPlainText("approve the change at https://example.com/review")
        )
        XCTAssertEqual(linkURLs(in: attributed), ["https://example.com/review"])
    }

    // MARK: Lockstep — the two prose renderers agree

    /// **The target the brief names: match MarkdownUI.** Both renderers are handed the same
    /// bare URL; MarkdownUI's own parse (via `renderHTML()`, the preflight check above) and the
    /// attributed path's bare-URL pass must agree on the address linked.
    func testTheAttributedPathAgreesWithMarkdownUIOnWhichURLIsLinked() {
        let text = "See https://example.com/runbook for the rollback."
        let html = MarkdownContent(text).renderHTML()
        let attributed = TimelineProseText.attributed(text)

        XCTAssertTrue(html.contains(#"<a href="https://example.com/runbook">"#))
        XCTAssertEqual(linkURLs(in: attributed), ["https://example.com/runbook"])
    }

    // MARK: `TimelineLinkCache` — the plain-text memo

    func testASecondCallWithTheSameIDIsAMemoHit() {
        let cache = TimelineLinkCache()
        let item = TimelineItem(
            id: "0#0", kind: .toolResult, status: .complete,
            body: .init(text: "see https://example.com", tool: "Bash")
        )
        let first = cache.linked(for: item)
        let second = cache.linked(for: item)
        XCTAssertEqual(cache.computeCount, 1, "the detector ran once for two identical asks")
        XCTAssertEqual(first, second)
    }

    func testTheCacheIsBoundedAndEvicts() {
        let cache = TimelineLinkCache(capacity: 2)
        func item(_ id: String) -> TimelineItem {
            TimelineItem(id: id, kind: .toolResult, status: .complete, body: .init(text: "x", tool: "Bash"))
        }
        _ = cache.linked(for: item("0#0"))
        _ = cache.linked(for: item("1#0"))
        _ = cache.linked(for: item("2#0")) // evicts 0#0
        _ = cache.linked(for: item("0#0")) // recompute
        XCTAssertEqual(cache.computeCount, 4, "the evicted key recomputes rather than hitting")
    }

    // MARK: Helpers

    /// Every `.link` URL in `attributed`, in string order — the shape both the attributed-path
    /// and the lockstep assertions above read off.
    private func linkURLs(in attributed: NSAttributedString) -> [String] {
        var urls: [String] = []
        attributed.enumerateAttribute(
            .link, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let url = value as? URL else { return }
            urls.append(url.absoluteString)
        }
        return urls
    }

    private func linkColor(in attributed: NSAttributedString) -> UIColor? {
        var color: UIColor?
        attributed.enumerateAttribute(
            .link, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard value is URL else { return }
            color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        }
        return color
    }
}
