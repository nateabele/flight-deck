import XCTest
@testable import FlightDeck

/// Fixtures are verbatim screens captured from a live `claude` through a terminal
/// emulator (pyte) driving a pty, not hand-written approximations. The separator after
/// `❯` is U+00A0 in every case that has content — including the placeholder hint, which
/// is why `content` alone can never decide whether a draft exists.
final class InputBarTests: XCTestCase {
    private let rule = String(repeating: "─", count: 92)

    /// The chrome below the box. Present in every real screen, and its rows start with two
    /// spaces exactly like a wrapped continuation row — so the parser has to stop at the
    /// closing rule rather than counting indented rows.
    private var footer: String {
        """
        \(rule)
          Opus 5 (1M context)  [░░░░░░░░░░] 0%  ⎇ master
          ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
        """
    }

    private func viewport(_ boxRows: [String]) -> String {
        ([rule] + boxRows + [footer]).joined(separator: "\n")
    }

    func testEmptyBarHasOneRowAndNoContent() {
        let bar = InputBar.read(fromViewport: viewport(["❯"]))
        XCTAssertEqual(bar?.rows.count, 1)
        XCTAssertEqual(bar?.content, "")
    }

    func testSingleLineDraftHasOneRowAndItsText() {
        let bar = InputBar.read(fromViewport: viewport(["❯\u{a0}short draft"]))
        XCTAssertEqual(bar?.rows.count, 1)
        XCTAssertEqual(bar?.content, "short draft")
    }

    /// A hint is indistinguishable from a draft here, deliberately: both are one row of
    /// text behind a U+00A0. Anything that tried to tell them apart by content would be
    /// wrong, which is why the store kills first and checks whether the screen moved.
    func testPlaceholderHintLooksExactlyLikeADraft() {
        let bar = InputBar.read(fromViewport: viewport(["❯\u{a0}Try \"how does RootView.swift work?\""]))
        XCTAssertEqual(bar?.rows.count, 1)
        XCTAssertEqual(bar?.content, "Try \"how does RootView.swift work?\"")
    }

    /// Wrapping is not multiline, but Ctrl+U treats it like it is: the spike showed
    /// Ctrl+E + Ctrl+U failing to clear a 240-character wrapped line. Both must count as
    /// more than one row so the store defers instead of corrupting the draft.
    func testWrappedSingleLogicalLineCountsAsMultipleRows() {
        let bar = InputBar.read(fromViewport: viewport([
            "❯\u{a0}" + String(repeating: "x", count: 90),
            "  " + String(repeating: "x", count: 90),
            "  xxxxxxxx",
        ]))
        XCTAssertEqual(bar?.rows.count, 3)
    }

    func testTwoLogicalLinesCountAsMultipleRows() {
        let bar = InputBar.read(fromViewport: viewport([
            "❯\u{a0}line one",
            "  line two",
        ]))
        XCTAssertEqual(bar?.rows.count, 2)
    }

    func testViewportWithoutAPromptMarkerIsUnreadable() {
        XCTAssertNil(InputBar.read(fromViewport: "\(rule)\n  no prompt here\n\(rule)"))
    }

    /// The box is the *last* one on screen: earlier `❯` glyphs appear in the scrollback as
    /// echoes of submitted messages, and locking onto one of those would read a frozen
    /// snapshot of an old prompt instead of the live input bar.
    func testReadsTheLastBoxWhenScrollbackContainsSubmittedEchoes() {
        let screen = """
        ❯ /rename an earlier message
          ⎿  Session renamed to: something
        \(viewport(["❯\u{a0}current draft"]))
        """
        let bar = InputBar.read(fromViewport: screen)
        XCTAssertEqual(bar?.content, "current draft")
        XCTAssertEqual(bar?.rows.count, 1)
    }
}
