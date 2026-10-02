import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The decisions the timeline's rendering makes that are not layout.
///
/// Where a card's corner lands and how a monospaced line wraps are not reachable from a test
/// process and must never grow an assertion here — docs/MOBILE.md's checklist and the offscreen
/// renders own that. What IS reachable is every rule about *what text appears at all*, and that
/// is where this screen's real failures have been: a 64 KB file read reduced to one line, a
/// timestamp formatted from a date nobody has, a VoiceOver label that reads a whole transcript.
///
/// `@MainActor`: `time(_:)`/`timestamp(_:)` memoize their formatted output on a main-actor
/// cache (see `TimelineStyle`'s date memo) — every real call site is already on the main actor
/// (`TimelineRow.header`, `TimelineItemDetailScreen.header`, both inside a `View.body`), so the
/// class picks up the same isolation `TimelineLinkTests`/`TimelineSegmentCacheTests` already
/// carry for the same reason.
@MainActor
final class TimelineStyleTests: XCTestCase {

    // MARK: A result that arrives without its call

    /// **The defect the renders found and the code did not.** A `.toolResult` stands alone
    /// whenever its call is not in the feed — one page boundary is enough — and read through
    /// the command slot it rendered as `Read`, `1  import Foundation`, `68 KB more`: the first
    /// line of a 64 KB file, captioned with a byte count that made it look deliberate.
    func testAResultWithoutItsCallSuppliesTheOutputPanelItself() {
        let orphan = TimelineFixtures.readResult

        XCTAssertEqual(
            TimelineStyle.outputBody(of: orphan, result: nil)?.id, orphan.id,
            "a result is output wherever it lands, not a command line"
        )
        XCTAssertEqual(
            TimelineStyle.outputBody(of: TimelineFixtures.readCall,
                                     result: TimelineFixtures.readResult)?.id,
            TimelineFixtures.readResult.id
        )
        XCTAssertNil(
            TimelineStyle.outputBody(of: TimelineFixtures.unansweredCall, result: nil),
            "a call still running has no output, and must not borrow its own input for one"
        )
    }

    /// The same rule, in the vocabulary VoiceOver hears: an orphaned result must be announced
    /// as output and must carry more than its first line.
    func testVoiceOverHearsAnOrphanedResultAsOutputRatherThanAsACommand() {
        let spoken = TimelineStyle.accessibilityLabel(for: TimelineFixtures.readResult)

        XCTAssertTrue(spoken.hasPrefix("Read. Output."), spoken)
        XCTAssertTrue(
            spoken.contains("Hands out one page of a transcript"),
            "the body, not just the line the body happens to open on: \(spoken)"
        )
        XCTAssertTrue(spoken.contains("68 KB not shown"), spoken)
    }

    // MARK: The line under a tool's name

    /// The Mac's own summary when it sent one — that field exists because a tool call's text is
    /// JSON — and otherwise the first line that carries anything. A pretty-printed object opens
    /// on a bare `{`, and a card whose only content is `{` says nothing at all.
    func testACommandLineSkipsTheBareDelimiterAPrettyPrintedInputOpensOn() {
        XCTAssertEqual(
            TimelineStyle.commandLine(for: TimelineFixtures.bashCall),
            "rg -n 'hasNewer|hasMore' Sources/FleetKit Sources/FlightDeckMobile"
        )
        XCTAssertEqual(
            TimelineStyle.commandLine(for: TimelineFixtures.callWithoutSummary),
            "\"pattern\": \"TimelineFeed\",",
            "no summary, so the first line with content in it — never the `{` above it"
        )
    }

    /// An input the byte cap cut down to nothing, and a record with no body at all. Neither is
    /// a line, and both must resolve to the empty string rather than to whitespace that renders
    /// as a bar of grey.
    func testACommandLineWithNothingInItIsEmptyRatherThanBlank() {
        let empty = TimelineItem(
            id: "1#0", kind: .toolCall, status: .complete,
            body: .init(text: "{\n}", tool: "Bash", callID: "c1")
        )
        XCTAssertEqual(
            TimelineStyle.commandLine(for: empty), "",
            "`{}` pretty-prints to two delimiters and no content — a card reading `}` "
                + "is noise with a border around it"
        )

        let nothing = TimelineItem(
            id: "2#0", kind: .toolCall, status: .complete,
            body: .init(text: "   \n\n", tool: "Bash", callID: "c2")
        )
        XCTAssertEqual(TimelineStyle.commandLine(for: nothing), "")
    }

    // MARK: Who said it

    /// The fleet's own agent name heads its prose, because "Claude" reads as a participant and
    /// "Assistant" reads as a category. **An agent this build has never heard of is still
    /// named**, for the same reason `WireSession.agent` is a `String` at all: the Mac may be
    /// newer, and the honest answer to a name we do not know is the name.
    func testAnAgentThisBuildHasNeverHeardOfIsNamedRatherThanCalledAssistant() {
        XCTAssertEqual(TimelineStyle.agentName("claude"), "Claude")
        XCTAssertEqual(TimelineStyle.agentName("codex"), "Codex")
        XCTAssertEqual(TimelineStyle.agentName("gemini"), "Gemini")
        XCTAssertNil(TimelineStyle.agentName(nil))
        XCTAssertNil(TimelineStyle.agentName(""), "an empty wire field is not a name")

        XCTAssertEqual(
            TimelineStyle.heading(for: TimelineFixtures.assistantAnswer, agent: "claude"),
            "Claude"
        )
        XCTAssertEqual(
            TimelineStyle.heading(for: TimelineFixtures.assistantAnswer, agent: nil),
            "Assistant",
            "a session the fleet no longer lists still has to head its own rows"
        )
    }

    /// Every kind gets a word and a symbol, **including the one this build cannot name**. A
    /// kind from a newer Mac renders as `Unrecognized` with the same `circle.dotted` the fleet
    /// list uses for a status it does not know, never as a blank row.
    func testEveryKindIncludingAnUnknownOneRendersAsSomething() {
        let headings = TimelineFixtures.conversation.map { TimelineStyle.heading(for: $0) }
        XCTAssertFalse(headings.contains(""), "\(headings)")

        XCTAssertEqual(TimelineStyle.heading(for: TimelineFixtures.unknown), "Unrecognized")
        XCTAssertEqual(TimelineStyle.symbol(for: TimelineFixtures.unknown), "circle.dotted")
        XCTAssertEqual(TimelineStyle.heading(for: TimelineFixtures.prompt), "Waiting for you")
    }

    // MARK: A message from another session

    private func peerMessage(_ text: String, sender: String? = "The Plan Part 3") -> TimelineItem {
        TimelineItem(
            id: "9#0", kind: .systemNotice, status: .complete,
            body: .init(text: text, tool: "cross-session-message", sender: sender)
        )
    }

    /// Headed by the session that sent it. "Cross session message" answers a question the
    /// reader never had; which session is talking is the one they do.
    func testAPeerMessageIsHeadedBySenderAndFallsBackToAWord() {
        XCTAssertEqual(TimelineStyle.heading(for: peerMessage("hi")), "The Plan Part 3")
        XCTAssertEqual(TimelineStyle.heading(for: peerMessage("hi", sender: nil)),
                       "Another session")
        XCTAssertNotEqual(TimelineStyle.symbol(for: peerMessage("hi")), "gearshape.fill",
                          "an agent talking is not the harness")
    }

    /// A peer's message is an agent's prose — numbered plans, code spans, headings — and read
    /// as machine text it was a wall of backticks and asterisks, cut at fourteen lines.
    func testAPeerMessageIsProseLikeAnAnswer() {
        let short = peerMessage("1. Task 14 (`relational`)\n2. Then rebase")
        XCTAssertTrue(TimelineStyle.rendersMarkdown(short))
        XCTAssertNil(TimelineStyle.proseLineLimit(for: peerMessage(
            Array(repeating: "line", count: 40).joined(separator: "\n"))))
        XCTAssertFalse(TimelineStyle.opensDetail(short), "prose expands in place")
        XCTAssertEqual(TimelineStyle.rowCopyText(for: short), short.body.text)
    }

    /// Every other notice stays machine text: a `bash-stdout` must not be reflowed.
    func testOtherNoticesAreStillMachineText() {
        let stdout = TimelineItem(
            id: "9#1", kind: .systemNotice, status: .complete,
            body: .init(text: "**not bold**", tool: "bash-stdout", sender: "x")
        )
        XCTAssertFalse(TimelineStyle.rendersMarkdown(stdout))
        XCTAssertEqual(TimelineStyle.heading(for: stdout), "Bash stdout")
    }

    /// A tool is whatever the agent was given, so most of them are names this build has never
    /// seen. They get the generic symbol; they do not get an empty one.
    func testAToolThisBuildDoesNotKnowStillGetsASymbol() {
        XCTAssertEqual(TimelineStyle.symbol(forTool: "Bash"), "terminal.fill")
        XCTAssertEqual(TimelineStyle.symbol(forTool: "Read"), "doc.text.fill")
        XCTAssertEqual(
            TimelineStyle.symbol(forTool: "mcp__linear__create_issue"),
            "wrench.and.screwdriver.fill"
        )
        XCTAssertEqual(TimelineStyle.symbol(forTool: nil), "wrench.and.screwdriver.fill")
    }

    // MARK: When it happened

    /// **Both spellings, because the two agents write different ones.** Claude writes
    /// fractional seconds and codex does not, and `ISO8601DateFormatter` fails whichever it was
    /// not configured for rather than coping — so a screen built against one agent's transcript
    /// shows no times at all for the other's.
    func testBothAgentsTimestampsParseAndAnythingElseRendersAsNothing() {
        XCTAssertNotNil(
            TimelineStyle.time("2026-08-23T09:14:02.117Z"), "claude writes fractional seconds"
        )
        XCTAssertNotNil(
            TimelineStyle.time("2026-08-23T09:14:02Z"), "codex writes whole ones"
        )
        XCTAssertNil(TimelineStyle.time(nil))
        XCTAssertNil(
            TimelineStyle.time("yesterday afternoon"),
            "no time at all beats a formatted lie about a date nobody has"
        )
        XCTAssertNotNil(TimelineStyle.timestamp("2026-08-23T09:14:02Z"))
        XCTAssertNil(TimelineStyle.timestamp("yesterday afternoon"))
    }

    /// **The defect this memo fixes.** `time(_:)` runs on every render of a row's header, and a
    /// re-render that leaves the raw string untouched used to reparse the same ISO-8601 text and
    /// reformat the same `Date` every time — hundreds of rows, dozens of times a minute. A second
    /// ask for the same raw string must return the identical formatted string and must not touch
    /// the formatters again; `dateMemoComputeCount` is the miss counter, the same shape as
    /// `TimelineLinkCache.computeCount`/`TimelineSegmentCache.computeCount`.
    /// **A raw string this file and its fixtures never otherwise use.** `dateMemoComputeCount`
    /// is process-wide (the memo lives on `TimelineStyle`, not on an instance this test owns),
    /// so a raw string any other test also asks for would make the `before` baseline here a lie
    /// — the memo may already hold it. `2031-…` is not a date anything else in this file or
    /// `TimelineFixtures` writes.
    func testASecondCallWithTheSameRawStringIsAMemoHit() {
        let before = TimelineStyle.dateMemoComputeCount
        let raw = "2031-01-02T03:04:05.678Z"
        let first = TimelineStyle.time(raw)
        let second = TimelineStyle.time(raw)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            TimelineStyle.dateMemoComputeCount, before + 1,
            "the second ask for the same raw string should hit the memo, not reparse"
        )
    }

    /// `timestamp(_:)` shares the same memo entry as `time(_:)` — asking both for one raw string
    /// costs one parse, not two, because the full instant and the clock face come off the same
    /// `Date`. A raw string of its own, for the same reason as the test above.
    func testTimeAndTimestampShareOneMemoEntryForTheSameRawString() {
        let before = TimelineStyle.dateMemoComputeCount
        let raw = "2031-06-07T08:09:10Z"
        _ = TimelineStyle.time(raw)
        _ = TimelineStyle.timestamp(raw)
        XCTAssertEqual(
            TimelineStyle.dateMemoComputeCount, before + 1,
            "time and timestamp should share the one memo entry for a raw string, not keep two"
        )
    }

    // MARK: What the Mac cut

    /// `truncatedBytes > 0` means the body on screen is a fragment. A whole body must produce
    /// no chip at all — a row that said "0 bytes more" under every result would train a reader
    /// to stop reading the one place this screen tells them something is missing.
    func testTruncationIsSaidWithItsSizeAndOnlyWhenSomethingWasActuallyCut() {
        XCTAssertNil(TimelineStyle.truncationChip(0))
        XCTAssertNil(TimelineStyle.truncationChip(-1))
        XCTAssertEqual(TimelineStyle.truncationChip(68_412), "68 KB more")
    }

    /// Both numbers, because "truncated" on its own does not tell a reader whether they are
    /// missing a line or a megabyte — which is the difference between reading on and walking
    /// to the Mac.
    func testTheTruncationNoticeSaysWhatIsShownAndWhatTheWholeThingWas() {
        let notice = TimelineStyle.truncationNotice(shown: 584, dropped: 68_412)

        XCTAssertTrue(notice.contains("584 bytes"), notice)
        XCTAssertTrue(notice.contains("69 KB"), "the whole size, not the shortfall: \(notice)")
        XCTAssertTrue(notice.contains("on your Mac"), notice)
    }

    // MARK: What VoiceOver hears

    /// A `.toolResult` can be 64 KB. A label that long is a VoiceOver user trapped on one row
    /// of a list that may be hundreds long, with no way to reach the next one.
    func testAVoiceOverLabelIsCappedSoOneRowIsNotAQuarterHourOfSpeech() {
        let huge = TimelineItem(
            id: "1#0", kind: .assistantText, status: .complete,
            body: .init(text: String(repeating: "reticulating splines. ", count: 3_000))
        )

        let spoken = TimelineStyle.accessibilityLabel(for: huge)
        XCTAssertLessThan(spoken.count, 400, "a row is a stop, not a chapter")
        XCTAssertTrue(spoken.hasSuffix("…"), spoken)
    }

    /// Newlines are flattened, or VoiceOver pauses on every line of a stack trace as though it
    /// were a separate thought.
    func testAMultiLineBodyIsSpokenAsOneSentence() {
        XCTAssertEqual(TimelineStyle.clipped("one\ntwo\nthree"), "one two three")
    }

    /// A failing call is announced as failing. The chip is a colour and a word on screen and
    /// neither survives into a label built from the parts around it.
    func testAFailureIsSpokenAndNotOnlyTinted() {
        let spoken = TimelineStyle.accessibilityLabel(
            for: TimelineFixtures.failingCall, result: TimelineFixtures.failingResult
        )

        XCTAssertTrue(spoken.contains("Failed"), spoken)
        XCTAssertTrue(spoken.contains("./scripts/test-ios.sh"), spoken)
    }
}
