import XCTest
@testable import FlightDeck

final class ClaudeSessionTests: XCTestCase {
    let sid = UUID(uuidString: "38f62687-0abb-4b2b-9cc7-35276b243bb2")!

    func testEncodesEveryNonAlphanumericAsDash() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/Users/nate/Desktop/Scratch/gltf-viewer"),
            "-Users-nate-Desktop-Scratch-gltf-viewer"
        )
    }

    /// One-for-one, no collapsing: `/-` becomes `--`.
    func testDoesNotCollapseRuns() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/private/tmp/x/-Users-nate"),
            "-private-tmp-x--Users-nate"
        )
    }

    func testTranscriptURLJoinsDirAndSessionID() {
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        let url = ClaudeSession.transcriptURL(
            sessionID: sid, workingDirectory: "/work/foo", projectsRoot: root
        )
        XCTAssertEqual(url.path, "/root/-work-foo/\(sid.uuidString.lowercased()).jsonl")
    }

    func testParsesCustomTitleLine() {
        let line = #"{"type":"custom-title","customTitle":"my name","sessionId":"\#(sid.uuidString.lowercased())"}"#
        XCTAssertEqual(ClaudeSession.customTitle(inLine: line, sessionID: sid), "my name")
    }

    func testIgnoresAgentNameLine() {
        let line = #"{"type":"agent-name","agentName":"x","sessionId":"\#(sid.uuidString.lowercased())"}"#
        XCTAssertNil(ClaudeSession.customTitle(inLine: line, sessionID: sid))
    }

    func testIgnoresMismatchedSessionID() {
        let line = #"{"type":"custom-title","customTitle":"x","sessionId":"00000000-0000-0000-0000-000000000000"}"#
        XCTAssertNil(ClaudeSession.customTitle(inLine: line, sessionID: sid))
    }

    func testIgnoresMalformedJSON() {
        XCTAssertNil(ClaudeSession.customTitle(inLine: "{not json", sessionID: sid))
        XCTAssertNil(ClaudeSession.customTitle(inLine: "", sessionID: sid))
    }

    func testSanitizerTrimsAndRejectsEmpty() {
        XCTAssertEqual(ClaudeSession.sanitizedName("  hi  "), "hi")
        XCTAssertNil(ClaudeSession.sanitizedName("   "))
        XCTAssertNil(ClaudeSession.sanitizedName(""))
    }

    func testSanitizerStripsControlCharacters() {
        XCTAssertEqual(ClaudeSession.sanitizedName("a\nb\tc\u{7}d"), "abcd")
    }

    func testSanitizerCapsLength() {
        XCTAssertEqual(ClaudeSession.sanitizedName(String(repeating: "x", count: 200))?.count, 120)
    }

    func testLaunchCommandSingleQuotesAndEscapes() {
        let cmd = ClaudeSession.launchCommand(sessionID: sid, title: "it's mine")
        XCTAssertEqual(
            cmd,
            "claude --session-id \(sid.uuidString.lowercased()) --name 'it'\\''s mine'\n"
        )
    }

    /// Restore falls back to a fresh session when the transcript is gone.
    /// Verified empirically: `claude --resume <unknown-uuid>` exits 1, so `||` fires.
    func testResumeCommandFallsBackToFreshSession() {
        let id = sid.uuidString.lowercased()
        XCTAssertEqual(
            ClaudeSession.resumeCommand(sessionID: sid, title: "my work"),
            "claude --resume \(id) || claude --session-id \(id) --name 'my work'\n"
        )
    }
}
