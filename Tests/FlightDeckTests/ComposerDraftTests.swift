import XCTest
@testable import FlightDeck

/// `AgentTextChannel.draft` for every agent: what a smart-sleep rollover carries from the
/// frozen agent's composer into the resumed one. Each case reads that agent's own screen
/// grammar — a captured or synthetic screen from its fixtures where one exists — because the
/// failure this guards against is agent-specific: an empty box whose placeholder is read as a
/// draft (and pasted into the next composer as if typed), or a draft read as empty (and lost).
@MainActor
final class ComposerDraftTests: XCTestCase {
    /// A screen and nothing else: `draft` must only ever read.
    private final class Screen: TextInjecting {
        var viewport: String?
        var keys = 0
        init(_ viewport: String?) { self.viewport = viewport }
        func sendText(_ text: String) { keys += 1 }
        func sendReturn() { keys += 1 }
        func sendKillLine() { keys += 1 }
        func sendYank() { keys += 1 }
        func sendArrowDown() { keys += 1 }
        func sendArrowUp() { keys += 1 }
        func sendTab() { keys += 1 }
        func sendEscape() { keys += 1 }
        func sendCharacterKey(_ character: Character) { keys += 1 }
        func sendControlKey(_ letter: Character) { keys += 1 }
        func readViewport() -> String? { viewport }
    }

    private func fixture(_ agent: String, _ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: ComposerDraftTests.self).url(
            forResource: name, withExtension: "txt", subdirectory: "Fixtures/\(agent)"), "missing \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func claudeBox(_ rows: [String]) -> String {
        let rule = String(repeating: "─", count: 40)
        return ([rule] + rows + [rule, "  ? for shortcuts"]).joined(separator: "\n")
    }

    // MARK: claude

    func testClaudeReadsARealDraft() {
        let screen = Screen(claudeBox(["❯\u{a0}refactor the parser next"]))
        XCTAssertEqual(ClaudeTextChannel().draft(screen), "refactor the parser next")
        XCTAssertEqual(screen.keys, 0, "reading a draft must never type")
    }

    /// The rotating hint renders exactly like a draft; pasting it into the next composer would
    /// put words in the user's mouth.
    func testClaudeReadsItsRotatingHintAsEmpty() {
        let screen = Screen(claudeBox(["❯\u{a0}Try \"how does RootView.swift work?\""]))
        XCTAssertEqual(ClaudeTextChannel().draft(screen), "")
        XCTAssertEqual(ClaudeTextChannel().draft(Screen(claudeBox(["❯"]))), "")
        XCTAssertEqual(ClaudeTextChannel().draft(Screen(claudeBox(["❯ Press up to edit queued messages"]))), "")
    }

    func testClaudeJoinsAWrappedDraftWithASpace() {
        let screen = Screen(claudeBox(["❯ the first half of a long", "  thought that wrapped"]))
        XCTAssertEqual(ClaudeTextChannel().draft(screen), "the first half of a long thought that wrapped")
    }

    /// No composer (a dialog, a bare shell, an unreadable screen) is "could not tell", never
    /// "empty": the store refuses a rollover on nil rather than drop a draft it never saw.
    func testClaudeWithNoComposerIsUnknown() throws {
        XCTAssertNil(ClaudeTextChannel().draft(Screen(nil)))
        XCTAssertNil(ClaudeTextChannel().draft(Screen(try fixture("Claude", "permission-bash.captured"))))
    }

    // MARK: codex

    func testCodexReadsItsPlaceholderAsEmptyAndADraftAsText() throws {
        let idle = try fixture("Codex", "tui-idle.captured")
        XCTAssertEqual(CodexTextChannel().draft(Screen(idle)), "")
        let drafted = idle.replacingOccurrences(of: "› Ask Codex to do anything", with: "› tighten the retry loop")
        XCTAssertEqual(CodexTextChannel().draft(Screen(drafted)), "tighten the retry loop")
        XCTAssertNil(CodexTextChannel().draft(Screen("$ ls")))
    }

    // MARK: grok

    func testGrokReadsWhatItsBoxHolds() throws {
        XCTAssertEqual(GrokTextChannel().draft(Screen(try fixture("Grok", "tui-idle.synthetic"))), "")
        XCTAssertEqual(GrokTextChannel().draft(Screen(try fixture("Grok", "tui-draft.synthetic"))), "half typed thought")
        XCTAssertNil(GrokTextChannel().draft(Screen(try fixture("Grok", "shell-prompt.synthetic"))))
    }

    // MARK: gemini (agy)

    func testGeminiReadsItsModeHintAsEmpty() {
        XCTAssertEqual(GeminiTextChannel().draft(Screen(GeminiScreens.composer(">"))), "")
        XCTAssertEqual(GeminiTextChannel().draft(Screen(GeminiScreens.composer("> plan mode (shift+tab to cycle)"))), "")
        XCTAssertEqual(GeminiTextChannel().draft(Screen(GeminiScreens.composer("> summarise the diff"))), "summarise the diff")
    }

    // MARK: OpenCode

    func testOpenCodeReadsItsGutterRows() throws {
        XCTAssertEqual(OpenCodeTextChannel().draft(Screen(try fixture("OpenCode", "idle-composer.captured"))), "")
        let drafted = try XCTUnwrap(OpenCodeTextChannel().draft(Screen(try fixture("OpenCode", "draft-composer.captured"))))
        XCTAssertFalse(drafted.isEmpty, "the captured draft screen holds typed text")
        XCTAssertNil(OpenCodeTextChannel().draft(Screen("$ ls")))
    }
}
