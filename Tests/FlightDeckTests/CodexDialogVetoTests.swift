import XCTest
@testable import FlightDeck

/// `CodexTextChannel.isKnownNonComposer` — codex's half of the veto. See
/// `ClaudeDialogVetoTests` for the claude half and `AgentTextChannel.isKnownNonComposer` for
/// the shared rationale: this predicate is the only thing standing between an injection and a
/// dialog, because no hook announces one.
///
/// It exists at all because `AgentTextChannel` refuses protocol-extension defaults for
/// capability questions. A defaulted `false` would have read as "codex never raises a dialog"
/// — and codex raises three distinct ones, two of which claude's rule would miss outright:
/// its footers are lowercase and its marker is `›`, not `❯`.
///
/// Every capture here is verbatim pty output — see `Fixtures/Codex/tui.captured.provenance
/// .json` for the session this channel was built from.
@MainActor
final class CodexDialogVetoTests: XCTestCase {
    private func viewport(_ name: String) throws -> String {
        try TimelineFixtureTests.text("\(name).captured", in: "Codex")
    }

    /// `approval-command` and `approval-command-row1` carry `esc to cancel`; `tui-rename-modal`
    /// carries `esc to go back` instead. `workspace-trust` carries NEITHER — its footer is a
    /// bare `Press enter to continue` — so it is caught only by `hasNumberedMarkerRow`.
    private static let dialogs = [
        "approval-command", "approval-command-row1", "workspace-trust", "tui-rename-modal",
    ]

    /// `tui-idle` draws the SAME `›` marker a dialog does, for its composer's placeholder hint
    /// (`› Ask Codex to do anything`) — prose, never a digit-dot row. `tui-working` carries the
    /// busy line `esc to interrupt`, which must not collide with either dialog token.
    private static let composers = ["tui-idle", "tui-working"]

    func testEveryDialogCaptureVetoes() throws {
        for name in Self.dialogs {
            XCTAssertTrue(
                CodexTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) must veto — an injection here lands in a dialog"
            )
        }
    }

    func testNoComposerCaptureVetoes() throws {
        for name in Self.composers {
            XCTAssertFalse(
                CodexTextChannel.isKnownNonComposer(try viewport(name)),
                "\(name) is a composer — vetoing it would refuse legitimate injection"
            )
        }
    }

    /// `workspace-trust`'s prompt in isolation: neither dialog token appears anywhere in the
    /// screen, so it can only be caught by the marker-plus-numbered-row rule. Asserted
    /// separately so that rule stays proved even if a future codex build adds a footer token
    /// to this screen.
    func testWorkspaceTrustHasNeitherFooterToken() throws {
        let screen = try viewport("workspace-trust")
        for token in CodexTextChannel.dialogFooterTokens {
            XCTAssertFalse(screen.contains(token), "unexpectedly found \(token)")
        }
        XCTAssertTrue(CodexTextChannel.hasNumberedMarkerRow(screen))
    }

    /// The mirror of the assertion above, and the reason neither rule may be dropped for the
    /// other: `tui-rename-modal` draws no `›` at all — its own marker is
    /// `InputBar.renameModalMarker` — so only `esc to go back` catches it. Between the two,
    /// each rule is the sole defence for at least one real codex screen.
    func testTheRenameModalHasNoNumberedRowAtItsMarker() throws {
        let screen = try viewport("tui-rename-modal")
        XCTAssertFalse(CodexTextChannel.hasNumberedMarkerRow(screen))
        XCTAssertTrue(screen.contains("esc to go back"))
    }

    /// `tui-idle`'s own placeholder hint sits directly after codex's `›` marker and must never
    /// be mistaken for a numbered row — the case that makes this rule about position and
    /// shape, never about the marker's presence.
    func testIdleComposersMarkerIsNotMistakenForANumberedRow() throws {
        let screen = try viewport("tui-idle")
        XCTAssertFalse(CodexTextChannel.hasNumberedMarkerRow(screen))
    }

    /// Synthetic, not captured: the busy line reduced to the one token that matters. The real
    /// screen it stands for is `tui-working.captured.txt`, asserted in the loop above; this
    /// pins it on its own so that widening either token to a bare `esc to ` prefix fails here
    /// loudly rather than only as one entry in a two-name list.
    func testEscToInterruptIsNeitherDialogToken() {
        XCTAssertFalse(CodexTextChannel.isKnownNonComposer("  esc to interrupt\n"))
    }

    // MARK: - Through the injector

    func testIsKnownNonComposerReadsTheInjectorsViewport() throws {
        let injector = SpyInjector()
        injector.viewportOverride = try viewport("approval-command")
        XCTAssertTrue(CodexTextChannel().isKnownNonComposer(injector))
    }

    /// Unreadable screen means no veto, not a veto — the fail-open direction. A read failure
    /// that vetoed would look exactly like a dialog and silently drop the message.
    func testIsKnownNonComposerRefusesWhenTheScreenCannotBeRead() {
        let injector = SpyInjector()
        injector.viewportIsReadable = false
        XCTAssertFalse(CodexTextChannel().isKnownNonComposer(injector))
    }

    func testAnIdleComposerThroughTheInjectorDoesNotVeto() throws {
        let injector = SpyInjector()
        injector.viewportOverride = try viewport("tui-idle")
        XCTAssertFalse(CodexTextChannel().isKnownNonComposer(injector))
    }
}
