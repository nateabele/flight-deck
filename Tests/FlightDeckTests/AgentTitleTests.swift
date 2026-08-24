import XCTest
@testable import FlightDeck

/// **A legal conversation name is a property of the channel the name travels down.**
///
/// `SessionStore.rename` used to run every agent's title through
/// `ClaudeSession.sanitizedName`, whose shell-metacharacter strip exists because claude's
/// rename is *typed at a pty that may be a bare shell*. Codex's rename is `thread/name/set`
/// over JSON-RPC — no shell, no pty, no quoting anywhere on the path — so the strip bought
/// nothing and cost the user their punctuation, in codex's own thread list, in
/// `session_index.jsonl`, and in the sidebar.
///
/// **This file exists because that shipped behaviour was asserted by nothing at all.** The
/// change to it broke no test in the suite, in either direction, which is exactly the state
/// that lets a behaviour drift without anyone noticing. Both agents' answers are pinned here
/// now, side by side, so a future change has to pick which one it means.
final class AgentTitleTests: XCTestCase {
    /// The audit's own example (§4.6). This is the whole change, in one line each.
    func testOnlyClaudeStripsShellMetacharacters() {
        XCTAssertEqual(AgentID.claude.sanitizedTitle("fix build (part 2)"), "fix build part 2")
        XCTAssertEqual(AgentID.codex.sanitizedTitle("fix build (part 2)"), "fix build (part 2)")
    }

    /// The whole set claude removes, because `/rename <name>` can reach a bare shell.
    func testClaudeRemovesEveryShellMetacharacterAndCodexKeepsThemAll() {
        let raw = "a;b&c|d`e$f(g)h<i>j"
        XCTAssertEqual(AgentID.claude.sanitizedTitle(raw), "abcdefghij")
        XCTAssertEqual(AgentID.codex.sanitizedTitle(raw), raw)
    }

    /// **Control characters are stripped for BOTH, and that is not the shell rule under
    /// another name.** A newline breaks a sidebar row whatever the channel — and for claude
    /// it would submit the injected `/rename` halfway through. A codex title that kept its
    /// newlines would be the same bug with a different cause.
    func testBothAgentsStripControlCharacters() {
        XCTAssertEqual(AgentID.claude.sanitizedTitle("a\nb\tc\u{7}d"), "abcd")
        XCTAssertEqual(AgentID.codex.sanitizedTitle("a\nb\tc\u{7}d"), "abcd")
    }

    func testBothAgentsTrimAndCap() {
        XCTAssertEqual(AgentID.claude.sanitizedTitle("  hi  "), "hi")
        XCTAssertEqual(AgentID.codex.sanitizedTitle("  hi  "), "hi")
        XCTAssertEqual(AgentID.claude.sanitizedTitle(String(repeating: "x", count: 200))?.count, 120)
        XCTAssertEqual(AgentID.codex.sanitizedTitle(String(repeating: "x", count: 200))?.count, 120)
    }

    /// nil is "revert to the previous title" at every call site, so an agent that answered
    /// an empty string instead would blank a sidebar row rather than decline to change it.
    func testNothingUsableIsRefusedByBothAgents() {
        for agent in AgentID.allCases {
            XCTAssertNil(agent.sanitizedTitle("   "), "\(agent)")
            XCTAssertNil(agent.sanitizedTitle(""), "\(agent)")
        }
        // Claude only: a title made *entirely* of metacharacters is nothing usable to it,
        // and is a perfectly good codex thread name.
        XCTAssertNil(AgentID.claude.sanitizedTitle("$()"))
        XCTAssertEqual(AgentID.codex.sanitizedTitle("$()"), "$()")
    }

    /// **`nil` is codex's answer, not a gap.** A codex thread's name lives in
    /// `session_index.jsonl` and reaches the store through `CodexNameWatcher`; the rollout
    /// carries conversation content. The store's default resolver used to be
    /// `ConversationTitle.resolve` for every agent — a claude JSONL parser — reached from
    /// `repin` through an agent-blind `binding(for:).transcriptURL`.
    func testOnlyClaudeReadsAConversationNameOutOfItsTranscript() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        try #"{"type":"custom-title","customTitle":"named in the file"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(AgentID.claude.title(fromTranscriptAt: url), "named in the file")
        XCTAssertNil(
            AgentID.codex.title(fromTranscriptAt: url),
            "a codex rollout must never be parsed as a claude transcript"
        )
    }

    /// The marker file and the identity parse, asked of the agent rather than switched on
    /// inside `AccountDirectory`. Kept here beside the other namings: one of these two
    /// answers is what decides whether a directory is a home at all.
    func testEachAgentNamesItsOwnHomeMarker() {
        XCTAssertEqual(AgentID.claude.homeMarkerFile, ".claude.json")
        XCTAssertEqual(AgentID.codex.homeMarkerFile, "auth.json")
        XCTAssertEqual(AgentID.claude.homeMarkerFile, AccountDirectory.marker(for: .claude))
        XCTAssertEqual(AgentID.codex.homeMarkerFile, AccountDirectory.marker(for: .codex))
    }

    /// Each parse reads its own agent's file shape and refuses the other's, so a mis-routed
    /// marker degrades to "no answer" rather than to a wrong email under a real account.
    func testEachAgentParsesItsOwnHomeFileAndRefusesTheOthers() throws {
        let claudeFile = Data(#"{"oauthAccount":{"emailAddress":"a@b.c"}}"#.utf8)
        XCTAssertEqual(AgentID.claude.identity(fromHomeData: claudeFile)?.email, "a@b.c")
        XCTAssertNil(AgentID.codex.identity(fromHomeData: claudeFile))
    }
}
