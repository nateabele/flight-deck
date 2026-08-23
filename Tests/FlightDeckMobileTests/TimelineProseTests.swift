import FleetKit
import XCTest
@testable import FlightDeckMobile

/// How much of a message the row shows, and whether tapping it leads anywhere.
///
/// **Nothing here looks at a rendered view, and nothing here may.** Whether the ceiling's cut
/// reads as deliberate, whether a whole answer sits well among the tool cards around it, and
/// where a `List` floats a disclosure chevron on a four-screenful row are all layout, which has
/// no window in this process. `.superpowers/sdd/ui-renders/prose-full/` and docs/MOBILE.md's
/// checklist own those; the renders are what chose the ceiling and what moved "Read the whole
/// message" down to the cut.
///
/// What is reachable is the decision itself, and it is one decision with three consequences:
/// `proseLineLimit(for:)` answering `nil` is what draws a body whole, what takes the chevron
/// off the row, and what puts Copy on it instead. A test that let those three drift apart
/// would be describing a row that hides words with no way to reach them.
final class TimelineProseTests: XCTestCase {

    // MARK: What the row draws

    /// **The change, on the case it was asked for.** A real four-line answer off this machine's
    /// transcripts was cut at fourteen lines' worth of height and sent one tap away; 75.7% of
    /// the 7,987 real assistant messages here are shorter than that clamp, so for three
    /// messages in four the drill-down led to the same words over again.
    func testARealAnswerIsDrawnWholeOnTheRow() {
        XCTAssertNil(
            TimelineStyle.proseLineLimit(for: TimelineFixtures.assistantShortReply),
            "a short answer has nothing to cut and must be drawn whole"
        )
        for item in TimelineFixtures.markdownConversation {
            XCTAssertNil(
                TimelineStyle.proseLineLimit(for: item),
                "a real assistant message is read in the conversation, not one tap from it"
            )
        }
    }

    /// A reader's own turn is prose too — `rendersMarkdown` admits it, and 29.9% of real user
    /// turns carry a heading, a list or a fence. It used to have its own twenty-line clamp,
    /// which is a different number and the same defect.
    func testAReadersOwnTurnIsDrawnWholeToo() {
        XCTAssertNil(TimelineStyle.proseLineLimit(for: TimelineFixtures.userTurn))
    }

    /// **Machine text keeps its clamp, and the three kinds keep three different ones.** A
    /// thinking block is styled as one italic secondary six-line whole; a `.prompt` and an
    /// `.unknown` are sentences the Mac composed and bytes from a newer Mac. None of them is
    /// what a reader opened the session to read, and a 64 KB body drawn whole inline is the
    /// case the detail screen exists for.
    func testMachineTextIsStillClamped() {
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.thinking), 6)
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.prompt), 14)
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.unknown), 14)
    }

    /// The ceiling, on the real message it was chosen against: 6,775 characters, 201 lines in
    /// the row's column, past the 99th percentile of the corpus on this machine.
    ///
    /// **The bound is not a reading limit, it is what stops one message being the whole
    /// screen** — the largest user turn here is a 64 KB paste, which is around a thousand
    /// lines. Unbounded it renders 4,067pt tall, six screenfuls with the conversation nowhere
    /// near it (`ui-renders/prose-full/unbounded-light.png`).
    func testAMessagePastTheCeilingIsCutAtTheCeiling() {
        XCTAssertEqual(
            TimelineStyle.proseLineLimit(for: TimelineFixtures.assistantVeryLongAnswer),
            TimelineStyle.proseCeilingLines,
            "a body past the ceiling is cut at it, not at some other number"
        )
    }

    // MARK: Where a tap leads

    /// **A row that shows everything leads nowhere, and every row that hides something leads
    /// somewhere.** The two halves are one rule: a chevron onto a screen carrying the identical
    /// words promises more that is not there, and a body cut with nowhere to go loses words
    /// with no way to reach them. The second is the worse failure, which is why the negative
    /// controls below outnumber the positive one.
    func testOnlyARowThatHidesSomethingOpensTheDetailScreen() {
        for item in [TimelineFixtures.assistantShortReply, TimelineFixtures.userTurn,
                     TimelineFixtures.assistantHeadingAndList,
                     TimelineFixtures.assistantFencedCode] {
            XCTAssertFalse(
                TimelineStyle.opensDetail(item),
                "\(item.id) is drawn whole — a chevron on it points at nothing new"
            )
        }
        for item in [TimelineFixtures.assistantVeryLongAnswer, TimelineFixtures.thinking,
                     TimelineFixtures.prompt, TimelineFixtures.unknown,
                     TimelineFixtures.bashCall, TimelineFixtures.bashResult,
                     TimelineFixtures.readResult] {
            XCTAssertTrue(
                TimelineStyle.opensDetail(item),
                "\(item.id) shows less than it holds, so the row must lead to the rest"
            )
        }
    }

    /// The invariant underneath both of those, stated once so it cannot drift: **clamped and
    /// tappable are the same fact.** A prose body drawn whole must not open a screen, and one
    /// that was cut must.
    func testTheClampAndTheWayInAreOneDecision() {
        for item in TimelineFixtures.conversation + TimelineFixtures.markdownConversation
            + [TimelineFixtures.assistantVeryLongAnswer, TimelineFixtures.assistantShortReply]
        where TimelineStyle.rendersMarkdown(item) {
            XCTAssertEqual(
                TimelineStyle.proseLineLimit(for: item) != nil,
                TimelineStyle.opensDetail(item),
                "\(item.id): a cut body with no way in, or a whole one with a chevron"
            )
        }
    }

    // MARK: Counting the lines

    /// **Wraps, not newlines.** A real answer is written as long paragraphs with hard breaks
    /// only between them — the fixture below is one unbroken line — so a count that read `\n`
    /// alone would call a 6,775-character message one line and draw every one of them whole.
    func testALineIsWhatWrapsNotWhatWasTyped() {
        let oneLongParagraph = String(repeating: "measured in characters, not in returns. ", count: 60)
        XCTAssertFalse(oneLongParagraph.contains("\n"), "the fixture has to have no breaks in it")
        XCTAssertTrue(
            TimelineStyle.exceeds(20, oneLongParagraph),
            "2,400 characters in a 42-character column is far past twenty lines"
        )
    }

    /// The boundary, both sides of it, on hard breaks alone: `limit` lines is not past `limit`.
    /// An off-by-one here clamps a body that fits, which is a chevron onto nothing.
    func testExactlyTheLimitIsNotPastIt() {
        let three = "one\ntwo\nthree"
        XCTAssertFalse(TimelineStyle.exceeds(3, three), "three lines do not exceed three")
        XCTAssertTrue(TimelineStyle.exceeds(2, three), "three lines do exceed two")
    }
}
