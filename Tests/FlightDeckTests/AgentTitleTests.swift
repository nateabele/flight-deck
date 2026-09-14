import XCTest
@testable import FlightDeck

/// **A legal conversation name is a property of the channel the name travels down —**
/// **and both agents' channels now answer the same way.**
///
/// `SessionStore.rename` used to run claude's title through `ClaudeSession.sanitizedName`,
/// whose shell-metacharacter strip existed because claude's rename is typed at a pty that
/// *could*, in theory, be a bare shell rather than a live claude. `SessionStore.inject` now
/// refuses to type anywhere but a rule-sandwiched composer actually on screen (see
/// `ClaudeTextChannel`), so that bare-shell case cannot reach `/rename` any more, and the
/// strip that guarded it is gone — the same answer codex already gave, for its own reason:
/// codex's rename is `thread/name/set` over JSON-RPC, no shell or pty on the path at all.
///
/// **This file exists because that shipped behaviour was asserted by nothing at all.** The
/// change to it broke no test in the suite, in either direction, which is exactly the state
/// that lets a behaviour drift without anyone noticing. Both agents' answers are pinned here
/// now, side by side, so a future change has to pick which one it means.
final class AgentTitleTests: XCTestCase {
    /// The audit's own example (§4.6), inverted: both agents now keep it.
    func testNeitherAgentStripsShellMetacharacters() {
        XCTAssertEqual(AgentID.claude.sanitizedTitle("fix build (part 2)"), "fix build (part 2)")
        XCTAssertEqual(AgentID.codex.sanitizedTitle("fix build (part 2)"), "fix build (part 2)")
    }

    /// The whole set that used to be claude-only forbidden survives for both agents now.
    func testBothAgentsKeepEveryFormerShellMetacharacter() {
        let raw = "a;b&c|d`e$f(g)h<i>j"
        XCTAssertEqual(AgentID.claude.sanitizedTitle(raw), raw)
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
        // Neither agent forbids metacharacters any more, so a title made entirely of them is
        // a perfectly good name for both — this used to be claude-only nil.
        XCTAssertEqual(AgentID.claude.sanitizedTitle("$()"), "$()")
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
