import Foundation

/// Codex's approval lists, read and driven.
///
/// **Every structural rule `ChoiceDialog` already had held against codex's screens
/// unmodified.** Checked against `Fixtures/Codex/approval-command.captured.txt`,
/// `approval-command-row1.captured.txt` and `workspace-trust.captured.txt` (codex-cli
/// 0.148.0): optional marker, then `N.`, then a space, then the label; contiguous numbering
/// from 1; a blank line ends the run; exactly one marker on screen, on the focused row, with
/// unfocused rows carrying two leading spaces and none. Codex fits the model more closely
/// than claude does — it draws no display-time extra rows below a closing rule.
///
/// **The echoed-prompt trap exists here too, and the existing defence is exactly right for
/// it.** Codex echoes the submitted prompt with the same `›` and no number (`› Run the shell
/// command: …` in `approval-command`), so a live session carries the marker twice. A row is
/// the marker AND a number AND a consecutively numbered neighbour, which rejects that echo
/// for the same reason it rejects claude's.
///
/// **One thing did differ, and it is one character.** Codex's marker is `›` (U+203A), not
/// claude's `❯` (U+276F) — which is why `ChoiceDialog.marker` became a parameter.
///
/// ## What these fixtures do NOT establish
///
/// - **They were never cross-checked through the Accessibility API**, unlike the claude set.
///   The provenance calls this the single most important gap and suggests it is cheap because
///   `accessibilityValue()` and `TextInjecting.readViewport()` return the same
///   `CachedValue<String>`. **They do not, in this build.** `accessibilityValue()` returns
///   `cachedScreenContents` (`SurfaceView_AppKit:2255`), built over `GHOSTTY_POINT_SCREEN` —
///   the whole scrollback — while `readViewport()` returns `cachedVisibleContents`
///   (`TextInjecting:128`), built over `GHOSTTY_POINT_VIEWPORT`. Two caches, two selections.
///   So the cross-check is a live-terminal exercise, not a comparison of one string, and it
///   remains open. What the tests below therefore prove is that this parser reads a **pyte**
///   render of codex's byte stream; that ghostty renders that same stream identically is
///   established for claude's screens only.
/// - **No narrow-width capture exists**, so whether codex wraps a long label onto
///   continuation lines (as claude does at 60 columns) or elides it with `…` is unknown, and
///   `ChoiceDialog.Row.continuations` is untested against codex. The interlock fails closed
///   either way — an elided label simply never matches — so a narrow codex dialog refuses
///   rather than confirms, which is the safe direction.
/// - **No file-write / apply_patch approval and no free-form question** were provoked. Only
///   a command approval is captured.
struct CodexDialogDriver: AgentDialogDriver {
    func focusedRow(inViewport viewport: String) -> Int? {
        ChoiceDialog.focusedRow(inViewport: viewport, marker: ChoiceDialog.codexMarker)
    }

    func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool {
        ChoiceDialog.row(index, reads: label, inViewport: viewport,
                         marker: ChoiceDialog.codexMarker)
    }

    /// **Codex's own answer, read off codex's own screen — not inherited.**
    ///
    /// `approval-command.captured.txt` reads, in order:
    ///
    /// ```text
    /// › 1. Yes, proceed (y)
    ///   2. Yes, and don't ask again for commands that start with `mkdir -p …` (p)
    ///   3. No, and tell Codex what to do differently (esc)
    /// ```
    ///
    /// So index 0 is the plain approval, index 1 is a **DURABLE GRANT**, and index 2 is deny.
    /// The number happens to match claude's, and that coincidence is exactly why
    /// `AgentDialogDriver.allowRow` has no default: an agent that inherited `0` without
    /// looking would be one reordered release away from granting "and don't ask again" from
    /// somebody's pocket, silently, with no label on screen to catch it.
    let allowRow = 0

    /// Escape, and codex's own footer says so — `Press enter to confirm or esc to cancel`,
    /// on every captured approval. The same one-key, reads-nothing path claude's deny takes,
    /// and the only answer that works on a screen this build cannot parse at all.
    func deny(_ injector: TextInjecting) { injector.sendEscape() }
}
