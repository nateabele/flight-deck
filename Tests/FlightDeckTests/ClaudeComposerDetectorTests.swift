import XCTest
@testable import FlightDeck

/// `ClaudeTextChannel.isComposerBox` — the gate `SessionStore.inject` now asks in place of the
/// status-file activity it used to consult. See that type's doc comment for the rule itself:
/// a `─` rule immediately above the `❯` marker line, AND the run it opens closed by another
/// rule rather than a blank line.
///
/// **Everything read through `captured(_:)` is a verbatim pty capture, not authored** — see
/// `Fixtures/Claude/dialogs.captured.provenance.json` and `MidTurnDraftTests`'s doc comment for
/// how they were taken. `authored(_:)` is this file's own construction, for the two shapes no
/// capture in the fixture set holds: a bare pre-boot shell prompt, and a dialog whose cursor has
/// been arrowed down onto its last, unruled row.
@MainActor
final class ClaudeComposerDetectorTests: XCTestCase {
    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Claude")
    }

    // MARK: - Real composer screens

    func testAnIdleEmptyBoxIsAComposer() throws {
        XCTAssertTrue(ClaudeTextChannel.isComposerBox(try captured("idle-empty-box.captured")))
    }

    /// The ordinary case while output streams: the box is on screen and empty, sandwiched by
    /// its two rules exactly as it is at rest.
    func testTheBoxWhileOutputStreamsIsAComposer() throws {
        XCTAssertTrue(
            ClaudeTextChannel.isComposerBox(try captured("busy-streaming-no-box.captured"))
        )
    }

    /// **Same shape as `busy-streaming-no-box`, and deliberately not exempted.** This capture's
    /// own name suggests "no marker box", but every byte says otherwise: a `❯` sits alone on its
    /// line, with a rule immediately above it and another immediately below —
    /// `MidTurnDraftTests.testTheBoxStaysOnScreenAndEmptyWhileOutputStreams` already reads both
    /// fixtures as identical one-row empty boxes, and treating this one as "not a composer"
    /// would defeat the point of gating on the screen at all: it is one of the two ordinary
    /// mid-turn streaming screens the whole task exists to keep injectable.
    func testTheStreamingScreenNamedNoMarkerIsStillAComposer() throws {
        XCTAssertTrue(
            ClaudeTextChannel.isComposerBox(try captured("busy-streaming-no-marker.captured"))
        )
    }

    /// The rotating placeholder hint (`Press up to edit queued messages`) is a real composer
    /// with text painted into it, not a draft — `isComposerEmpty` is what tells those apart.
    /// This gate only asks whether the box itself is there, and it is.
    func testTheQueuedMessagesHintBoxIsAComposer() throws {
        XCTAssertTrue(ClaudeTextChannel.isComposerBox(try captured("busy-queued-message.captured")))
    }

    /// **A titled top border is still a composer.** Live production capture, 2026-09-17: a
    /// Claude Code build newer than every pinned fixture here (banner read "Update installed
    /// · Restart to update") draws the tab's own title into the rule directly above the
    /// marker — `──…── New Phone Sessions ─` instead of a bare run of `─` — which made
    /// `hasComposerBox` reject a screen that was a completely ordinary, empty, present
    /// composer. Authored from `idle-empty-box.captured` with only that one line changed, the
    /// same way `testTheLastUnruledRowOfADialogListIsNotAComposer` derives its authored shape.
    func testATitledTopBorderIsStillAComposer() throws {
        // Line-indexed, not `replacingOccurrences`: the fixture's two rules are byte-identical,
        // and only the one directly above the marker (index 5, the sixth line) gets a title —
        // the closing rule below stays plain, matching the real capture exactly.
        var lines = try captured("idle-empty-box.captured").components(separatedBy: "\n")
        let plainRule = lines[5]
        XCTAssertTrue(InputBar.isRule(plainRule), "fixture line 6 must be the top rule")
        lines[5] = String(plainRule.dropLast(" New Phone Sessions ─".count)) + " New Phone Sessions ─"
        XCTAssertTrue(ClaudeTextChannel.isComposerBox(lines.joined(separator: "\n")))
    }

    // MARK: - The moment after submitting, before output arrives

    /// **The one mid-turn window the gate does refuse, and correctly.** The box holds the
    /// echoed prompt that just submitted, closed by a blank line rather than a rule — the run
    /// scrolls straight into the transcript above it, with no footer rule beneath. It is brief:
    /// `flushPromptQueue` retries on the next registry tick.
    func testTheEchoOnlyScreenRightAfterSubmittingIsNotAComposer() throws {
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(try captured("busy-echo-only.captured")))
    }

    // MARK: - Dialogs: draw one rule at most, never both

    func testAPermissionPromptIsNotAComposer() throws {
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(try captured("permission-bash.captured")))
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(try captured("permission-write.captured")))
    }

    func testAWorkspaceTrustPromptIsNotAComposer() throws {
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(try captured("workspace-trust.captured")))
    }

    func testAnAskUserQuestionPromptIsNotAComposer() throws {
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(try captured("question-single.captured")))
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(try captured("question-two.captured")))
        XCTAssertFalse(
            ClaudeTextChannel.isComposerBox(try captured("question-checkbox.captured"))
        )
    }

    /// **The row `AskUserQuestion` draws its own `❯` on that a real composer never does**, and
    /// the reason both halves of the rule are required. The list's closing rule sits directly
    /// above this row, so "a rule immediately above the marker" alone would pass it; nothing
    /// closes the run *below* it but a blank line, which is what actually refuses it.
    ///
    /// No capture in the fixture set holds the cursor on this exact row, so this is `question-
    /// single.captured` with the marker moved by hand from "1. Rust" onto "5. Chat about this" —
    /// the shape a real arrow-down drive reaches, not a screen this file invented from nothing.
    func testTheLastUnruledRowOfADialogListIsNotAComposer() throws {
        var screen = try captured("question-single.captured")
        screen = screen.replacingOccurrences(of: "❯ 1. Rust", with: "  1. Rust")
        screen = screen.replacingOccurrences(of: "  5. Chat about this", with: "❯ 5. Chat about this")
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(screen))
    }

    // MARK: - A pre-boot shell prompt

    /// The screen `openSignInSession` and a restore's queued "Keep going" both have to refuse:
    /// a bare shell that has not started claude yet draws its own prompt marker, but neither
    /// rule a real composer does. Authored rather than captured — this is a `starship`-style
    /// shell prompt, not a claude screen at all.
    func testABareShellPromptIsNotAComposer() {
        let screen = "~/Projects/flight-deck on \u{1B}[35m main\u{1B}[0m\n❯ "
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(screen))
    }

    // MARK: - hasComposerBox, through the injector

    func testHasComposerBoxReadsTheInjectorsViewport() throws {
        let injector = SpyInjector()
        injector.viewportOverride = try captured("idle-empty-box.captured")
        XCTAssertTrue(ClaudeTextChannel().hasComposerBox(injector))
    }

    func testHasComposerBoxRefusesWhenTheScreenCannotBeRead() {
        let injector = SpyInjector()
        injector.viewportIsReadable = false
        XCTAssertFalse(ClaudeTextChannel().hasComposerBox(injector))
    }

    /// **Claude-only, the other direction.** `AgentTextChannel.hasComposerBox` is answered per
    /// agent so `SessionStore.inject` never has to know either one's screen grammar — a codex
    /// screen run through claude's detector must find nothing, exactly as a codex marker finds
    /// nothing in `InputBar.read` (see `CodexTextChannelTests.testClaudesMarkerFindsNothingOnACodexScreen`).
    func testAClaudeDetectorFindsNoComposerOnARealCodexScreen() throws {
        let screen = try TimelineFixtureTests.text("tui-idle.captured", in: "Codex")
        XCTAssertFalse(ClaudeTextChannel.isComposerBox(screen))
    }
}
