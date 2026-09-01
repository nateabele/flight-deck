import XCTest
@testable import FlightDeck

/// Reads and types into codex's composer, against the real captured screens.
///
/// Everything here is asserted against `Fixtures/Codex/tui-*.captured.txt` — verbatim output
/// from a real `codex resume`, which is the production shape, since a Flight Deck codex tab
/// IS `codex resume`. Nothing in this file describes a screen anybody authored.
@MainActor
final class CodexTextChannelTests: XCTestCase {
    private let channel = CodexTextChannel()

    private func viewport(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: CodexTextChannelTests.self).url(
                forResource: name, withExtension: "txt", subdirectory: "Fixtures/Codex"
            ),
            "missing capture \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Reading

    func testTheComposerIsFoundOnARealIdleScreen() throws {
        let bar = try XCTUnwrap(
            InputBar.read(fromViewport: viewport("tui-idle.captured"), marker: InputBar.codexMarker)
        )
        XCTAssertEqual(bar.rows.count, 1)
        XCTAssertEqual(bar.content, CodexTextChannel.placeholder)
    }

    /// The regression the whole feature rests on: claude's marker finds nothing on a codex
    /// screen. If this ever starts passing, `InputBar`'s default has silently become wrong for
    /// one of the two agents.
    func testClaudesMarkerFindsNothingOnACodexScreen() throws {
        let screen = try viewport("tui-idle.captured")
        XCTAssertNil(InputBar.read(fromViewport: screen, marker: InputBar.claudeMarker))
    }

    /// A working screen carries `›` twice — the echoed submitted prompt in the scrollback and
    /// the live composer. Locking onto the earlier one would read a frozen old prompt.
    func testTheLiveComposerIsReadNotTheEchoedPrompt() throws {
        let bar = try XCTUnwrap(
            InputBar.read(fromViewport: viewport("tui-working.captured"), marker: InputBar.codexMarker)
        )
        XCTAssertEqual(bar.content, CodexTextChannel.placeholder,
                       "the last marker is the composer; the earlier one is the echoed turn")
        XCTAssertFalse(bar.content.contains("essay"),
                       "must not lock onto the submitted prompt sitting above it")
    }

    // MARK: - isComposerEmpty

    func testThePlaceholderCountsAsEmpty() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        XCTAssertTrue(channel.isComposerEmpty(injector))
    }

    /// Codex keeps its composer up and accepting mid-turn, and the line is byte-identical to
    /// the idle one — so a busy screen must still read as an empty composer. Anything that
    /// inferred "not ready" from this line would be wrong during every turn.
    func testAWorkingScreenStillReadsAsAnEmptyComposer() throws {
        let injector = FakeInjector(viewport: try viewport("tui-working.captured"))
        XCTAssertTrue(channel.isComposerEmpty(injector))
    }

    func testARealDraftIsNotEmpty() {
        let injector = FakeInjector(viewport: """
        › write the migration notes

          gpt-5.6-sol default · /tmp/work
        """)
        XCTAssertFalse(channel.isComposerEmpty(injector))
    }

    /// The discriminator that makes this safe on a tab sitting at a bare shell. A prompt theme
    /// drawing `›` with no codex status line beneath it is not a composer — and here the words
    /// would not be typed into a box, they would be RUN.
    func testAShellPromptDrawingTheSameGlyphIsRefused() {
        let injector = FakeInjector(viewport: "› ls -la\n")
        XCTAssertFalse(channel.isComposerEmpty(injector))
        XCTAssertFalse(
            channel.submit("x", into: injector, settle: { $0() }, stillWanted: { true }, onSent: {}),
            "no codex status line means this is not codex's composer"
        )
    }

    /// Presence of ` · ` somewhere on screen is not the test — POSITION is. A shell whose
    /// scrollback merely mentions the separator must not be mistaken for a composer, or the
    /// guard is defeated by any tab that once ran `ls` over a path containing it.
    func testAFooterFarAboveTheMarkerDoesNotQualify() {
        let injector = FakeInjector(viewport: """
          gpt-5.6-sol default · /tmp/work
        some other output
        more output
        still more
        › ls -la
        """)
        XCTAssertFalse(channel.isComposerEmpty(injector),
                       "the status line must sit directly below the composer, not anywhere")
    }

    func testAFooterWithinThreeRowsBelowTheMarkerQualifies() {
        let injector = FakeInjector(viewport: """
        › \(CodexTextChannel.placeholder)

          gpt-5.6-sol default · /tmp/work
        """)
        XCTAssertTrue(channel.isComposerEmpty(injector),
                      "blank line then footer is exactly what both real captures show")
    }

    // MARK: - submit

    func testSubmittingIntoAnEmptyComposerTypesAndReturnsWithoutRestoring() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        let sent = channel.submit("ship it", into: injector,
                                  settle: { $0() }, stillWanted: { true }, onSent: {})
        XCTAssertTrue(sent)
        XCTAssertEqual(injector.actions, [.killLine, .text("ship it"), .return],
                       "an empty composer needs no restore — the placeholder survives any kill")
    }

    /// The draft is put back by RE-TYPING what was read, not by Ctrl-Y: codex has never been
    /// shown to keep a deleted-text ring, and the draft is on screen before the kill anyway.
    func testARealDraftIsRetypedAfterTheReturnNotYanked() {
        let injector = FakeInjector(viewport: """
        › half-written thought

          gpt-5.6-sol default · /tmp/work
        """)
        // The kill empties the composer, which is what the post-kill read must observe.
        injector.viewportAfterKill = """
        › \(CodexTextChannel.placeholder)

          gpt-5.6-sol default · /tmp/work
        """

        XCTAssertTrue(channel.submit("ship it", into: injector,
                                     settle: { $0() }, stillWanted: { true }, onSent: {}))
        XCTAssertEqual(injector.actions,
                       [.killLine, .text("ship it"), .return, .text("half-written thought")],
                       "restore comes AFTER the Return, so a wrong guess can never submit it")
        XCTAssertFalse(injector.actions.contains(.yank), "codex has no ring to yank from")
    }

    func testACancelledRequestTypesNothingAfterTheKill() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        XCTAssertTrue(channel.submit("ship it", into: injector,
                                     settle: { $0() }, stillWanted: { false }, onSent: {}))
        XCTAssertEqual(injector.actions, [.killLine],
                       "a request replaced while codex repainted must not be typed")
    }

    func testOnSentRunsExactlyOnceWhenTheChannelReturnsTrue() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        var sentCount = 0
        XCTAssertTrue(channel.submit("ship it", into: injector,
                                     settle: { $0() }, stillWanted: { true },
                                     onSent: { sentCount += 1 }))
        XCTAssertEqual(sentCount, 1, "the store clears its mid-injection mark in here")
    }

    // MARK: - Fixture

    private final class FakeInjector: TextInjecting {
        enum Action: Equatable {
            case killLine, yank, `return`, text(String), arrowDown, arrowUp, escape
        }

        private var viewport: String
        var viewportAfterKill: String?
        private(set) var actions: [Action] = []

        init(viewport: String) { self.viewport = viewport }

        func readViewport() -> String? { viewport }
        func sendText(_ text: String) { actions.append(.text(text)) }
        func sendReturn() { actions.append(.return) }
        func sendKillLine() {
            actions.append(.killLine)
            if let after = viewportAfterKill { viewport = after }
        }
        func sendYank() { actions.append(.yank) }
        func sendArrowDown() { actions.append(.arrowDown) }
        func sendArrowUp() { actions.append(.arrowUp) }
        func sendEscape() { actions.append(.escape) }
    }
}
