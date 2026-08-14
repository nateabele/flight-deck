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

    /// Ctrl+E then Ctrl+U: move to the end of the current logical line and kill it into
    /// Claude Code's own deleted-text ring, from where `sendYank()` can restore it.
    ///
    /// Ctrl+E first is load-bearing — Ctrl+U deletes from the cursor to the line *start*,
    /// so without it a draft's tail survives and the injected command is spliced into the
    /// middle of it. On an empty line the pair is a no-op and pushes nothing onto the ring.
    func sendKillLine()

    /// Ctrl+Y: paste back the most recently killed text.
    func sendYank()

    /// The terminal's visible screen, or nil when it cannot be read. Plain text only —
    /// libghostty exposes no cell attributes, which is why `InputBar` cannot tell a
    /// placeholder hint from a real draft.
    func readViewport() -> String?
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

    func sendKillLine() {
        sendControl(.e, byte: "\u{05}")
        sendControl(.u, byte: "\u{15}")
    }

    func sendYank() {
        sendControl(.y, byte: "\u{19}")
    }

    /// Control keys go the same route as Return, and for the same reason — a control byte
    /// inside a bracketed paste is inserted as content, not acted on.
    ///
    /// The encoded byte is passed as `text` rather than left to the key encoder to derive
    /// from key+modifier: it is what the terminal must actually receive, and stating it
    /// here keeps the mapping visible next to the key it belongs to.
    private func sendControl(_ key: Ghostty.Input.Key, byte: String) {
        guard let surfaceModel else { return }
        surfaceModel.sendKeyEvent(.init(key: key, action: .press, text: byte, mods: .ctrl))
        surfaceModel.sendKeyEvent(.init(key: key, action: .release, mods: .ctrl))
    }

    /// The screen ghostty already keeps for accessibility, reused rather than re-read: it
    /// is cached for 500 ms, which is well inside the cadence a rename needs.
    func readViewport() -> String? {
        cachedVisibleContents.get()
    }
}
