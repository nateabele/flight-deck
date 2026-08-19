import XCTest
@testable import FlightDeck

@MainActor
final class ToolTemplateTests: XCTestCase {
    private func context(
        cwd: String = "/w/a",
        transcript: String? = "/t/x.jsonl"
    ) -> ToolContext {
        ToolContext(
            workingDirectory: cwd,
            projectPath: "/w",
            projectName: "w",
            sessionTitle: "tools",
            agent: .claude,
            conversationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transcriptPath: transcript,
            home: "/Users/nate"
        )
    }

    func testEveryKnownVariableExpands() {
        let c = context()
        XCTAssertEqual(ToolTemplate.expand("${cwd}", in: c), "'/w/a'")
        XCTAssertEqual(ToolTemplate.expand("${project}", in: c), "'/w'")
        XCTAssertEqual(ToolTemplate.expand("${root}", in: c), "'/w'")
        XCTAssertEqual(ToolTemplate.expand("${projectName}", in: c), "'w'")
        XCTAssertEqual(ToolTemplate.expand("${session}", in: c), "'tools'")
        XCTAssertEqual(ToolTemplate.expand("${agent}", in: c), "'claude'")
        XCTAssertEqual(ToolTemplate.expand("${transcript}", in: c), "'/t/x.jsonl'")
        XCTAssertEqual(ToolTemplate.expand("${home}", in: c), "'/Users/nate'")
        XCTAssertEqual(
            ToolTemplate.expand("${conversationID}", in: c),
            "'11111111-2222-3333-4444-555555555555'"
        )
    }

    func testAPathWithSpacesStaysOneArgument() {
        // The bug this whole type exists to prevent: `$EDITOR /Users/nate/My Projects/foo`
        // opens two files, neither of them the one you wanted.
        let expanded = ToolTemplate.expand("$EDITOR ${cwd}", in: context(cwd: "/Users/nate/My Projects/foo"))
        XCTAssertEqual(expanded, "$EDITOR '/Users/nate/My Projects/foo'")
    }

    func testASingleQuoteInAPathIsEscaped() {
        let expanded = ToolTemplate.expand("${cwd}", in: context(cwd: "/w/nate's code"))
        XCTAssertEqual(expanded, #"'/w/nate'\''s code'"#)
    }

    func testDollarEditorIsLeftForTheLoginShell() {
        // Unbraced shell variables are not ours to expand — resolving $EDITOR is exactly what
        // the login shell is for, and rewriting it here would break every user whose editor
        // is set in their profile.
        XCTAssertEqual(ToolTemplate.expand("$EDITOR", in: context()), "$EDITOR")
    }

    func testUnknownBracedNamesAreLeftLiteralForTheShell() {
        XCTAssertEqual(ToolTemplate.expand("${HOME}/x", in: context()), "${HOME}/x")
        XCTAssertEqual(ToolTemplate.expand("${nope}", in: context()), "${nope}")
    }

    func testAKnownNameWithNoValueExpandsToAnEmptyQuotedString() {
        // NOT to nothing. `code ${transcript} ${cwd}` with an absent transcript must not
        // silently slide the cwd into the transcript's argument position.
        XCTAssertEqual(
            ToolTemplate.expand("code ${transcript} ${cwd}", in: context(transcript: nil)),
            "code '' '/w/a'"
        )
    }

    func testSurroundingTextAndRepeatsSurvive() {
        XCTAssertEqual(
            ToolTemplate.expand("cd ${cwd} && git -C ${cwd} status", in: context()),
            "cd '/w/a' && git -C '/w/a' status"
        )
    }

    func testAnUnterminatedBraceIsLeftAlone() {
        XCTAssertEqual(ToolTemplate.expand("echo ${cwd", in: context()), "echo ${cwd")
    }

    func testEmptyTemplateIsEmpty() {
        XCTAssertEqual(ToolTemplate.expand("", in: context()), "")
    }
}
