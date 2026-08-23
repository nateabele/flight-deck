import FleetKit
import XCTest
@testable import FlightDeck

/// Pager plus mapper plus budget. The three things this adds on top of Task 5 are the ones a
/// phone on a cellular link depends on: a per-item cap, a per-page budget, and the guarantee
/// that neither of them can ever produce an empty page while a record remains.
///
/// **Every cursor is asserted, not just the items.** `start`, `end`, `hasMore` and `reset` are
/// the client's entire pagination state: a page carrying exactly the right rows with `start`
/// one record too low re-serves what the client already has on every scroll, and a page that
/// sheds records to the budget while reporting `hasMore: false` is a conversation with a hole
/// in it. Neither shows up in a test that reads `items` alone.
///
/// Sizes here are computed from `TimelineLimits`, never spelled as literals, and the fixture
/// records are deliberately unequal in length so an offset that is off by a newline cannot
/// land on a plausible multiple.
final class TimelineReaderTests: XCTestCase {
    private let session = UUID()
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    // MARK: - Fixtures

    private func writeRaw(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("t.jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func write(_ lines: [String]) throws -> URL {
        try writeRaw(lines.joined(separator: "\n") + "\n")
    }

    /// The byte offset every line in `write(_:)` lands at, plus the file's size on the end —
    /// computed rather than written out, because these fixtures are JSON and their lengths are
    /// nobody's idea of a readable constant.
    private func offsets(_ lines: [String]) -> [Int] {
        var found: [Int] = []
        var offset = 0
        for line in lines {
            found.append(offset)
            offset += line.utf8.count + 1
        }
        return found + [offset]
    }

    private func userTurn(_ text: String) -> String {
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"\#(text)"}}"#
    }

    private func assistantText(_ texts: [String]) -> String {
        let blocks = texts.map { #"{"type":"text","text":"\#($0)"}"# }.joined(separator: ",")
        return #"{"type":"assistant","isSidechain":false,"message":"#
            + #"{"role":"assistant","content":[\#(blocks)]}}"#
    }

    /// A codex `custom_tool_call`, whose `input` becomes `text` verbatim and whose first line
    /// becomes `summary`. The one fixture shape that lets a test set both halves of a body's
    /// size independently.
    private func codexToolCall(callID: String, input: String) -> String {
        let escaped = input.replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","#
            + #""call_id":"\#(callID)","input":"\#(escaped)"}}"#
    }

    /// A body of an exact size that still says which record it is. Under `maxItemBytes`, so
    /// the per-item cap cannot quietly change what the page budget is measuring.
    private func padded(_ mark: String, to bytes: Int = TimelineLimits.maxPageBytes / 2 - 100)
        -> String {
        mark + String(repeating: "y", count: bytes - mark.utf8.count)
    }

    private func read(
        _ url: URL, _ anchor: TimelineAnchor,
        limit: Int = TimelineLimits.defaultLimit, agent: AgentID = .claude
    ) throws -> TimelinePage {
        try TimelineReader.page(
            session: session, agent: agent, url: url, anchor: anchor, limit: limit
        ).get()
    }

    private func marks(_ page: TimelinePage) -> [String] {
        page.items.map { String($0.body.text.prefix(6)) }
    }

    // MARK: - Items, order and cursors

    func testAPageCarriesTheMappedItemsInFileOrderBetweenTheCursorsThatSpanThem() throws {
        let lines = [userTurn("one"), userTurn("two"), userTurn("three")]
        let page = try read(try write(lines), .latest, limit: 2)
        let at = offsets(lines)
        XCTAssertEqual(page.items.map(\.body.text), ["two", "three"],
                       "oldest first, even though the anchor asked backwards")
        XCTAssertEqual(page.items.map(\.id), ["\(at[1])#0", "\(at[2])#0"])
        XCTAssertEqual(page.session, session)
        XCTAssertEqual(page.start, at[1], "the next page up starts where this page's first "
                       + "record does, not at the file's first record")
        XCTAssertEqual(page.end, at[3], "one past the last line, which is the file's size here")
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.reset)
    }

    /// One record can carry several items, so `limit` counts records and `items.count` can
    /// exceed it. Asserted because the opposite reading — limit as an item count — produces a
    /// pager call with the wrong argument and pages that shrink unpredictably.
    func testTheLimitCountsRecordsNotItems() throws {
        let lines = [assistantText(["a", "b", "c"])]
        let page = try read(try write(lines), .latest, limit: 1)
        XCTAssertEqual(page.items.map(\.body.text), ["a", "b", "c"])
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, offsets(lines)[1])
        XCTAssertFalse(page.hasMore, "one record is the whole file")
    }

    /// **`start` is the pager's, carried verbatim.** A blank line is a boundary that carries
    /// no record, so a page whose oldest boundary is one begins a byte before its first item.
    /// Recomputing `start` from `items.first` — the obvious simplification — moves the
    /// client's cursor past that byte, and the next `.before(start)` never returns it.
    ///
    /// Note what this test does NOT catch: the items and their ids are identical either way.
    /// Only `start` moves.
    func testTheStartCursorIsThePagersEvenWhenItNamesABlankLine() throws {
        let lines = [userTurn("one"), "", userTurn("two"), userTurn("three")]
        let at = offsets(lines)
        let page = try read(try write(lines), .latest, limit: 3)
        XCTAssertEqual(page.items.map(\.body.text), ["two", "three"])
        XCTAssertEqual(page.start, at[1], "the blank line's own offset")
        XCTAssertEqual(page.items.first?.id, "\(at[2])#0",
                       "the first record begins one byte after `start`, and this is the byte "
                       + "that recomputing the cursor from the items would lose")
        XCTAssertEqual(page.end, at[4])
        XCTAssertTrue(page.hasMore)
    }

    // MARK: - The per-item cap

    func testAnItemLongerThanTheCapIsTruncatedAndSaysSo() throws {
        let long = String(repeating: "x", count: TimelineLimits.maxItemBytes + 500)
        let item = try XCTUnwrap(try read(try write([userTurn(long)]), .latest).items.first)
        XCTAssertEqual(item.body.text.utf8.count, TimelineLimits.maxItemBytes)
        XCTAssertEqual(item.body.truncatedBytes, 500,
                       "a client that cannot say how much it is missing will present a "
                       + "partial file read as a whole one")
    }

    /// The cut lands on a `Character`, not on a byte. `maxItemBytes` is divisible by 4, so an
    /// emoji fixture would cut cleanly by either rule and prove nothing; a three-byte glyph
    /// leaves one byte spare at the cap and puts a scalar across it.
    func testTruncationCutsOnACharacterBoundaryAndNeverOnAScalar() throws {
        let glyphs = TimelineLimits.maxItemBytes / 3 + 100
        let long = String(repeating: "\u{3042}", count: glyphs)  // 3 bytes each
        let kept = (TimelineLimits.maxItemBytes / 3) * 3
        let item = try XCTUnwrap(try read(try write([userTurn(long)]), .latest).items.first)
        XCTAssertEqual(item.body.text.utf8.count, kept,
                       "one byte under the cap, because the glyph that would straddle it is "
                       + "dropped whole")
        XCTAssertFalse(item.body.text.contains("\u{FFFD}"),
                       "a body ending in a replacement character reads as corrupted output "
                       + "rather than as a truncation")
        XCTAssertEqual(item.body.truncatedBytes, glyphs * 3 - kept)
    }

    // MARK: - The page budget

    /// **Progress.** One record whose items outweigh the whole page budget must still come
    /// back, or backwards paging stalls on it forever with no way past.
    ///
    /// It takes a MULTI-ITEM record to get here: `maxItemBytes` is half of `maxPageBytes`, so
    /// a single item can never exceed the budget on its own — three 64 KB text blocks in one
    /// assistant record can, and that is an ordinary long reply.
    func testARecordHeavierThanTheWholeBudgetStillMakesAPage() throws {
        let block = String(repeating: "x", count: TimelineLimits.maxItemBytes)
        let lines = [userTurn("first"), assistantText([block, block, block])]
        let at = offsets(lines)
        let url = try write(lines)
        let page = try read(url, .latest)
        XCTAssertEqual(page.items.count, 3, "the budget stops AFTER one record, never before")
        XCTAssertEqual(page.items.map(\.body.truncatedBytes), [0, 0, 0])
        XCTAssertEqual(page.start, at[1])
        XCTAssertEqual(page.end, at[2])
        XCTAssertTrue(page.hasMore, "the pager could reach the top of this file in one window "
                      + "— the only reason there is more is what the budget dropped")
        XCTAssertEqual(try read(url, .before(page.start)).items.map(\.body.text), ["first"],
                       "and what it dropped is exactly what the next page up returns")
    }

    /// Paging backwards, the budget drops the OLDEST records — the client is scrolling up and
    /// wants what is nearest its cursor. `start` moves with them, so the next `.before(start)`
    /// picks up exactly what was dropped.
    func testTheBudgetTrimsFromTheOldestEndWhenPagingBackwards() throws {
        let lines = [padded("oldest"), padded("middle"), padded("newest")].map(userTurn)
        let at = offsets(lines)
        let url = try write(lines)
        let page = try read(url, .latest)
        XCTAssertEqual(marks(page), ["middle", "newest"])
        XCTAssertEqual(page.start, at[1], "the cursor moves with what was dropped")
        XCTAssertEqual(page.end, at[3])
        XCTAssertTrue(page.hasMore)

        let next = try read(url, .before(page.start))
        XCTAssertEqual(marks(next), ["oldest"],
                       "what the budget dropped is exactly what the next page up returns")
        XCTAssertEqual(next.end, at[1])
        XCTAssertFalse(next.hasMore, "and above it is the top of the transcript")
    }

    /// Paging forwards, it trims from the newest end instead, and `end` moves back with them.
    func testTheBudgetTrimsFromTheNewestEndWhenPagingForwards() throws {
        let lines = [padded("oldest"), padded("middle"), padded("newest")].map(userTurn)
        let at = offsets(lines)
        let url = try write(lines)
        let page = try read(url, .after(0))
        XCTAssertEqual(marks(page), ["oldest", "middle"])
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, at[2], "one past the last record it kept, not one past the "
                       + "last record it read")
        XCTAssertTrue(page.hasMore)

        let next = try read(url, .after(page.end))
        XCTAssertEqual(marks(next), ["newest"])
        XCTAssertEqual(next.start, at[2])
        XCTAssertEqual(next.end, at[3])
    }

    /// The budget counts `summary` as well as `text`. Both are output the source record's
    /// size decides, and only `text` is bounded by `capped` — a preview escapes the per-item
    /// cap entirely, and 200 of them are 40 KB of a 128 KB page.
    ///
    /// Sized so the two readings differ by exactly one record: the bodies alone come to the
    /// budget precisely, and the two previews are what push it over.
    func testTheBudgetCountsThePreviewAndNotOnlyTheBody() throws {
        let head = String(repeating: "a", count: ToolInputSummary.maxSummaryBytes)
        let body = TimelineLimits.maxPageBytes / 2 - head.utf8.count - 1
        let input = head + "\n" + String(repeating: "b", count: body)
        let lines = [
            codexToolCall(callID: "c1", input: input),
            codexToolCall(callID: "c2", input: input),
        ]
        let at = offsets(lines)
        let page = try read(try write(lines), .latest, agent: .codex)
        XCTAssertEqual(page.items.map(\.body.text.utf8.count), [TimelineLimits.maxPageBytes / 2])
        XCTAssertEqual(page.items.compactMap(\.body.summary), [head],
                       "and the preview is the part the per-item cap never sees")
        XCTAssertEqual(page.items.map(\.body.callID), ["c2"], "the newest survives")
        XCTAssertEqual(page.items.map(\.body.truncatedBytes), [0], "nothing was over the cap")
        XCTAssertEqual(page.start, at[1])
        XCTAssertTrue(page.hasMore)
    }

    // MARK: - Limits, resets and failures

    /// Clamped rather than refused: a limit is a hint about what a screen wants, and refusing
    /// an over-eager client turns a mildly greedy request into a broken one.
    func testALimitAboveTheMaximumIsClampedToTheMaximum() throws {
        let lines = (0..<(TimelineLimits.maxLimit + 5)).map { userTurn("m\($0)") }
        let page = try read(try write(lines), .latest, limit: 10_000)
        XCTAssertEqual(page.items.count, TimelineLimits.maxLimit)
        XCTAssertEqual(page.start, offsets(lines)[5])
        XCTAssertTrue(page.hasMore)
    }

    /// A limit off the wire has no floor, and zero or less is a page that cannot make
    /// progress: no records, and a cursor that has not moved.
    ///
    /// Defence in depth, and said plainly because it changes what a mutation proves: the
    /// pager holds the same floor — it is where a negative traps — so this reddens only when
    /// BOTH clamps go. It is here because neither layer is entitled to assume the other one
    /// still clamps.
    func testALimitBelowOneStillMakesAPageOfOneRecord() throws {
        let lines = [userTurn("one"), userTurn("two")]
        let page = try read(try write(lines), .latest, limit: -1)
        XCTAssertEqual(page.items.map(\.body.text), ["two"])
        XCTAssertEqual(page.start, offsets(lines)[1])
        XCTAssertTrue(page.hasMore)
    }

    func testAResetPageCarriesNoItemsAndSaysReset() throws {
        let lines = [userTurn("one")]
        let page = try read(try write(lines), .after(9_999))
        XCTAssertTrue(page.reset)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore, "the client's move is to re-fetch `.latest`, not to page "
                       + "from a cursor already declared meaningless")
        XCTAssertEqual(page.start, offsets(lines)[1])
        XCTAssertEqual(page.end, offsets(lines)[1])
    }

    /// The ordinary poll: a screen that is already open asks what has been appended since its
    /// cursor, and nothing has. An empty page at the same cursor, not a failure and not a
    /// reset — and `hasMore` false, or the client re-issues this request on every poll.
    func testAForwardPollWithNothingAppendedIsAnEmptyPageAtTheSameCursor() throws {
        let lines = [userTurn("one")]
        let end = offsets(lines)[1]
        let page = try read(try write(lines), .after(end))
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.start, end)
        XCTAssertEqual(page.end, end)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.reset)
    }

    func testAMissingTranscriptIsAFailureNotAnEmptyPage() {
        let result = TimelineReader.page(
            session: session, agent: .claude,
            url: directory.appendingPathComponent("nope.jsonl"),
            anchor: .latest, limit: TimelineLimits.defaultLimit
        )
        XCTAssertEqual(result, .failure(.unreadable))
    }

    /// A file with no line boundary in it cannot be paged, and saying so is the whole point:
    /// the alternative answer — no lines, cursors at zero, `hasMore` and `reset` false — is
    /// byte-identical to a genuinely empty transcript, so a phone renders "this conversation
    /// is empty" over history it simply could not reach, with nothing to retry and nothing to
    /// log. `unreadable` is showable and retryable; see `TimelineReadFailure`.
    func testATranscriptWithNoLineBoundaryIsAFailureRatherThanAnEmptyConversation() throws {
        let url = try writeRaw(userTurn("mid-write, no newline yet"))
        XCTAssertEqual(
            TimelineReader.page(session: session, agent: .claude, url: url,
                                anchor: .latest, limit: TimelineLimits.defaultLimit),
            .failure(.unreadable)
        )
    }

    /// And the other side of that decision, which is what keeps it from swallowing a real
    /// state: a file that exists and holds nothing IS an empty conversation, and says so.
    func testAnEmptyTranscriptIsAnEmptyPageRatherThanAFailure() throws {
        let page = try read(try writeRaw(""), .latest)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, 0)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.reset)
    }

    /// The agent chooses the mapper and nothing else does. A codex rollout read as claude
    /// yields nothing, which is what a mis-routed tab would look like — so this is the test
    /// that catches the routing being wrong rather than the mapping.
    func testTheAgentSelectsTheMapper() throws {
        let lines = [#"{"type":"event_msg","payload":{"type":"agent_message","message":"ok"}}"#]
        let url = try write(lines)
        let asCodex = try read(url, .latest, agent: .codex)
        XCTAssertEqual(asCodex.items.map(\.body.text), ["ok"])
        XCTAssertEqual(asCodex.items.map(\.kind), [.assistantText])

        let asClaude = try read(url, .latest)
        XCTAssertTrue(asClaude.items.isEmpty, "claude's mapper has no row for it")
        XCTAssertEqual(asClaude.end, offsets(lines)[1],
                       "and the cursor still spans the records it read, so a client is not "
                       + "pinned in front of records it can never map")
    }
}
