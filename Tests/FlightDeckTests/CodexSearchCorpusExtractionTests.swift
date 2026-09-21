import XCTest
@testable import FlightDeck

/// Extraction and naming for codex, mirroring `TranscriptExtractorTests` and
/// `ClaudeSearchCorpusTests` for the record shapes a rollout actually uses.
final class CodexSearchCorpusExtractionTests: XCTestCase {
    private let corpus = CodexSearchCorpus()

    private static func lines() throws -> [String] {
        let url = try XCTUnwrap(
            Bundle(for: CodexSearchCorpusExtractionTests.self).url(
                forResource: "codex-rollout-sample", withExtension: "jsonl",
                subdirectory: "Fixtures"
            ),
            "Fixtures/codex-rollout-sample.jsonl not found in the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func ref(indexedName: String?) -> TranscriptRef {
        TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/rollout.jsonl"), projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.codex"), workingDirectory: "/w/fd",
            conversationID: "conv-sample", agent: .codex, provenance: "exec",
            indexedName: indexedName, modified: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: Extraction

    /// The fixture's only two `event_msg` prose records are the only rows that come back,
    /// in order, each carrying the role its own record type implies.
    func testIndexesEventMsgProseOnly() throws {
        let messages = try Self.lines().enumerated().flatMap { offset, line in
            corpus.indexedMessages(inLine: line, conversationID: "conv-sample", at: offset)
        }
        XCTAssertEqual(messages.map(\.text), [
            "Index the Claude Code conversations for this directory.",
            "Sure, I'll index them now.",
            "Run the shell command: echo hi. Then reply with exactly the word: done",
            "done",
        ])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertTrue(messages.allSatisfy { $0.conversationID == "conv-sample" })
    }

    /// The fixture's `response_item`/`message` row with `role: "assistant"` repeats the exact
    /// text of the `agent_message` beside it. It must not also produce a row, or every reply
    /// would be indexed twice.
    func testDropsResponseItemDuplicateOfTheSameReply() throws {
        let duplicate = try XCTUnwrap(
            Self.lines().first { $0.contains("msg_reply_dup") }
        )
        XCTAssertEqual(corpus.indexedMessages(inLine: duplicate, conversationID: "c", at: 0), [])
    }

    /// The fixture's `response_item`/`message` row with `role: "user"` is the assembled
    /// prompt, not a person's turn — it must never surface as a `.user` index row.
    func testDropsTheAssembledPromptBlob() throws {
        let promptBlob = try XCTUnwrap(
            Self.lines().first { $0.contains("msg_prompt") }
        )
        XCTAssertEqual(corpus.indexedMessages(inLine: promptBlob, conversationID: "c", at: 0), [])
    }

    /// `agent_reasoning` earns a timeline row (`CodexTimelineMapper`) but not an index row —
    /// the same reason `TranscriptExtractor` drops tool blocks.
    func testDropsAgentReasoning() throws {
        let reasoning = try XCTUnwrap(
            Self.lines().first { $0.contains("agent_reasoning") }
        )
        XCTAssertEqual(corpus.indexedMessages(inLine: reasoning, conversationID: "c", at: 0), [])

        let reasoningResponseItem = try XCTUnwrap(
            Self.lines().first { $0.contains("rs_sample") }
        )
        XCTAssertEqual(
            corpus.indexedMessages(inLine: reasoningResponseItem, conversationID: "c", at: 0), []
        )
    }

    /// Codex writes fractional seconds; a formatter missing `.withFractionalSeconds` returns
    /// nil for every one of them, silently falling every message back to file mtime.
    func testParsesFractionalSecondTimestamps() throws {
        let line = try XCTUnwrap(
            Self.lines().first { $0.contains("Index the Claude Code conversations") }
        )
        let stamp = try XCTUnwrap(
            corpus.indexedMessages(inLine: line, conversationID: "c", at: 0).first?.timestamp
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(formatter.date(from: "2026-09-16T16:25:50.889Z"))
        XCTAssertEqual(stamp.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: Naming

    /// A real rename wins even when the rollout has a first user message of its own — the
    /// same precedence claude's rule states, applied to codex's out-of-band name.
    func testARealRenameIsAuthoritative() throws {
        XCTAssertEqual(
            corpus.conversationName(inLines: try Self.lines(), for: ref(indexedName: "Pipeline Review")),
            .authoritative("Pipeline Review")
        )
    }

    /// Flight Deck's own default tab title, pushed into `session_index.jsonl` by
    /// `thread/name/set`, must lose to the rollout's own first user message.
    func testAPlaceholderLosesToTheFirstUserMessage() throws {
        XCTAssertEqual(
            corpus.conversationName(inLines: try Self.lines(), for: ref(indexedName: "session 206")),
            .fallback("Index the Claude Code conversations for this directory.")
        )
    }

    /// With no user message to fall back to, a placeholder name is still better than the
    /// bare conversation id.
    func testAPlaceholderAloneIsAFallback() {
        XCTAssertEqual(
            corpus.conversationName(inLines: [], for: ref(indexedName: "session 206")),
            .fallback("session 206")
        )
    }

    /// Anchored on purpose: a thread somebody genuinely titled "session 4 retrospective" is
    /// not a placeholder and keeps its name, even with no user message in scope.
    func testANameThatMerelyStartsWithSessionIsNotAPlaceholder() {
        XCTAssertEqual(
            corpus.conversationName(inLines: [], for: ref(indexedName: "session 4 retrospective")),
            .authoritative("session 4 retrospective")
        )
    }

    func testNoNameAndNoMessageIsUnknown() {
        XCTAssertEqual(corpus.conversationName(inLines: [], for: ref(indexedName: nil)), .unknown)
    }
}
