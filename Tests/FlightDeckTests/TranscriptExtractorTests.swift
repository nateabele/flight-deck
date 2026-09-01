import XCTest
@testable import FlightDeck

/// What is worth searching inside a transcript, and — mostly — what is not.
///
/// Measured over 60 random transcripts (97 MB): user and assistant text are 5.0% of the
/// bytes. Tool results are 20%, tool inputs 9%, the JSON envelope 54%. This type is the
/// boundary that keeps the other 95% out of the index, so every exclusion below is a
/// deliberate size and relevance decision, not an oversight.
final class TranscriptExtractorTests: XCTestCase {
    private let conversation = "c1"

    private func extract(_ line: String) -> [IndexedMessage] {
        TranscriptExtractor.messages(inLine: line, conversationID: conversation, offset: 0)
    }

    func testAStringContentUserMessageIsExtracted() {
        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"fix the rename bug"}}"#
        let messages = extract(line)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "fix the rename bug")
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.conversationID, conversation)
    }

    func testEveryTextBlockOfABlockArrayIsExtracted() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}}"#
        XCTAssertEqual(extract(line).map(\.text), ["first", "second"])
    }

    /// The 29% of bytes that would change what the feature means: searching `rename` must
    /// find the moment somebody asked for a rename, not every file that contains the word.
    func testToolBlocksYieldNothing() {
        let toolUse = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"old_string":"rename"}}]}}"#
        let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"rename rename rename"}]}}"#

        XCTAssertTrue(extract(toolUse).isEmpty)
        XCTAssertTrue(extract(toolResult).isEmpty)
    }

    /// `isMeta` records are the harness talking to itself — caveats, reminders, the
    /// system-reminder envelope. `ConversationTitle.resolve` already excludes them when
    /// picking a name, for the same reason: they are not something a person said.
    func testMetaAndCompactSummaryRecordsAreExcluded() {
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"caveat: the messages below"}}"#
        let compact = #"{"type":"user","isCompactSummary":true,"message":{"content":"summary of the above"}}"#

        XCTAssertTrue(extract(meta).isEmpty)
        XCTAssertTrue(extract(compact).isEmpty)
    }

    /// A transcript is appended to while we read it, and `TailReader` hands back only
    /// complete lines — but a line can still be malformed for reasons we do not control.
    /// A bad line must cost that line, never the pass.
    func testMalformedLinesAreSkippedRatherThanThrowing() {
        XCTAssertTrue(extract("not json at all").isEmpty)
        XCTAssertTrue(extract("").isEmpty)
        XCTAssertTrue(extract(#"{"type":"user"}"#).isEmpty)
    }

    func testOtherRecordTypesAreIgnored() {
        XCTAssertTrue(extract(#"{"type":"custom-title","customTitle":"rename-break"}"#).isEmpty)
        XCTAssertTrue(extract(#"{"type":"system","content":"rename"}"#).isEmpty)
    }

    /// Recency orders transcript hits (§7), so the record's own timestamp is what the
    /// ranker sorts on. File mtime is only the fallback for records that lack one.
    func testTheRecordTimestampIsParsed() throws {
        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"hi"}}"#
        let stamp = try XCTUnwrap(extract(line).first?.timestamp)
        let expected = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-26T21:57:19Z")
        )

        XCTAssertEqual(stamp.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func testWhitespaceOnlyTextIsNotWorthIndexing() {
        XCTAssertTrue(extract(#"{"type":"user","message":{"content":"   \n  "}}"#).isEmpty)
    }

    /// One line can yield several messages, and they all name the same line.
    ///
    /// An offset here is a LINE boundary, which is exactly what a timeline cursor is — so two
    /// messages from one record sharing a number is correct, not a collision.
    func testEveryMessageFromOneLineCarriesThatLinesOffset() {
        let line = """
            {"type":"assistant","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":\
            [{"type":"text","text":"first"},{"type":"text","text":"second"}]}}
            """
        let messages = TranscriptExtractor.messages(
            inLine: line, conversationID: "abc", offset: 4096
        )
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map(\.offset), [4096, 4096])
        XCTAssertEqual(messages.map(\.text), ["first", "second"])
    }
}
