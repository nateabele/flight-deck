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

    /// Twenty-one of these twenty-three carry `Esc to cancel`. The two review screens,
    /// `question-two-review` and `question-typed-checkbox-review`, do not — their footer is
    /// `❯ 1. Submit answers` / `  2. Cancel`, caught only by the marker-plus-numbered-row rule. See `ClaudeTextChannel.hasNumberedMarkerRow`.
    ///
    /// **Internal rather than private** so `ClaudeComposerDetectorTests` can hold the *other*
    /// predicate to the same twenty-three screens — see its `testEveryDialogCaptureIsRefused`. One
    /// hand-written list, asserted twice: a dialog added here is covered by both gates at once,
    /// which is the whole reason the list is shared instead of copied.
    static let dialogs = [
        "permission-bash", "permission-write", "permission-write-60col", "permission-write-row2",
        "question-single", "question-single-247", "question-two", "question-two-answered",
        "question-two-review", "question-multi", "question-checkbox", "question-checkbox-toggled",
        "question-checkbox-submit-focused", "question-set-with-checkbox",
        "question-numbered-description", "question-preview",
        "workspace-trust",
        // claude 2.1.289, the "Type something" row — `typed-answers.captured.provenance.json`.
        "question-typed-focused", "question-typed-single", "question-typed-set",
        "question-typed-checkbox", "question-typed-checkbox-submit-focused",
        "question-typed-checkbox-review",
    ]

    private static let composers = [
        "idle-empty-box", "busy-echo-only", "busy-draft-below-echo",
        "busy-queued-message", "busy-streaming-no-box", "busy-streaming-no-marker",
        // A lone question's answer just committed: the turn resumes with an empty box.
        "question-typed-single-committed", "question-single-committed-no-review",
    ]

    /// **Every `*.captured.txt` in `Fixtures/Claude` must appear in one of the two lists
    /// above.** The lists are hand-written, so without this a capture added by a later task is
    /// classified by nobody and asserted by nothing — it simply does not appear, which reads
    /// exactly like passing. The corpus IS the proof for this predicate, so a screen nobody
    /// has decided about is a hole in it, not a neutral addition.
    func testTheCorpusSplitCoversEveryCapture() throws {
        let classified = Set(Self.dialogs + Self.composers)
        XCTAssertEqual(
            classified.count, Self.dialogs.count + Self.composers.count,
            "a name is listed as both a dialog and a composer"
        )
        let onDisk = try Self.capturedNames(in: "Claude")
        XCTAssertEqual(
            onDisk.subtracting(classified).sorted(), [],
            "unclassified capture — decide whether it is a dialog or a composer and list it"
        )
        XCTAssertEqual(
            classified.subtracting(onDisk).sorted(), [],
            "listed capture that is no longer in Fixtures/Claude"
        )
    }

    /// The `*.captured.txt` basenames the test bundle actually holds for `directory`, with both
    /// extensions taken off so they read as the names the lists above use. Bundle-based rather
    /// than a filesystem path because `Fixtures/` is a copied folder reference — what shipped
    /// into the bundle is the only listing that can disagree with the lists.
    static func capturedNames(in directory: String) throws -> Set<String> {
        let urls = try XCTUnwrap(
            Bundle(for: ClaudeDialogVetoTests.self).urls(
                forResourcesWithExtension: "txt", subdirectory: "Fixtures/\(directory)"
            ),
            "Fixtures/\(directory) holds no .txt resources — did it reach the test bundle?"
        )
        return Set(
            urls.map { $0.deletingPathExtension().lastPathComponent }
                .filter { $0.hasSuffix(".captured") }
                .map { String($0.dropLast(".captured".count)) }
        )
    }

    func testEveryDialogCaptureVetoes() throws {
        for name in Self.dialogs {
            XCTAssertTrue(
                ClaudeTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) must veto — an injection here lands in a dialog"
            )
        }
    }

    /// The whole point of allowing mid-turn injection is that claude queues it, so the three
    /// `busy-*` screens must pass as readily as the idle one. None of the six carries
    /// `Esc to cancel` in any casing, and none puts a numbered row at its `❯`.
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

    /// The mirror of the assertion above, and the reason neither rule may be dropped for the
    /// other: `question-checkbox-submit-focused` puts the marker on the UNNUMBERED action row
    /// (`❯    Submit`), so no numbered row sits at its marker and only the footer token catches
    /// it. Between the two, each rule is the sole defence for at least one real screen.
    func testTheSubmitFocusedCheckboxScreenHasNoNumberedRowAtItsMarker() throws {
        let screen = try viewport("question-checkbox-submit-focused")
        XCTAssertFalse(ClaudeTextChannel.hasNumberedMarkerRow(screen))
        XCTAssertTrue(screen.contains(ClaudeTextChannel.dialogFooterToken))
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

    /// Synthetic, and **it stands for no claude capture** — no screen in `Fixtures/Claude`
    /// carries `esc to interrupt` at all; codex's `tui-working` is the corpus's only
    /// occurrence. It is here so both channels are held to the same invariant rather than
    /// letting claude's drift: **a screen whose only esc-text is an interrupt hint must not
    /// veto**, because a running turn is exactly when injection must stay allowed, claude
    /// queueing what it receives. Codex's twin, `testEscToInterruptIsNeitherDialogToken`,
    /// pins it against a real capture.
    ///
    /// **What it does NOT pin, stated so the next reader does not assume otherwise:
    /// case-sensitivity.** Lowercasing both sides of the comparison leaves this green, because
    /// `esc to interrupt` does not contain `esc to cancel` at any casing. Nor does any capture
    /// pin it — the phrase appears only in the fifteen dialog footers. The comment here
    /// previously claimed this test guarded that; it did not, and that claim is the same
    /// defect class as the dead position check removed in `0744a9e`.
    func testEscToInterruptDoesNotMatchTheFooterToken() {
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
