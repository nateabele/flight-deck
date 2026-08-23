import FleetKit
import XCTest
@testable import FlightDeck

/// Byte-window paging over an append-only JSONL file. No agents, no JSON — just "which lines,
/// and where were they".
///
/// Four properties here are load-bearing and each is a bug someone would otherwise ship:
/// a trailing partial line must never be consumed, a page must always make progress, cursors
/// must round-trip exactly, and a cursor past the end of the file must announce a reset
/// rather than silently serving from wherever the file happens to be now.
///
/// **Offsets are asserted, not just line contents.** The arithmetic is the entire product
/// here: a pager that returns the right lines with every offset one byte off looks perfect in
/// a test that only reads `.text`, and downstream turns into a phone that skips or repeats a
/// message. `varied` exists for the same reason — evenly sized records let an off-by-one hide
/// behind a multiple of the record size.
final class TranscriptPagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    @discardableResult
    private func write(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("t.jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func append(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }

    /// Every line is the same length, so an expected offset is arithmetic a reader can check.
    private func numbered(_ count: Int) -> String {
        (0..<count).map { String(format: "line%03d", $0) }.joined(separator: "\n") + "\n"
    }

    /// Deliberately ragged: 1, 4, 2, 9, 1, 6 and 3 bytes of text. Every offset below is
    /// therefore a different number, and an implementation that is off by one — or that
    /// forgets a line's terminator — cannot land on a plausible-looking multiple.
    private let varied = "a\nbbbb\ncc\nddddddddd\ne\nffffff\nggg\n"
    /// The offsets `varied`'s lines occupy: 0, 2, 7, 10, 20, 22, 29, ending at 33.
    private let variedLines = [
        SourceLine(offset: 0, text: "a"),
        SourceLine(offset: 2, text: "bbbb"),
        SourceLine(offset: 7, text: "cc"),
        SourceLine(offset: 10, text: "ddddddddd"),
        SourceLine(offset: 20, text: "e"),
        SourceLine(offset: 22, text: "ffffff"),
        SourceLine(offset: 29, text: "ggg"),
    ]

    func testLatestReturnsTheNewestLines() throws {
        let url = try write(numbered(10))                       // 8 bytes per line
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 3))
        XCTAssertEqual(page.lines.map(\.text), ["line007", "line008", "line009"])
        XCTAssertEqual(page.lines.map(\.offset), [56, 64, 72])
        XCTAssertEqual(page.start, 56, "7 lines * 8 bytes")
        XCTAssertEqual(page.end, 80)
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.reset)
    }

    /// The whole page, offsets included, against a file whose records are all different
    /// lengths. Everything else here checks one property; this checks the arithmetic itself.
    func testEveryLineCarriesItsOwnByteOffset() throws {
        let url = try write(varied)
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines, variedLines)
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, 33, "the file is 33 bytes and every one of them is accounted for")
        XCTAssertFalse(page.hasMore)
    }

    /// The cursor contract: `start` fed back as `.before` is the next page up, with no gap and
    /// no overlap. This is the property every scroll depends on.
    func testStartFedBackAsBeforeIsTheNextPageUpExactly() throws {
        let url = try write(numbered(10))
        let first = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 4))
        let second = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .before(first.start), limit: 4)
        )
        XCTAssertEqual(second.lines.map(\.text), ["line002", "line003", "line004", "line005"])
        XCTAssertEqual(second.lines.map(\.offset), [16, 24, 32, 40])
        XCTAssertEqual(second.end, first.start, "no gap and no overlap between pages")
    }

    /// Scrolling a whole conversation to its top, two records at a time, through a window
    /// smaller than most of its pages. Every line arrives exactly once, in file order, with
    /// its real offset — which is the only end-to-end statement of what this type is for.
    func testPagingBackwardsToTheTopVisitsEveryLineExactlyOnce() throws {
        let url = try write(varied)
        var collected: [SourceLine] = []
        var anchor = TimelineAnchor.latest
        var previousStart: Int?
        for _ in 0..<10 {
            let page = try XCTUnwrap(
                TranscriptPager.page(url: url, anchor: anchor, limit: 2, window: 8)
            )
            if let previousStart {
                XCTAssertEqual(page.end, previousStart, "no gap and no overlap between pages")
            }
            collected.insert(contentsOf: page.lines, at: 0)
            previousStart = page.start
            guard page.hasMore else { break }
            anchor = .before(page.start)
        }
        XCTAssertEqual(collected, variedLines)
        XCTAssertEqual(previousStart, 0, "the walk ended at the top of the file")
    }

    func testPagingUpToTheTopReportsNoMore() throws {
        let url = try write(numbered(3))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines.count, 3)
        XCTAssertEqual(page.start, 0)
        XCTAssertFalse(page.hasMore, "there is nothing above offset 0")
    }

    /// **A window boundary lands mid-line far more often than not.** The record the window
    /// cut through starts before `start`, so it belongs to the next page up — returning it
    /// here would hand a client a fragment carrying an offset that says it is whole.
    func testAWindowThatCutsALineDoesNotReturnTheFragment() throws {
        let url = try write(varied)
        let page = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .latest, limit: 2, window: 8)
        )
        XCTAssertEqual(page.lines, [variedLines[5], variedLines[6]])
        XCTAssertEqual(page.start, 22, "the 8-byte window cut through 'ddddddddd'; it is not ours")
        XCTAssertEqual(page.end, 33)
        XCTAssertTrue(page.hasMore)
    }

    func testAfterReturnsWhatWasAppendedSince() throws {
        let url = try write(numbered(4))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(16), limit: 10))
        XCTAssertEqual(page.lines.map(\.text), ["line002", "line003"])
        XCTAssertEqual(page.lines.map(\.offset), [16, 24])
        XCTAssertEqual(page.start, 16)
        XCTAssertEqual(page.end, 32)
    }

    func testAfterZeroReadsFromTheTopOfTheFile() throws {
        let url = try write(varied)
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(0), limit: 3))
        XCTAssertEqual(page.lines, Array(variedLines.prefix(3)))
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, 10)
        XCTAssertTrue(page.hasMore, "four records are still ahead of the cursor")
    }

    func testBeforeZeroIsTheTopOfTheFileRatherThanAReset() throws {
        let url = try write(varied)
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .before(0), limit: 3))
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, 0)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.reset)
    }

    /// Forwards, a window ending mid-line stops at the last boundary inside it — so `end` is
    /// short of the window, and the next `.after(end)` picks the record up whole.
    func testAForwardWindowEndingMidLineStopsAtTheBoundary() throws {
        let url = try write(varied)
        let first = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .after(0), limit: 10, window: 8)
        )
        XCTAssertEqual(first.lines, Array(variedLines.prefix(2)))
        XCTAssertEqual(first.end, 7, "8 bytes were read; the 8th is inside 'cc'")
        XCTAssertTrue(first.hasMore)

        let second = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .after(first.end), limit: 10, window: 8)
        )
        XCTAssertEqual(second.lines, [variedLines[2]], "'cc' arrives whole, once")
        XCTAssertEqual(second.start, 7)
        XCTAssertEqual(second.end, 10)
    }

    func testAfterTheEndReturnsNothingRatherThanRereading() throws {
        let url = try write(numbered(4))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(32), limit: 10))
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertEqual(page.start, 32)
        XCTAssertEqual(page.end, 32)
        XCTAssertFalse(page.reset, "at the end is not the same as past the end")
    }

    /// The ordinary case, not the edge case: the writer appends between two requests, and the
    /// cursor from the first picks up exactly what arrived and nothing else.
    func testAFileThatGrewBetweenRequestsResumesAtTheCursor() throws {
        let url = try write(varied)
        let first = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(first.end, 33)

        try append("hhhhh\niiii\n", to: url)
        let second = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .after(first.end), limit: 10)
        )
        XCTAssertEqual(second.lines, [
            SourceLine(offset: 33, text: "hhhhh"), SourceLine(offset: 39, text: "iiii"),
        ])
        XCTAssertEqual(second.start, 33)
        XCTAssertEqual(second.end, 44)
        XCTAssertFalse(second.hasMore)
        XCTAssertFalse(second.reset)
    }

    /// **The writer appends while we read.** A read can land mid-write, and consuming a
    /// trailing line that has no newline yet hands a client half a JSON record — which the
    /// mapper drops, permanently, because the cursor has already moved past it. Same rule
    /// `TailReader` documents, for the same reason.
    func testATrailingPartialLineIsNeverConsumed() throws {
        let url = try write(numbered(3) + "line003-partial-no-newline")
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines.map(\.text), ["line000", "line001", "line002"])
        XCTAssertEqual(page.end, 24, "the end is the last newline boundary, not the file size")
    }

    /// And the record that was mid-write arrives whole, at its real offset, once the writer
    /// finishes it — which is the payoff for having withheld it.
    func testAWithheldPartialLineArrivesWholeOnceItIsFinished() throws {
        let url = try write("a\nbbbb\ncc")
        let first = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(first.lines, Array(variedLines.prefix(2)))
        XCTAssertEqual(first.end, 7)

        try append("c\n", to: url)
        let second = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .after(first.end), limit: 10)
        )
        XCTAssertEqual(second.lines, [SourceLine(offset: 7, text: "ccc")])
        XCTAssertEqual(second.end, 11)
    }

    /// A cursor past the end of the file means the transcript was replaced or truncated.
    /// Item ids are byte offsets, so every id a client holds now names a different record —
    /// it must be told to throw them away, not quietly handed a page from the new file.
    /// The file-level analogue of §4's explicit re-snapshot.
    func testACursorPastTheEndAnnouncesAReset() throws {
        let url = try write(numbered(2))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(9_999), limit: 10))
        XCTAssertTrue(page.reset)
        XCTAssertTrue(page.lines.isEmpty)
    }

    func testABeforeCursorPastTheEndAlsoAnnouncesAReset() throws {
        let url = try write(numbered(2))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .before(9_999), limit: 10))
        XCTAssertTrue(page.reset)
    }

    /// The realistic shape of that: a cursor issued against one file, spent against the
    /// shorter file that replaced it at the same path.
    func testACursorIssuedBeforeTheFileWasReplacedAnnouncesAReset() throws {
        let url = try write(varied)
        let first = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(first.end, 33)

        try write("z\n")                                        // same path, new, shorter file
        let second = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .after(first.end), limit: 10)
        )
        XCTAssertTrue(second.reset)
        XCTAssertTrue(second.lines.isEmpty)
        XCTAssertEqual(second.start, 2, "the cursor is answered with where the file now ends")
        XCTAssertEqual(second.end, 2)
        XCTAssertFalse(second.hasMore, "re-fetch .latest; do not page from a dead cursor")
    }

    /// **Progress.** A record longer than one window must still come back, or backwards
    /// paging stalls on it forever with no way past. The scan widens until it has enough
    /// newlines rather than giving up at the first window.
    func testALineLongerThanTheWindowIsStillReturned() throws {
        let long = String(repeating: "x", count: 300)
        let url = try write("short\n" + long + "\n")
        let page = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .latest, limit: 1, window: 64)
        )
        XCTAssertEqual(page.lines.map(\.text), [long])
        XCTAssertEqual(page.start, 6)
        XCTAssertEqual(page.end, 307)
        XCTAssertTrue(page.hasMore)
    }

    /// The same rule forwards, where getting it wrong is worse: the cursor never advances, so
    /// every poll rereads the same bytes and returns nothing, forever.
    func testALineLongerThanTheWindowIsStillReturnedForwards() throws {
        let long = String(repeating: "x", count: 300)
        let url = try write("short\n" + long + "\n")
        let page = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .after(6), limit: 10, window: 64)
        )
        XCTAssertEqual(page.lines, [SourceLine(offset: 6, text: long)])
        XCTAssertEqual(page.end, 307, "the cursor moved past the oversized record")
        XCTAssertFalse(page.hasMore)
    }

    /// The widening is bounded. A file that is one enormous line cannot be paged, and saying
    /// so beats reading it all into memory on a Mac.
    func testTheBackwardScanIsBounded() throws {
        let url = try write(String(repeating: "x", count: 5_000) + "\n")
        let page = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .latest, limit: 1, window: 64, maxScan: 256)
        )
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertFalse(page.hasMore, "nothing further is reachable, so do not invite a retry")
    }

    /// So is the forward one, and it stops inviting retries for the same reason — an
    /// unfinished record says "ask again", a record past the budget says "there is nothing
    /// here for you".
    func testTheForwardScanIsBounded() throws {
        let url = try write("a\n" + String(repeating: "x", count: 5_000) + "\n")
        let page = try XCTUnwrap(TranscriptPager.page(
            url: url, anchor: .after(2), limit: 10, window: 64, maxScan: 256
        ))
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertEqual(page.start, 2)
        XCTAssertEqual(page.end, 2, "the cursor does not move past bytes nobody has seen")
        XCTAssertFalse(page.hasMore)
    }

    /// And so is the search for the last boundary, which is the one scan that runs before any
    /// budget has been spent. A tail with no newline in it is a record still being written;
    /// past the budget it is indistinguishable from a file that is not a transcript at all.
    func testALatestWhoseTailHoldsNoBoundaryWithinTheBudgetIsAnEmptyPage() throws {
        let url = try write("short\n" + String(repeating: "x", count: 5_000))
        let page = try XCTUnwrap(TranscriptPager.page(
            url: url, anchor: .latest, limit: 10, window: 64, maxScan: 256
        ))
        XCTAssertTrue(page.lines.isEmpty, "the partial tail is never returned as a whole line")
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.reset)
        // Every offset this type hands out is a line boundary, including the ones it hands
        // out when it is giving up: a `start`/`end` in the middle of a record would come back
        // as an anchor, and become an item id, naming a position no record ever began at.
        XCTAssertEqual(page.start, 0)
        XCTAssertEqual(page.end, 0, "not 5006 — the file size is not a boundary")
    }

    /// A blank line carries no record, but its byte still moves every offset after it.
    func testABlankLineCarriesNoRecordAndStillCountsItsByte() throws {
        let url = try write("aa\n\nbbb\n")
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines, [
            SourceLine(offset: 0, text: "aa"), SourceLine(offset: 4, text: "bbb"),
        ])
        XCTAssertEqual(page.end, 8)
    }

    /// This measures bytes and does not edit content: a stray `\r` is one byte of the line
    /// and stays in the text, exactly as `TailReader` leaves it. JSON treats it as
    /// whitespace, so the mapper never notices — while stripping it here without adjusting
    /// the arithmetic would shift every offset in the file.
    func testACarriageReturnIsPartOfTheLineAndOfTheOffsets() throws {
        let url = try write("aa\r\nbbbb\r\n")
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines, [
            SourceLine(offset: 0, text: "aa\r"), SourceLine(offset: 4, text: "bbbb\r"),
        ])
        XCTAssertEqual(page.end, 10)
    }

    func testAMissingFileIsNilRatherThanAnEmptyPage() {
        XCTAssertNil(TranscriptPager.page(
            url: directory.appendingPathComponent("nope.jsonl"), anchor: .latest, limit: 10
        ), "a claude tab before its first turn has no transcript yet, and 'not there' must "
           + "not render as 'empty conversation'")
    }

    func testAnEmptyFileIsAnEmptyPage() throws {
        let url = try write("")
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.reset)
    }
}
