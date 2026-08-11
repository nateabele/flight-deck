import Foundation

/// Anything that can type into a live terminal. Mirrors the `SurfaceProvider`
/// seam so the Store stays testable without a real surface.
///
/// Text and Return are deliberately separate operations, because in libghostty they
/// travel different paths — see `sendReturn()`.
@MainActor
protocol TextInjecting: AnyObject {
    /// Insert literal text. This is a *paste*, not typing (see the extension below).
    func sendText(_ text: String)

    /// Press and release Return as a real key event.
    func sendReturn()
}

extension Ghostty.SurfaceView: TextInjecting {
    func sendText(_ text: String) {
        surfaceModel?.sendText(text)
    }

    /// Sends Return as a key event rather than as text, which is load-bearing.
    ///
    /// `sendText` is not "typing": `ghostty_surface_text` lands in `Surface.textCallback`,
    /// which calls `completeClipboardPaste` — a paste. When the running program has
    /// bracketed-paste mode (2004) enabled, as Claude Code does, `input/paste.zig` wraps the
    /// payload in `\u{1b}[200~ … \u{1b}[201~`. A full-screen TUI treats everything inside
    /// those markers as pasted *content*, so a `\r` in there is inserted as a literal
    /// newline and never submits — the command just sits in the input bar.
    ///
    /// Routing Return through `ghostty_surface_key` instead means it arrives after the paste
    /// has closed, as a genuine keypress that the program's key handler sees as submit.
    func sendReturn() {
        guard let surfaceModel else { return }
        surfaceModel.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
        surfaceModel.sendKeyEvent(.init(key: .enter, action: .release))
    }
}
