import Foundation
import IntakeKit

/// OpenCode's dialogs, as far as a screen can be trusted to say anything about them.
///
/// **This driver deliberately cannot locate a row, and the store never asks it to.** OpenCode
/// marks the focused option by colour alone — the captures carry `1. Yes` / `2. No` and the
/// permission buttons `Allow once   Allow always   Reject` with no glyph on the current one —
/// and `ghostty_surface_read_text` returns no colour. So `focusedRow` answers nil and
/// `row(_:reads:)` false, which makes every keystroke-counted answer refuse rather than guess.
/// That costs nothing: OpenCode's dialogs are answered by request id through
/// `OpenCodePromptResponder`, which `SessionStore.answerPrompt` consults first.
///
/// What it CAN do it does from captures: say that a select list is up, and refuse with one key.
struct OpenCodeDialogDriver: AgentDialogDriver {
    func focusedRow(inViewport viewport: String) -> Int? { nil }

    func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool { false }

    /// Either footer — a question's `↑↓ select  enter submit` or a permission's
    /// `⇆ select  enter confirm`.
    func hasSelectList(inViewport viewport: String) -> Bool {
        viewport.contains("↑↓ select") || viewport.contains("⇆ select")
    }

    /// "Allow once" is the first button, then the DURABLE grant "Allow always", then
    /// "Reject" — `permission-dialog.captured.txt`. Stated, not defaulted, for the reason
    /// `AgentDialogDriver.allowRow` gives; nothing reaches it while `focusedRow` is nil.
    let allowRow = 0

    /// One Escape. Live-probed on both dialogs: on a permission request it is a real refusal —
    /// OpenCode emitted `permission.replied` with `reply: "reject"` and ended the turn — and on
    /// a question it is the advertised `esc dismiss`.
    func deny(_ injector: TextInjecting) {
        injector.sendEscape()
    }
}
