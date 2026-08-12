import XCTest
@testable import FlightDeck

final class ConversationTitleTests: XCTestCase {
    private func userLine(_ text: String, isMeta: Bool = false,
                          isCompactSummary: Bool = false) -> String {
        """
        {"type":"user","isMeta":\(isMeta),"isCompactSummary":\(isCompactSummary),\
        "message":{"content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    func testPrefersTheLastNameRecord() {
        let lines = [
            userLine("first thing I asked"),
            #"{"type":"agent-name","agentName":"early name"}"#,
            #"{"type":"agent-name","agentName":"later name"}"#,
        ]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "later name")
    }

    /// `custom-title` and `agent-name` are both rename records; whichever is last wins.
    func testCustomTitleRecordAlsoCounts() {
        let lines = [
            #"{"type":"agent-name","agentName":"early name"}"#,
            #"{"type":"custom-title","customTitle":"newest name"}"#,
        ]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "newest name")
    }

    /// The unnamed case: this is what `claude`'s own /resume picker shows.
    func testFallsBackToFirstUserMessage() {
        let lines = [userLine("fix the flaky test"), userLine("second message")]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "fix the flaky test")
    }

    func testSkipsMetaAndCompactSummaryMessages() {
        let lines = [
            userLine("injected context", isMeta: true),
            userLine("a summary of earlier work", isCompactSummary: true),
            userLine("the real first prompt"),
        ]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "the real first prompt")
    }

    func testCollapsesNewlinesInTheFirstMessage() {
        let lines = [userLine(#"line one\nline two"#)]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "line one line two")
    }

    func testStringContentIsAcceptedAsWellAsBlocks() {
        let lines = [#"{"type":"user","message":{"content":"plain string content"}}"#]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "plain string content")
    }

    func testEmptyTranscriptResolvesToNil() {
        XCTAssertNil(ConversationTitle.resolve(lines: []))
    }

    func testMalformedLinesAreIgnored() {
        let lines = ["not json at all", "", userLine("still found")]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "still found")
    }

    /// Sanitization is shared with every other title path, so the 120-char cap applies.
    func testOverlongFirstMessageIsCapped() {
        let lines = [userLine(String(repeating: "a", count: 400))]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines)?.count, 120)
    }

    func testReadsFromDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("t.jsonl")
        try (userLine("from disk") + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConversationTitle.resolve(transcriptAt: url), "from disk")
    }

    func testMissingFileResolvesToNil() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        XCTAssertNil(ConversationTitle.resolve(transcriptAt: url))
    }
}
