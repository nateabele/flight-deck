import FleetKit
import XCTest
@testable import FlightDeckMobile

/// Where a body is split, and how a line budget is spent across the pieces.
///
/// **Nothing here renders anything**, and the split is worth testing precisely because of that:
/// it is the one part of selectable prose that is a pure function of text, so it can be pinned
/// exactly where the views above it can only be looked at. What a segmented body *looks* like
/// beside the same message rendered whole is `.superpowers/sdd/ui-renders/` and docs/MOBILE.md,
/// as it has to be — a margin that drifted by `.em(0.7)` has no assertion in this process.
///
/// The boundary being defended is: prose is what an `NSAttributedString` can honestly carry,
/// and everything else keeps MarkdownUI. Every case below is either a thing that must land on
/// one side of that line, or the budget arithmetic that decides how much of it a row draws.
final class TimelineSegmentTests: XCTestCase {

    // MARK: The split

    func testAPlainAnswerIsOneProseSegment() {
        let body = "The queue drains first.\n\nThen the flag flips."
        XCTAssertEqual(TimelineSegmenter.segments(of: body), [.prose(body)])
    }

    /// The shape the feature exists for: prose, a block of code, more prose. The block carries
    /// its contents **without** the fences, because that is what a reader pressing it copies.
    func testAFencedBlockSplitsTheProseAroundIt() {
        let body = """
        Here is the fix:

        ```swift
        func drain() {}
        ```

        Run it before the migration.
        """
        XCTAssertEqual(TimelineSegmenter.segments(of: body), [
            .prose("Here is the fix:"),
            .code(language: "swift", "func drain() {}"),
            .prose("Run it before the migration."),
        ])
    }

    /// **An unclosed fence is still a fence.** A message cut at the byte cap mid-block, or one
    /// an agent is still streaming, would otherwise flip into prose and render its code as a
    /// wall of markdown — the loudest possible way to be wrong about a body.
    func testAnUnclosedFenceRunsToTheEnd() {
        let body = "Here:\n\n```\nfunc drain() {\n  while let job ="
        XCTAssertEqual(TimelineSegmenter.segments(of: body), [
            .prose("Here:"),
            .code(language: nil, "func drain() {\n  while let job ="),
        ])
    }

    /// Inline code is prose and must stay prose — it is styled by the theme's `.code`, tint and
    /// wash, and pulling it out into its own segment would strip exactly that.
    func testInlineBackticksStayInsideProse() {
        let body = "Call `drain()` and then `flip(_:)` on the store."
        XCTAssertEqual(TimelineSegmenter.segments(of: body), [.prose(body)])
    }

    func testListsTablesAndQuotesBecomeRichBlocks() {
        let list = "- drain the queue\n- flip the flag"
        XCTAssertEqual(TimelineSegmenter.segments(of: list), [.richBlock(list)])

        let ordered = "1. drain the queue\n2. flip the flag"
        XCTAssertEqual(TimelineSegmenter.segments(of: ordered), [.richBlock(ordered)])

        let table = "| step | when |\n| --- | --- |\n| drain | first |"
        XCTAssertEqual(TimelineSegmenter.segments(of: table), [.richBlock(table)])

        let quote = "> the queue must drain first"
        XCTAssertEqual(TimelineSegmenter.segments(of: quote), [.richBlock(quote)])
    }

    /// A loose list is one list. Splitting it at its own paragraph breaks would hand MarkdownUI
    /// a series of one-item lists, each with its own margins, which is a visibly different
    /// object from the list the message contains.
    func testABlankLineInsideAListDoesNotEndIt() {
        let body = "- drain the queue\n\n- flip the flag"
        XCTAssertEqual(TimelineSegmenter.segments(of: body), [.richBlock(body)])
    }

    /// The near-misses. Each of these begins with a character a list or a fence begins with, and
    /// none of them is one.
    func testBoldRulesAndDecimalsAreNotBlockStarts() {
        for body in ["**drain** the queue first", "---", "3.5 seconds to drain", "*emphasis* only"] {
            XCTAssertEqual(
                TimelineSegmenter.segments(of: body), [.prose(body)],
                "\"\(body)\" is prose, not a block"
            )
        }
    }

    // MARK: The budget

    private func lines(_ count: Int, _ word: String = "line") -> String {
        (1...count).map { "\(word) \($0)" }.joined(separator: "\n")
    }

    func testABodyUnderTheBudgetIsDrawnWholeWithNoMore() {
        let clamped = TimelineSegmenter.clamp(lines(10), budget: 120)
        XCTAssertEqual(clamped.segments, [.prose(lines(10))])
        XCTAssertFalse(clamped.hasMore, "nothing was held back")
    }

    func testProseIsCutMidRunAndOffersMore() {
        let clamped = TimelineSegmenter.clamp(lines(200), budget: 20)
        guard case .prose(let kept)? = clamped.segments.first else {
            return XCTFail("expected a prose segment, got \(clamped.segments)")
        }
        XCTAssertTrue(clamped.hasMore, "180 lines were held back")
        XCTAssertLessThan(kept.count, lines(200).count, "the cut must be strictly shorter")
        XCTAssertTrue(kept.hasPrefix("line 1\n"), "the cut keeps the top of the message")
    }

    /// **The overshoot.** A budget that runs out inside a fenced block draws the block whole
    /// rather than a panel with no bottom edge, so the row runs past its ceiling by whatever
    /// that block costs.
    func testAFencedBlockStartingInsideTheBudgetIsDrawnWhole() {
        let body = lines(5) + "\n\n```\n" + lines(60, "code") + "\n```\n\nand afterwards"
        let clamped = TimelineSegmenter.clamp(body, budget: 10)
        XCTAssertEqual(
            clamped.segments.count, 2,
            "the prose above it and the whole block, and nothing after: \(clamped.segments)"
        )
        guard case .code(_, let code)? = clamped.segments.last else {
            return XCTFail("expected the block to survive whole, got \(clamped.segments)")
        }
        XCTAssertEqual(code, lines(60, "code"), "a cut block is a panel that lies about its end")
        XCTAssertTrue(clamped.hasMore, "\"and afterwards\" is still held back")
    }

    /// **The case that moved `hasMore` off the line count.** This body is over the ceiling by
    /// any measure, and yet every word of it is drawn — because the block that pushed it over
    /// is the last thing in the message. A More link here would open onto nothing, which is the
    /// exact defect `TimelineStyle.firstLines` was written to prevent.
    func testAMessageEndingOnAnOvershootingBlockOffersNoMore() {
        let body = lines(5) + "\n\n```\n" + lines(60, "code") + "\n```"
        let clamped = TimelineSegmenter.clamp(body, budget: 10)
        XCTAssertFalse(clamped.hasMore, "the overshoot consumed the remainder; there is no more")
        XCTAssertEqual(clamped.segments, [
            .prose(lines(5)),
            .code(language: nil, lines(60, "code")),
        ])
    }

    /// Trailing blank lines are not content. A body that ends on newlines must not draw a More
    /// link that opens onto whitespace.
    func testTrailingBlankLinesAreNotHeldBack() {
        let clamped = TimelineSegmenter.clamp(lines(5) + "\n\n\n", budget: 5)
        XCTAssertFalse(clamped.hasMore, "whitespace is not something to open onto")
    }

    /// A budget spent exactly, with a block still to come, is held back at the boundary — no
    /// half-drawn segment, and the More link is honest.
    func testAnExhaustedBudgetStopsAtASegmentBoundary() {
        let body = lines(10) + "\n\n```\ncode\n```"
        let clamped = TimelineSegmenter.clamp(body, budget: 10)
        XCTAssertEqual(clamped.segments, [.prose(lines(10))])
        XCTAssertTrue(clamped.hasMore)
    }

    // MARK: Back to markdown

    /// Reconstructing a block for MarkdownUI has one trap: contents that contain a fence. A
    /// three-backtick opener would end the block early, and the rest of the code would render
    /// as prose.
    func testAReconstructedFenceOutrunsTheBackticksInside() {
        let contents = "print(\"```\")"
        let fenced = TimelineSegment.fenced(language: "swift", contents)
        XCTAssertTrue(fenced.hasPrefix("````swift\n"), "got \(fenced)")
        XCTAssertEqual(
            TimelineSegmenter.segments(of: fenced), [.code(language: "swift", contents)],
            "a reconstructed block must split back into the block it came from"
        )
    }
}
