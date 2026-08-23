import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The boundary between prose and machine text, and what VoiceOver is given on each side of it.
///
/// **Nothing here looks at a rendered view**, and nothing here may: whether a heading is
/// legible, whether the row's height clamp reads as deliberate and whether a fenced block's
/// surface separates it from the paragraph above are all layout, which has no window in this
/// process. `.superpowers/sdd/ui-renders/markdown/` and docs/MOBILE.md's checklist own those.
///
/// What IS reachable is every rule about *which parser touches which body* — and that rule has
/// a sharp edge. cmark reads a diff's leading `-` as a bullet and reflows the line: a real
/// `- removed line` comes back out of the plain-text renderer as `  - removed line`, indented,
/// with the `+` line folded into the same list. So "tool bodies are not Markdown" is not a
/// stylistic preference to be asserted loosely; it is the difference between a diff that says
/// what happened and one that says the opposite.
final class TimelineMarkdownTests: XCTestCase {

    // MARK: Which bodies are Markdown at all

    /// The `false` arm of `rendersMarkdown`, which is the load-bearing one.
    ///
    /// A `.toolCall`'s body is pretty-printed JSON the Mac cut at the byte cap wherever that
    /// landed, and a `.toolResult`'s is command output. Handing either to a Markdown parser
    /// breaks the rule `TimelineItem.Body.text` states in full — and does it silently, on
    /// exactly the largest and most useful bodies.
    func testAToolBodyIsNeverHandedToTheMarkdownParser() {
        for item in [TimelineFixtures.bashCall, TimelineFixtures.readCall,
                     TimelineFixtures.bashResult, TimelineFixtures.readResult,
                     TimelineFixtures.failingResult, TimelineFixtures.unknown] {
            XCTAssertFalse(
                TimelineStyle.rendersMarkdown(item),
                "\(item.kind) is machine text — a parser reflows the only structure it has left"
            )
        }
    }

    /// The `true` arm, and **both** halves of it. A user's own turn is not a lesser case: of
    /// 1,302 real user text blocks on this machine 29.9% carry a heading, a list or a fence,
    /// because that is how a brief gets written.
    func testTheTwoKindsAPersonWroteAreReadAsMarkdown() {
        XCTAssertTrue(TimelineStyle.rendersMarkdown(TimelineFixtures.assistantHeadingAndList))
        XCTAssertTrue(
            TimelineStyle.rendersMarkdown(TimelineFixtures.userTurn),
            "a prompt is written in Markdown as surely as an answer is"
        )
        XCTAssertFalse(
            TimelineStyle.rendersMarkdown(TimelineFixtures.thinking),
            "thinking is styled as one italic secondary block, and per-block styling undoes it"
        )
    }

    // MARK: What VoiceOver is given

    /// **The same defect as the visible one, one layer down.** A raw body reaches a label as it
    /// was typed, so a listener gets the asterisks around `**All tests pass**` and the two
    /// number signs opening `## Result` — and unlike a reader they cannot skim past them.
    func testAVoiceOverLabelSaysTheWordsNotTheSyntaxCarryingThem() {
        let spoken = TimelineStyle.accessibilityLabel(
            for: TimelineFixtures.assistantHeadingAndList, agent: "claude"
        )

        XCTAssertTrue(spoken.hasPrefix("Claude. "), spoken)
        XCTAssertTrue(spoken.contains("Result"), "the heading's words survive: \(spoken)")
        XCTAssertTrue(spoken.contains("All tests pass"), spoken)
        XCTAssertFalse(spoken.contains("*"), "an emphasis marker read aloud: \(spoken)")
        XCTAssertFalse(spoken.contains("`"), "a code fence marker read aloud: \(spoken)")
        XCTAssertFalse(spoken.contains("#"), "a heading marker read aloud: \(spoken)")
    }

    /// A fenced block is spoken as the code inside it, never as its fence — and that holds when
    /// the byte cap cut the body before the closing fence ever arrived, which is the only way a
    /// long answer reaches the phone at all.
    func testAFencedBlockIsSpokenAsItsCodeAndNotAsItsFence() {
        let whole = TimelineStyle.spoken(TimelineFixtures.assistantFencedCode)
        XCTAssertTrue(whole.contains("perf: cut main-thread file work"), whole)
        XCTAssertFalse(whole.contains("```"), "the fence itself, read aloud: \(whole)")

        let cutMidFence = TimelineItem(
            id: "20100#0", kind: .assistantText, status: .complete,
            body: .init(text: "Here it is:\n\n```swift\nlet limits = TimelineLimits()",
                        truncatedBytes: 4_096),
            at: nil
        )
        XCTAssertTrue(
            TimelineStyle.spoken(cutMidFence).contains("let limits = TimelineLimits()"),
            "an unterminated fence must not swallow the code it opened on"
        )
    }

    /// The other side of the boundary, said the strongest way available: **byte-identical**.
    ///
    /// This is the assertion that catches the diff bug concretely. Run through cmark, the body
    /// below comes back as an indented two-item bullet list and the `***` becomes a horizontal
    /// rule — a stack trace and a diff turned into something that reads as deliberate prose.
    func testAToolResultIsSpokenExactlyAsItArrived() {
        let diff = TimelineItem(
            id: "20440#0", kind: .toolResult, status: .complete,
            body: .init(text: "- removed line\n+ added line\n*** frame ***\n  __init__ ran",
                        tool: "Bash", callID: "toolu_09Diff"),
            at: nil
        )

        XCTAssertEqual(
            TimelineStyle.spoken(diff), diff.body.text,
            "machine text is announced as it arrived, markers and all"
        )
    }

    /// The fallback, and it is reachable rather than defensive decoration: cmark renders a body
    /// that is nothing but an HTML comment as the **empty string**. Returning that would drop a
    /// row out of VoiceOver entirely — a silent stop on a list, with no way to tell it from a
    /// blank message.
    func testAProseBodyTheParserMakesNothingOfIsStillSaid() {
        let commentOnly = TimelineItem(
            id: "20780#0", kind: .assistantText, status: .complete,
            body: .init(text: "<!-- the agent emitted only a comment -->"), at: nil
        )

        XCTAssertEqual(TimelineStyle.spoken(commentOnly), commentOnly.body.text)
    }
}
