import XCTest
@testable import FlightDeck

/// Codex's approval lists, read off codex's own captured screens.
///
/// **What these fixtures are.** Five verbatim pyte renders of codex-cli 0.148.0 at 136x45,
/// recorded with their sha256s in `Fixtures/Codex/tui.captured.provenance.json`. Two of them
/// are the *same dialog one Down apart* — `approval-command` and `approval-command-row1` —
/// which is a state the claude set explicitly lacks, and the only fixture pair in the repo
/// that can tell "reads the marker" apart from "returns 0".
///
/// **What they do not establish, and these tests do not claim.**
///
/// - They were never cross-checked through the Accessibility API, unlike one of the claude
///   screens. So what is proved here is that this parser reads a **pyte** render of codex's
///   byte stream; that ghostty renders the same stream identically is established for
///   claude's screens only. See `CodexDialogDriver`'s doc for why the cheap version of that
///   cross-check does not exist as the provenance describes it.
/// - No narrow-width codex dialog was captured, so whether codex wraps a long label onto
///   continuation lines or elides it is unknown and `ChoiceDialog.Row.continuations` is
///   untested against codex. There is deliberately no test below pretending otherwise. The
///   interlock fails closed either way: an elided label never matches, so a narrow codex
///   dialog refuses rather than confirms.
/// - Only a *command* approval was provoked. A file-write/apply_patch approval may word its
///   rows differently and nothing here covers it.
@MainActor
final class CodexDialogDriverTests: XCTestCase {
    private let driver = CodexDialogDriver()
    private let claude = ClaudeDialogDriver()

    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Codex")
    }

    /// Verbatim from `approval-command.captured.txt`, backticks and trailing hint included.
    private let approvalLabels = [
        "1. Yes, proceed (y)",
        "2. Yes, and don't ask again for commands that start with "
            + "`mkdir -p /private/tmp/codexcap/work/newdir` (p)",
        "3. No, and tell Codex what to do differently (esc)",
    ].map { String($0.dropFirst(3)) }

    // MARK: - Where the cursor is

    func testTheCursorIsReadOffARealCodexApprovalDialog() throws {
        XCTAssertEqual(try driver.focusedRow(inViewport: captured("approval-command.captured")), 0)
        XCTAssertEqual(try driver.focusedRow(inViewport: captured("workspace-trust.captured")), 0)
    }

    /// **The fixture pair the claude set cannot produce.** `approval-command-row1` is
    /// `approval-command` after exactly one Down: the marker moved to row 2, the row it left
    /// reverted to two leading spaces, and there is still exactly one marker on screen.
    ///
    /// A driver that ignored the marker and returned a constant would pass every other
    /// cursor assertion in this repo. It cannot pass this one.
    func testAMovedCursorIsReadAsMovedRatherThanAsZero() throws {
        XCTAssertEqual(
            try driver.focusedRow(inViewport: captured("approval-command-row1.captured")), 1,
            "the correct answer on this screen is 1, and only reading the marker gives it"
        )
    }

    /// A codex session at rest and mid-turn draws no select list at all. Both screens carry
    /// the marker — `› Ask Codex to do anything` — so a rule keyed on the glyph alone would
    /// report a row on an idle terminal and drive arrows into a composer.
    func testAnOrdinaryCodexScreenIsNotADialog() throws {
        XCTAssertNil(try driver.focusedRow(inViewport: captured("tui-idle.captured")))
        XCTAssertNil(try driver.focusedRow(inViewport: captured("tui-working.captured")))
    }

    /// **The echoed-prompt trap, on a real codex screen.** `approval-command` carries the
    /// marker twice: once on the focused row and once on `› Run the shell command: …`, which
    /// codex echoes with no number. A row is the marker AND a number AND a consecutively
    /// numbered neighbour, so the echo is not a row and cannot head a list.
    func testTheEchoedPromptIsNotAReadableRow() throws {
        let screen = try captured("approval-command.captured")
        XCTAssertEqual(driver.focusedRow(inViewport: screen), 0,
                       "the echo must not be counted as row 0 with the real list below it")
        for index in 0..<4 {
            XCTAssertFalse(
                driver.row(index, reads: "Run the shell command: mkdir -p "
                           + "/private/tmp/codexcap/work/newdir && echo made. Use your shell "
                           + "tool to actually run it.", inViewport: screen),
                "the echoed prompt must confirm nothing, at any index"
            )
        }
    }

    // MARK: - What the row says

    func testEveryApprovalRowReadsAsItsOwnLabelAndNoOther() throws {
        let screen = try captured("approval-command.captured")
        for (index, label) in approvalLabels.enumerated() {
            XCTAssertTrue(driver.row(index, reads: label, inViewport: screen),
                          "row \(index) must read as \(label.prefix(24))…")
            for other in approvalLabels.indices where other != index {
                XCTAssertFalse(driver.row(other, reads: label, inViewport: screen),
                               "a label on the screen but not on THAT row is the interlock's "
                               + "whole job")
            }
        }
    }

    /// The list is three rows; a fourth is not there to confirm and must not trap.
    func testARowPastTheEndOfTheListConfirmsNothing() throws {
        let screen = try captured("approval-command.captured")
        XCTAssertFalse(driver.row(3, reads: approvalLabels[0], inViewport: screen))
    }

    func testTheTrustDialogsRowsRead() throws {
        let screen = try captured("workspace-trust.captured")
        XCTAssertTrue(driver.row(0, reads: "Yes, continue", inViewport: screen))
        XCTAssertTrue(driver.row(1, reads: "No, quit", inViewport: screen))
    }

    // MARK: - The marker is per-agent, and the two do not read each other's screens

    /// **`›` is U+203A and `❯` is U+276F**, and on screen they are indistinguishable — the
    /// provenance established the difference by codepoint dump, not by eye. A defaulted
    /// marker on `ChoiceDialog` would be claude's grammar quietly applied to this screen; the
    /// two halves below are what a default would have hidden.
    func testNeitherAgentsDriverReadsTheOthersScreens() throws {
        for name in ["approval-command.captured", "approval-command-row1.captured",
                     "workspace-trust.captured"] {
            XCTAssertNil(try claude.focusedRow(inViewport: captured(name)),
                         "claude's ❯ appears nowhere on \(name)")
        }
        for name in ["permission-bash.captured", "permission-write.captured",
                     "question-single.captured", "workspace-trust.captured"] {
            XCTAssertNil(
                try driver.focusedRow(inViewport: TimelineFixtureTests.text(name, in: "Claude")),
                "codex's › appears nowhere on claude's \(name)"
            )
        }
    }

    // MARK: - The two answers that are not shared

    /// **`allowRow` is codex's own, checked against codex's own screen.** The assertion that
    /// matters is not `== 0`; it is that the row that number selects says *"Yes, proceed"* on
    /// a captured dialog, and that the row beside it — the DURABLE GRANT — is a different one
    /// this feature can never reach.
    func testAllowRowIsThePlainApprovalAndNotTheDurableGrant() throws {
        let screen = try captured("approval-command.captured")
        XCTAssertTrue(driver.row(driver.allowRow, reads: "Yes, proceed (y)", inViewport: screen),
                      "allowRow must select the plain approval on a real codex dialog")
        XCTAssertTrue(
            driver.row(1, reads: approvalLabels[1], inViewport: screen),
            "row 1 is `Yes, and don't ask again …` — a durable grant, and the reason "
            + "AgentDialogDriver.allowRow has no default for an agent to inherit"
        )
        XCTAssertFalse(driver.row(driver.allowRow, reads: approvalLabels[1], inViewport: screen))
    }

    /// Deny reads nothing at all — no viewport, no marker, no row arithmetic — and codex's
    /// own footer says so: `Press enter to confirm or esc to cancel`.
    func testDenyIsOneEscapeAndReadsNothing() throws {
        let spy = SpyInjector()
        spy.viewportIsReadable = false
        driver.deny(spy)
        XCTAssertEqual(spy.events, [.escape])
    }

    /// The footer is on every captured approval, and it is what the line above cites.
    func testTheCapturedApprovalsFooterNamesEscape() throws {
        XCTAssertTrue(
            try captured("approval-command.captured")
                .contains("Press enter to confirm or esc to cancel")
        )
    }
}
