import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Tap-to-expand: what the ceiling still cuts, what the More link is offered on, what a tap
/// changes, and what a long press now copies.
///
/// **Nothing here looks at a rendered view, and nothing here may.** Whether the link reads as a
/// control at `.caption2`, whether a collapsed answer sits well beside a tool card, and whether
/// the expanded row is legible at all are layout, which has no window in this process —
/// `.superpowers/sdd/ui-renders/expand/` owns those. The one runtime fact a test process *can*
/// reach is that a `List` throws a row away and rebuilds it, which is why the expansion state
/// is not on the row; `ProseExpansionRecyclingTests` drives that scroll and looks at what comes
/// back.
///
/// The boundary pair below is the spine of the file: `assistantJustUnderTheCeiling` is a real
/// 119-line answer and `assistantJustOverTheCeiling` a real 134-line one, either side of a
/// 120-line ceiling. Every rule here has to answer them differently, which is what stops a
/// "clamp everything" or a "clamp nothing" implementation from passing.
final class TimelineProseExpansionTests: XCTestCase {

    // MARK: What expanding changes

    /// **The change itself.** Collapsed, a body past the ceiling is cut at the ceiling;
    /// expanded, the row draws all of it. Both halves in one test because they are one
    /// decision — an implementation that answered `nil` in both states has removed the ceiling,
    /// and one that answered 120 in both has built a link that does nothing.
    func testTappingMoreDrawsTheWholeMessageAndTappingLessCutsItAgain() {
        let long = TimelineFixtures.assistantJustOverTheCeiling
        XCTAssertEqual(
            TimelineStyle.proseLineLimit(for: long, expanded: false),
            TimelineStyle.proseCeilingLines,
            "collapsed, a 134-line answer is cut at the ceiling"
        )
        XCTAssertNil(
            TimelineStyle.proseLineLimit(for: long, expanded: true),
            "expanded, the row draws the whole message — that is what More is for"
        )

        let collapsed = TimelineStyle.proseText(for: long, expanded: false)
        let expanded = TimelineStyle.proseText(for: long, expanded: true)
        XCTAssertEqual(expanded, long.body.text, "expanded, the row is handed the whole body")
        XCTAssertTrue(
            long.body.text.hasPrefix(collapsed),
            "the collapsed row is the beginning of the message, not a different message"
        )
        XCTAssertLessThan(
            collapsed.count, expanded.count,
            "collapsed, the row is handed strictly less — see the invariant below"
        )
    }

    /// **The defect the renders for this change found, stated as an invariant.**
    ///
    /// The row used to be bounded by *height* — `23pt × 120` with the overflow clipped — while
    /// the link was decided by a *line count* estimated at 42 characters to the line. Two
    /// measurements of the same number, and they disagree by ten to fifteen per cent: a real
    /// 134-line answer laid out at 2,770.67pt in both states — the clamp never bit — so the row
    /// drew More and tapping it moved nothing at all. Four of the nine over-ceiling messages in this machine's
    /// transcripts sit in that dead band, so it was not an edge case.
    ///
    /// Both directions, because both are ways of lying to a reader: a link on a row that is
    /// already showing everything, and a row cut short with no link on it.
    func testAMoreLinkAppearsExactlyWhenTheRowIsHoldingSomethingBack() {
        let prose = (TimelineFixtures.conversation + TimelineFixtures.markdownConversation
            + [TimelineFixtures.assistantVeryLongAnswer, TimelineFixtures.assistantShortReply,
               TimelineFixtures.assistantJustUnderTheCeiling,
               TimelineFixtures.assistantJustOverTheCeiling])
            .filter(TimelineStyle.rendersMarkdown)
        XCTAssertFalse(prose.isEmpty, "no prose fixtures, so this test asserts nothing")

        for item in prose {
            let drawn = TimelineStyle.proseText(for: item)
            if TimelineStyle.expandsInPlace(item) {
                XCTAssertLessThan(
                    drawn.count, item.body.text.count,
                    "\(item.id) offers More while already drawing every word it has"
                )
            } else {
                XCTAssertEqual(
                    drawn, item.body.text,
                    "\(item.id) is cut short with no way to reach the rest"
                )
            }
        }
    }

    /// The cut itself, on hard breaks alone, both sides of the boundary — the mirror of
    /// `TimelineProseTests.testExactlyTheLimitIsNotPastIt`, and it has to be: the two functions
    /// count lines the same way or a row offers More and shows the same words.
    func testTheCutIsWhereTheLineCountRunsOut() {
        let three = "one\ntwo\nthree"
        XCTAssertEqual(
            TimelineStyle.firstLines(3, of: three), three,
            "three lines are not past three, so nothing is cut"
        )
        XCTAssertEqual(
            TimelineStyle.firstLines(2, of: three), "one\ntwo",
            "the third line is cut at its start"
        )
    }

    /// **Wraps, not newlines** — the same rule `exceeds(_:_:)` counts by. A real answer is long
    /// paragraphs with hard breaks only between them, so a cut that looked for `\n` alone would
    /// hand a collapsed row the entire 6,775-character message and call it one line.
    func testTheCutCountsWrapsAsWellAsBreaks() {
        let oneLongParagraph = String(repeating: "measured in characters, not in returns. ", count: 60)
        XCTAssertFalse(oneLongParagraph.contains("\n"), "the fixture has to have no breaks in it")

        let cut = TimelineStyle.firstLines(2, of: oneLongParagraph, columns: 42)
        XCTAssertEqual(cut.count, 84, "two lines of a 42-character column is 84 characters")
    }

    /// Machine text is handed its body whole and clamped by `.lineLimit` in the row instead —
    /// `proseText` is the Markdown side only, because a `Markdown` view is a `VStack` of blocks
    /// and a line limit lands on each of them separately.
    func testMachineTextIsHandedItsWholeBody() {
        for item in [TimelineFixtures.thinking, TimelineFixtures.prompt,
                     TimelineFixtures.unknown, TimelineFixtures.readResult] {
            XCTAssertEqual(TimelineStyle.proseText(for: item), item.body.text)
        }
    }

    /// The reader's answer to the ceiling is the reader's answer to the *ceiling*, and nothing
    /// else on the screen. A thinking block's six lines are a style rather than a shortfall, and
    /// a `.prompt`, an `.unknown` and a tool body are machine text with a screen of their own —
    /// none of them draws a More link, so an `expanded: true` can only reach them by mistake and
    /// must change nothing when it does.
    func testExpandingUnclampsProseAndNothingElse() {
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.thinking,
                                                    expanded: true), 6)
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.prompt,
                                                    expanded: true), 14)
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.unknown,
                                                    expanded: true), 14)
        XCTAssertEqual(TimelineStyle.proseLineLimit(for: TimelineFixtures.bashResult,
                                                    expanded: true), 14)
    }

    // MARK: Who gets a link

    /// **The link is offered on exactly the bodies the ceiling bit**, and the two sides of the
    /// boundary are fifteen lines apart in one real conversation. A 119-line answer that drew a
    /// More link would point at nothing; a 134-line one that drew none would strand fourteen
    /// lines with no way to reach them.
    func testOnlyAnAnswerTheCeilingCutOffersMore() {
        XCTAssertFalse(
            TimelineStyle.expandsInPlace(TimelineFixtures.assistantJustUnderTheCeiling),
            "119 lines fit under a 120-line ceiling — nothing was cut, so nothing to offer"
        )
        XCTAssertTrue(
            TimelineStyle.expandsInPlace(TimelineFixtures.assistantJustOverTheCeiling),
            "134 lines do not, so the last fourteen need a way to arrive"
        )
        XCTAssertTrue(
            TimelineStyle.expandsInPlace(TimelineFixtures.assistantVeryLongAnswer),
            "the 201-line answer the ceiling was argued from"
        )
    }

    /// A reader's own turn is prose too — `rendersMarkdown` admits it, and a 64 KB paste is the
    /// case the ceiling exists for in the first place. A rule that read `.assistantText` alone
    /// would leave the longest bodies on the screen with no way out.
    func testALongUserTurnOffersMoreToo() {
        let paste = TimelineItem(
            id: "9000#0", kind: .userTurn, status: .complete,
            body: .init(text: String(repeating: "a line of a pasted stack trace\n", count: 200))
        )
        XCTAssertTrue(TimelineStyle.expandsInPlace(paste))
        XCTAssertNil(TimelineStyle.proseLineLimit(for: paste, expanded: true))
    }

    /// **Machine text never expands in place, however long it is.** A `.thinking`, a `.prompt`
    /// and an `.unknown` are clamped by kind rather than by the ceiling, and their way to the
    /// rest is the detail screen; a tool body is 64 KB of command output at the per-item cap,
    /// and unrolling one inline is the thing the clamp exists to prevent. The `readResult`
    /// fixture is a real cut 64 KB file read, so this is not a hypothetical.
    func testMachineTextNeverOffersMore() {
        for item in [TimelineFixtures.thinking, TimelineFixtures.prompt,
                     TimelineFixtures.unknown, TimelineFixtures.bashCall,
                     TimelineFixtures.readResult] {
            XCTAssertFalse(
                TimelineStyle.expandsInPlace(item),
                "\(item.id) is machine text: its way to the rest is the detail screen"
            )
        }
    }

    // MARK: One control, both directions

    /// Shut until the reader says otherwise, then open, then shut again. **The third assertion
    /// is the one with a defect behind it**: an implementation that only ever inserted would
    /// give a reader four screenfuls of an answer they have finished with and no way to put it
    /// away.
    func testMoreAndLessAreTheSameControl() {
        var expansion = SessionTimelineScreen.Expansion()
        let id = TimelineFixtures.assistantJustOverTheCeiling.id

        XCTAssertFalse(expansion.isExpanded(id), "a row opens collapsed")
        expansion.toggle(id)
        XCTAssertTrue(expansion.isExpanded(id), "More opens it")
        expansion.toggle(id)
        XCTAssertFalse(expansion.isExpanded(id), "and Less shuts it again")
    }

    /// **Opening one answer opens one answer.** A single `Bool` on the screen — the obvious
    /// wrong shape, and one line shorter than the right one — would open every long row in the
    /// conversation at once, which on a page holding three of them is a screen that jumps by
    /// twelve screenfuls on one tap.
    ///
    /// The near-miss ids at the end are the other half: the key is the record's byte offset in
    /// the file the agent wrote, so `7000#0` and `7000#1` are two different records that a
    /// prefix-ish comparison would confuse, and `7001#0` is one character from an open row.
    func testOpeningOneAnswerLeavesEveryOtherRowShut() {
        var expansion = SessionTimelineScreen.Expansion()
        let opened = TimelineFixtures.assistantJustOverTheCeiling.id
        let untouched = TimelineFixtures.assistantVeryLongAnswer.id
        XCTAssertNotEqual(opened, untouched, "two fixtures, or this test asserts a contradiction")

        expansion.toggle(opened)
        expansion.toggle("7000#0")

        XCTAssertTrue(expansion.isExpanded(opened))
        XCTAssertTrue(expansion.isExpanded("7000#0"))
        XCTAssertFalse(expansion.isExpanded(untouched), "its neighbour was not tapped")
        XCTAssertFalse(expansion.isExpanded("7000#1"), "a different record in the same file")
        XCTAssertFalse(expansion.isExpanded("7001#0"), "one character from an open row")
    }

    // MARK: What a long press copies

    /// **Copy now lands on every prose row, including the long ones.** It used to be withheld
    /// from an answer past the ceiling because that row led to a screen with a Copy button on
    /// it; that row leads nowhere now, so withholding it would leave the longest messages on
    /// the phone with no way to take them off it.
    func testALongAnswerIsCopiedFromTheRow() {
        let long = TimelineFixtures.assistantJustOverTheCeiling
        XCTAssertEqual(
            TimelineStyle.rowCopyText(for: long), long.body.text,
            "the whole message, not the hundred and twenty lines currently drawn"
        )
        XCTAssertEqual(
            TimelineStyle.rowCopyText(for: TimelineFixtures.assistantShortReply),
            TimelineFixtures.assistantShortReply.body.text
        )
    }

    /// The complement, and the reason the function exists rather than an unconditional gesture:
    /// two ways to copy one body a gesture apart is how a reader ends up unsure which of them
    /// took. Every row here has a Copy button on the screen it opens.
    func testARowThatLeadsToACopyButtonHasNoCopyGesture() {
        for item in [TimelineFixtures.bashCall, TimelineFixtures.readResult,
                     TimelineFixtures.thinking, TimelineFixtures.prompt,
                     TimelineFixtures.unknown] {
            XCTAssertNil(
                TimelineStyle.rowCopyText(for: item),
                "\(item.id) opens a screen whose blocks each carry Copy"
            )
        }
    }

    /// An empty body puts no Copy on the menu, because the alternative is a menu item that
    /// silently clears the clipboard.
    func testAnEmptyBodyHasNothingToCopy() {
        let empty = TimelineItem(
            id: "0#0", kind: .assistantText, status: .complete, body: .init(text: "")
        )
        XCTAssertNil(TimelineStyle.rowCopyText(for: empty))
    }
}
