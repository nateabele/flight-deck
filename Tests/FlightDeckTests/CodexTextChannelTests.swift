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

    // MARK: - hasComposerBox

    /// **The detector `SessionStore.inject` now gates on is per-agent.** Claude's rule-sandwich
    /// (see `ClaudeTextChannel.isComposerBox`) is not what codex draws at all, so codex's own
    /// presence check — reused from `composer(_:)` via `isComposerEmpty` above — has to keep
    /// answering for real codex screens once the shared activity gate is gone.
    func testARealIdleScreenHasAComposerBox() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        XCTAssertTrue(channel.hasComposerBox(injector))
    }

    func testARealWorkingScreenStillHasAComposerBox() throws {
        let injector = FakeInjector(viewport: try viewport("tui-working.captured"))
        XCTAssertTrue(channel.hasComposerBox(injector))
    }

    /// The same shell-prompt trap `isComposerEmpty` already refuses: `›` with no footer beneath
    /// it is not codex's composer, whichever question is asked of it.
    func testAShellPromptDrawingTheSameGlyphHasNoComposerBox() {
        let injector = FakeInjector(viewport: "› ls -la\n")
        XCTAssertFalse(channel.hasComposerBox(injector))
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

    // MARK: - submitRename
    //
    // Asserted against the Task 1 capture, `Fixtures/Codex/tui-rename-modal.captured.txt` —
    // verbatim output from a real codex 0.154.0 `/rename`. Nothing here describes a modal
    // anybody authored.

    /// The full two-stage happy path, typed in one exact sequence: `/rename`⏎ to open the
    /// modal, then the field-clearing `.killLine` (the fix for the prefill hazard — see
    /// `CodexTextChannel.submitRename`), then `<name>`⏎ to commit it. No draft restore at the
    /// end because the composer held only the placeholder.
    func testTheFullHappyPathTypesRenameThenClearsAndTypesTheName() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        injector.script([try viewport("tui-idle.captured"), try viewport("tui-rename-modal.captured")])
        var finished: Bool?
        XCTAssertTrue(channel.submitRename("new name", into: injector,
                                           settle: { $0() }, stillWanted: { true },
                                           onFinished: { finished = $0 }))
        XCTAssertEqual(injector.actions,
                       [.killLine, .text("/rename"), .return, .killLine, .text("new name"), .return],
                       "the second .killLine is the field-clearing step — losing it reopens the prefill hazard")
        XCTAssertEqual(finished, true)
    }

    /// The token-safety test. If `/rename` never actually opens a modal — a slow repaint, a
    /// version mismatch, anything — typing the name anyway would submit it to the model as a
    /// real prompt. The name must appear nowhere in what was sent, and the call escapes
    /// instead of pressing on.
    func testAMissingModalEscapesAndTypesNoName() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        injector.script([try viewport("tui-idle.captured")])   // never repaints into the modal
        var finished: Bool?
        XCTAssertTrue(channel.submitRename("should never be sent", into: injector,
                                           settle: { $0() }, stillWanted: { true },
                                           onFinished: { finished = $0 }))
        XCTAssertFalse(injector.actions.contains(.text("should never be sent")),
                       "no modal means the name must never reach the pty")
        XCTAssertTrue(injector.actions.contains(.escape))
        XCTAssertEqual(finished, false)
    }

    /// A real draft is restored only once the modal has committed the new name — never typed
    /// into the modal's own name field, which is the specific hazard that rules out reusing
    /// `submit` for this.
    func testARealDraftIsRestoredOnlyAfterTheModalCommits() throws {
        let draftScreen = """
        › half-written thought

          gpt-5.6-sol default · /tmp/work
        """
        let injector = FakeInjector(viewport: draftScreen)
        injector.script([draftScreen, try viewport("tui-rename-modal.captured")])
        var finished: Bool?
        XCTAssertTrue(channel.submitRename("new name", into: injector,
                                           settle: { $0() }, stillWanted: { true },
                                           onFinished: { finished = $0 }))
        XCTAssertEqual(injector.actions,
                       [.killLine, .text("/rename"), .return,
                        .killLine, .text("new name"), .return,
                        .text("half-written thought")],
                       "the restore is the LAST action — strictly after the modal's own Return")
        XCTAssertEqual(finished, true)
    }

    /// The request can be replaced or cancelled while codex repaints between the two stages —
    /// re-checked once, right after the first kill, exactly as `submit` does.
    func testACancelledRenameTypesNothingAfterTheKill() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        var finished: Bool?
        XCTAssertTrue(channel.submitRename("new name", into: injector,
                                           settle: { $0() }, stillWanted: { false },
                                           onFinished: { finished = $0 }))
        XCTAssertEqual(injector.actions, [.killLine],
                       "a request replaced while codex repainted must not be typed")
        XCTAssertEqual(finished, false)
    }

    /// `onFinished` is the one-shot guarantee `AgentRenameTyping` substitutes for `submit`'s
    /// one-shot `settle` — it must fire exactly once on every one of the three ways this call
    /// can end.
    func testOnFinishedRunsExactlyOnceOnSuccessAbortAndCancellation() throws {
        let success = FakeInjector(viewport: try viewport("tui-idle.captured"))
        success.script([try viewport("tui-idle.captured"), try viewport("tui-rename-modal.captured")])
        var successCount = 0
        _ = channel.submitRename("new name", into: success, settle: { $0() },
                                 stillWanted: { true }, onFinished: { _ in successCount += 1 })
        XCTAssertEqual(successCount, 1, "success must finish exactly once")

        let abort = FakeInjector(viewport: try viewport("tui-idle.captured"))
        abort.script([try viewport("tui-idle.captured")])   // no modal ever appears
        var abortCount = 0
        _ = channel.submitRename("new name", into: abort, settle: { $0() },
                                 stillWanted: { true }, onFinished: { _ in abortCount += 1 })
        XCTAssertEqual(abortCount, 1, "a refused modal must finish exactly once")

        let cancelled = FakeInjector(viewport: try viewport("tui-idle.captured"))
        var cancelledCount = 0
        _ = channel.submitRename("new name", into: cancelled, settle: { $0() },
                                 stillWanted: { false }, onFinished: { _ in cancelledCount += 1 })
        XCTAssertEqual(cancelledCount, 1, "a cancellation must finish exactly once")
    }

    /// A screen that draws the rename modal's marker glyph as its very last line, but not the
    /// modal's own title two rows above it — proof that the title check in
    /// `CodexTextChannel.renameModal` is load-bearing, not decorative. Without it, any repaint
    /// ending in a `▌`-prefixed line would be read as the open modal, and the name would be
    /// typed into whatever that line actually is.
    func testAScreenWithTheMarkerButNotTheModalTitleIsRefused() throws {
        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        injector.script([
            try viewport("tui-idle.captured"),
            """
            ▌ Not Rename Thread
            ▌
            ▌ some field value
            """,
        ])
        var finished: Bool?
        XCTAssertTrue(channel.submitRename("should never be sent", into: injector,
                                           settle: { $0() }, stillWanted: { true },
                                           onFinished: { finished = $0 }))
        XCTAssertFalse(injector.actions.contains(.text("should never be sent")),
                       "a screen that merely draws the marker must not be read as the modal")
        XCTAssertTrue(injector.actions.contains(.escape))
        XCTAssertEqual(finished, false)
    }

    /// Fix 2's regression test. `tui-rename-modal.captured.provenance.json` records the capture
    /// as 136x45 with per-line trailing whitespace stripped before it was committed — but other
    /// fixture batches in this repo are stored WITHOUT that stripping, so `readViewport()` can
    /// legitimately hand back a title row padded out to the full terminal width in production.
    /// Before Fix 2, the raw `==` in `CodexTextChannel.renameModal` would refuse this screen; the
    /// `trimmingCharacters` fix must accept it. The padding is computed here from the fixture
    /// that is actually committed, never checked in as a second, padded copy of it.
    func testAModalScreenPaddedToTheCaptureWidthIsStillRecognised() throws {
        let raw = try viewport("tui-rename-modal.captured")
        let capturedColumns = 136
        let padded = raw
            .components(separatedBy: "\n")
            .map { line -> String in
                guard line.count < capturedColumns else { return line }
                return line + String(repeating: " ", count: capturedColumns - line.count)
            }
            .joined(separator: "\n")

        let injector = FakeInjector(viewport: try viewport("tui-idle.captured"))
        injector.script([try viewport("tui-idle.captured"), padded])
        var finished: Bool?
        XCTAssertTrue(channel.submitRename("new name", into: injector,
                                           settle: { $0() }, stillWanted: { true },
                                           onFinished: { finished = $0 }))
        XCTAssertEqual(finished, true,
                       "trailing padding on the title row must not defeat the modal check")
    }

    // MARK: - Fixture

    private final class FakeInjector: TextInjecting {
        enum Action: Equatable {
            case killLine, yank, `return`, text(String), arrowDown, arrowUp, escape
        }

        private var viewport: String
        var viewportAfterKill: String?
        private(set) var actions: [Action] = []

        /// A verbatim screen sequence that advances on `sendReturn()`, modelling `codex
        /// resume` REPLACING the screen with each Return the way `SpyInjector.script(_:)`
        /// documents for claude — `/rename`⏎ opens the modal, `<name>`⏎ closes it, and each
        /// press is a repaint this fake must show. Off by default: most cases in this file
        /// are about `submit`, which never advances past one screen.
        private var scriptedScreens: [String] = []
        private var screenIndex = 0

        init(viewport: String) { self.viewport = viewport }

        /// Screens handed back in turn as `sendReturn()` is called — the first is what
        /// `readViewport()` returns until the first Return, the second from then on, and so
        /// on. Fewer Returns than screens, or more, both leave the last-reached screen in
        /// place rather than going out of bounds, which is what a real terminal does when
        /// nothing further repaints it.
        func script(_ screens: [String]) {
            scriptedScreens = screens
            screenIndex = 0
            if let first = screens.first { viewport = first }
        }

        func readViewport() -> String? { viewport }
        func sendText(_ text: String) { actions.append(.text(text)) }
        func sendReturn() {
            actions.append(.return)
            guard screenIndex + 1 < scriptedScreens.count else { return }
            screenIndex += 1
            viewport = scriptedScreens[screenIndex]
        }
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
