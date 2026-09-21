import XCTest
@testable import FlightDeck

/// `ClaudeTextChannel.isKnownNonComposer` — the veto is the ONLY thing standing between an
/// injection and a dialog. See `AgentTextChannel.isKnownNonComposer`'s doc comment: hook
/// lifecycle events answer "is this session booted and alive", never "what is on screen",
/// denying a permission prompt with Esc fires no hook at all, and claude raises select-list
/// dialogs of its own right after `Stop`. So this corpus is load-bearing, not illustrative —
/// a dialog capture this misses is a dialog Flight Deck will type into.
///
/// **Every named capture here is verbatim pty output** — see
/// `Fixtures/Claude/dialogs.captured.provenance.json`, whose whole premise is that lines may
/// be dropped but never edited. The two screens that are *not* captures are string literals
/// in this file, labelled where they appear, so nothing hand-authored can ever be mistaken
/// for a capture.
@MainActor
final class ClaudeDialogVetoTests: XCTestCase {
    private func viewport(_ name: String) throws -> String {
        try TimelineFixtureTests.text("\(name).captured", in: "Claude")
    }

    /// Fourteen of these fifteen carry `Esc to cancel`. `question-two-review` does not — its
    /// footer is `❯ 1. Submit answers` / `  2. Cancel`, caught only by the
    /// marker-plus-numbered-row rule. See `ClaudeTextChannel.hasNumberedMarkerRow`.
    private static let dialogs = [
        "permission-bash", "permission-write", "permission-write-60col", "permission-write-row2",
        "question-single", "question-single-247", "question-two", "question-two-answered",
        "question-two-review", "question-multi", "question-checkbox", "question-checkbox-toggled",
        "question-checkbox-submit-focused", "question-set-with-checkbox",
        "workspace-trust",
    ]

    private static let composers = [
        "idle-empty-box", "busy-echo-only", "busy-draft-below-echo",
        "busy-queued-message", "busy-streaming-no-box", "busy-streaming-no-marker",
    ]

    func testEveryDialogCaptureVetoes() throws {
        for name in Self.dialogs {
            XCTAssertTrue(
                ClaudeTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) must veto — an injection here lands in a dialog"
            )
        }
    }

    /// The whole point of allowing mid-turn injection is that claude queues it. A running
    /// turn shows `esc to interrupt`, which must not be confused with `Esc to cancel`, and none
    /// of these six carries a numbered row after its marker either.
    func testNoComposerCaptureVetoes() throws {
        for name in Self.composers {
            XCTAssertFalse(
                ClaudeTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) is a composer — vetoing it would refuse legitimate injection"
            )
        }
    }

    /// `question-two-review`'s confirmation step in isolation: no `Esc to cancel` anywhere in
    /// the screen, so it can only be caught by `hasNumberedMarkerRow`. Asserted separately
    /// because the loop above would still pass if the token rule started matching it for some
    /// unrelated reason, leaving the row rule untested by the corpus.
    func testTheReviewStepHasNoEscToCancelToken() throws {
        let screen = try viewport("question-two-review")
        XCTAssertFalse(screen.contains(ClaudeTextChannel.dialogFooterToken))
        XCTAssertTrue(ClaudeTextChannel.hasNumberedMarkerRow(screen))
    }

    /// A queued message's own echoed `❯` line, and the hint box's `❯` line beneath it, are
    /// both followed by prose — never a digit-dot row — so the marker-plus-numbered-row rule
    /// must not fire on either just because the screen happens to hold digits elsewhere (the
    /// truncated `⏺ 1. one` / `49. fern` / `50.` list sits under a DIFFERENT marker, `⏺`).
    func testAQueuedMessageWithNearbyDigitsDoesNotVeto() throws {
        let screen = try viewport("busy-queued-message")
        XCTAssertFalse(ClaudeTextChannel.hasNumberedMarkerRow(screen))
    }

    // MARK: - Screens written from observation, not captured

    /// **Authored from observation, NOT a fixture**, and deliberately not one: everything in
    /// `Fixtures/Claude/` is verbatim pty output under a checksum guard, so a hand-typed file
    /// in there would be a lie about its own provenance.
    ///
    /// This is the unprompted dialog claude raises right after `Stop`, seen on a PTY probe on
    /// 2026-09-19 — the screen that motivated this veto existing at all, because no hook
    /// announces it and the session looks idle underneath it. Transcribed from that probe by
    /// hand and therefore approximate in its spacing, which is why it proves nothing the
    /// captures do not: it carries BOTH recognised shapes. It is here to document *why* the
    /// veto exists, next to the corpus that proves *how* it decides.
    private static let unpromptedNudge = """
          Teach auto mode about your environment?

          Auto mode works better when it knows your environment. Takes about a minute.

        ❯ 1. Yes
          2. Not now
          3. Don't show again

          Enter to confirm · Esc to cancel
        """

    func testTheUnpromptedAutoModeNudgeVetoes() {
        XCTAssertTrue(ClaudeTextChannel.isKnownNonComposer(Self.unpromptedNudge))
        // Both shapes, stated separately so a regression in either is legible here.
        XCTAssertTrue(Self.unpromptedNudge.contains(ClaudeTextChannel.dialogFooterToken))
        XCTAssertTrue(ClaudeTextChannel.hasNumberedMarkerRow(Self.unpromptedNudge))
    }

    /// Synthetic, not captured: the busy line reduced to the one token that matters. The real
    /// screen it stands for is `busy-streaming-no-box.captured.txt`, asserted in the loop
    /// above; this pins the case-sensitivity on its own so that lowercasing the comparison
    /// fails here loudly rather than only as one entry in a six-name list.
    func testEscToInterruptIsNotEscToCancel() {
        XCTAssertFalse(ClaudeTextChannel.isKnownNonComposer("  esc to interrupt\n"))
    }

    // MARK: - Through the injector

    func testIsKnownNonComposerReadsTheInjectorsViewport() throws {
        let injector = SpyInjector()
        injector.viewportOverride = try viewport("permission-bash")
        XCTAssertTrue(ClaudeTextChannel().isKnownNonComposer(injector))
    }

    /// Unreadable screen means no veto, not a veto — the fail-open direction. A read failure
    /// that vetoed would look exactly like a dialog and silently drop the message.
    func testIsKnownNonComposerRefusesWhenTheScreenCannotBeRead() {
        let injector = SpyInjector()
        injector.viewportIsReadable = false
        XCTAssertFalse(ClaudeTextChannel().isKnownNonComposer(injector))
    }

    func testAnIdleComposerThroughTheInjectorDoesNotVeto() throws {
        let injector = SpyInjector()
        injector.viewportOverride = try viewport("idle-empty-box")
        XCTAssertFalse(ClaudeTextChannel().isKnownNonComposer(injector))
    }
}
