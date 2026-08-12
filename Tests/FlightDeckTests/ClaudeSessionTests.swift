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

    /// Verified against real `claude`: cwd `…/café-Ω-probe` produced `…-caf----probe`.
    /// Swift's `isLetter` would have kept `é` and `Ω`; Claude does not.
    func testEncodesNonASCIILettersAsDashes() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/x/café-Ω-probe"),
            "-x-caf----probe"
        )
    }

    /// Verified against real `claude`: an astral-plane character becomes TWO dashes,
    /// proving the replacement is per UTF-16 code unit, not per scalar.
    func testEncodesAstralCharacterAsTwoDashes() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/x/emo🎈dir"),
            "-x-emo--dir"
        )
    }

    func testKeepsASCIIAlphanumericsOnly() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/a1/B2_c3.d"),
            "-a1-B2-c3-d"
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

    /// Defense in depth: when `claude` isn't running, an injected `/rename` goes straight
    /// to a shell prompt, so these must never reach it — otherwise `/rename x; rm -rf ~`
    /// executes. See ClaudeSession.shellMetacharacters.
    func testSanitizerStripsShellMetacharacters() {
        XCTAssertEqual(ClaudeSession.sanitizedName("a;b&c|d`e$f(g)h<i>j"), "abcdefghij")
    }

    /// Ordinary punctuation people actually use in session names must survive.
    func testSanitizerKeepsOrdinaryPunctuation() {
        let name = "/ - _ . : + # @ , ' \" ! ? = * [ ] { } ~ %"
        XCTAssertEqual(ClaudeSession.sanitizedName(name), name)
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

    private var fixedID: UUID { UUID(uuidString: "4F3A0000-0000-0000-0000-000000000001")! }

    func testLaunchCommandWithNoFlagsIsUnchanged() {
        let command = ClaudeSession.launchCommand(sessionID: fixedID, title: "one")
        XCTAssertEqual(
            command,
            "claude --session-id 4f3a0000-0000-0000-0000-000000000001 --name 'one'\n"
        )
    }

    func testLaunchCommandAppendsFlagsAfterAppManagedOnes() {
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertEqual(
            command,
            "claude --session-id 4f3a0000-0000-0000-0000-000000000001 --name 'one' --model opus\n"
        )
    }

    func testResumeCommandAppliesFlagsToBothBranches() {
        let command = ClaudeSession.resumeCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--model": .value("opus")])
        )
        // The fallback branch must be configured too, or a pruned transcript silently
        // launches an unconfigured session.
        XCTAssertEqual(command.components(separatedBy: "--model opus").count - 1, 2)
    }

    func testResumeCommandWithNoFlagsIsUnchanged() {
        let command = ClaudeSession.resumeCommand(sessionID: fixedID, title: "one")
        let id = "4f3a0000-0000-0000-0000-000000000001"
        XCTAssertEqual(command, "claude --resume \(id) || claude --session-id \(id) --name 'one'\n")
    }

    func testFlagValuesAreQuotedNotStripped() throws {
        let hostile = "'; rm -rf ~; '"
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--system-prompt": .value(hostile)])
        )
        // The real assertion: the value survives as ONE literal argument rather than
        // decomposing into shell syntax. Tokenizing the command is how we prove that.
        // `tokenize` returns `[ClaudeFlagQuoting.Token]` (Task 4 added `wasQuoted`), so
        // compare against `.text`.
        let texts = try ClaudeFlagQuoting.tokenize(
            command.trimmingCharacters(in: .newlines)
        ).map(\.text)
        guard let index = texts.firstIndex(of: "--system-prompt"), index + 1 < texts.count else {
            return XCTFail("--system-prompt missing from: \(command)")
        }
        XCTAssertEqual(texts[index + 1], hostile)
        XCTAssertFalse(texts.contains("rm"), "the value must not split into separate tokens")
        XCTAssertFalse(texts.contains(";"), "the value must not split into separate tokens")
    }

    func testLockedPrefixMatchesTheStartOfTheLaunchCommand() {
        let prefix = ClaudeSession.lockedPrefix(sessionID: fixedID, title: "one")
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertTrue(command.hasPrefix(prefix))
    }

    func testLockedPrefixIsTheWholeCommandWhenThereAreNoFlags() {
        let prefix = ClaudeSession.lockedPrefix(sessionID: fixedID, title: "one")
        XCTAssertEqual(
            ClaudeSession.launchCommand(sessionID: fixedID, title: "one"),
            prefix + "\n"
        )
    }

    func testLaunchCommandDropsEmptyListFlags() {
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--add-dir": .list([]), "--model": .value("opus")])
        )
        XCTAssertFalse(command.contains("--add-dir"))
        XCTAssertTrue(command.contains("--model opus"))
    }

    func testResumeCommandDropsEmptyListFlags() {
        let command = ClaudeSession.resumeCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--add-dir": .list([])])
        )
        XCTAssertFalse(command.contains("--add-dir"))
    }

    func testNonEmptyListFlagsStillLaunch() {
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--add-dir": .list(["../shared"])])
        )
        XCTAssertTrue(command.contains("--add-dir ../shared"))
    }

    /// The Preferences panes show a placeholder prefix rather than calling `lockedPrefix`
    /// (there is no session yet). Nothing else keeps the two in step, so pin the *sequence*
    /// of app-managed flag names, not just a couple of substrings — a substring check would
    /// stay green if a third flag were added to `lockedPrefix` or the two were reordered,
    /// leaving the placeholder stale and misleading.
    func testPlaceholderPrefixMatchesTheRealPrefixShape() throws {
        let real = ClaudeSession.lockedPrefix(sessionID: fixedID, title: "one")
        let placeholder = ClaudeSettingsTab.placeholderPrefix

        func flagNames(_ command: String) throws -> [String] {
            try ClaudeFlagQuoting.tokenize(command).map(\.text).filter { $0.hasPrefix("--") }
        }

        XCTAssertEqual(try flagNames(real), try flagNames(placeholder))
    }
}
