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
    /// Claude Code's own deleted-text ring, from where `sendYank()` can restore it — this is
    /// the effect under the legacy keyboard encoding, where these two calls put the literal
    /// control bytes on the wire. Claude Code runs with the kitty keyboard protocol enabled,
    /// under which `sendControl` (below) sends `ESC[101;5u` / `ESC[117;5u` instead — see its
    /// comment for why. Whether Claude's composer honors that form as Ctrl+E/Ctrl+U is not
    /// yet confirmed; see docs/HANDOFF-agent-surface-findings.md §4 and the matching
    /// docs/FOLLOWUPS.md entry. If it does not, the box never clears and the next `sendText`
    /// is appended to the surviving draft instead of replacing it.
    ///
    /// Ctrl+E first is load-bearing on the legacy path — Ctrl+U deletes from the cursor to
    /// the line *start*, so without it a draft's tail survives and the injected command is
    /// spliced into the middle of it. On an empty line the pair is a no-op and pushes nothing
    /// onto the ring.
    func sendKillLine()

    /// Ctrl+Y: paste back the most recently killed text.
    func sendYank()

    /// Move a full-screen TUI's option list down one row, as a real key event.
    ///
    /// A key event and not text, for exactly the reason `sendReturn()` is one: `sendText` is a
    /// paste, ghostty wraps a paste in bracketed-paste markers, and an escape sequence inside
    /// those markers is inserted as literal *content* rather than acted on. An arrow written
    /// as `ESC [ B` through `sendText` would put five visible characters into a dialog.
    func sendArrowDown()

    /// The same, upwards. Both directions exist because a list's cursor can start below the
    /// target — Claude Code focuses a "(Recommended)" option when it has one — so a driver
    /// that could only go down would wrap or stall.
    func sendArrowUp()

    /// Escape: refuse the dialog outright.
    ///
    /// **This is the whole delivery mechanism for a denial, and it reads nothing.** No
    /// viewport parse, no marker, no row arithmetic, no confirmation pass — one key event.
    /// It is the path a worried person reaches for from a pocket, and it is deliberately the
    /// one path in this feature that cannot be wrong about which row it is on, because it is
    /// not on a row. See `PromptAnswer.deny`.
    func sendEscape()

    /// The terminal's visible screen, or nil when it cannot be read. Plain text only —
    /// libghostty exposes no cell attributes, which is why `InputBar` cannot tell a
    /// placeholder hint from a real draft.
    func readViewport() -> String?
}

extension Ghostty.SurfaceView: TextInjecting {
    func sendText(_ text: String) {
        surfaceModel?.sendText(text)
        screenChanged()
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
        screenChanged()
    }

    func sendKillLine() {
        sendControl(.e, byte: "\u{05}")
        sendControl(.u, byte: "\u{15}")
    }

    func sendYank() {
        sendControl(.y, byte: "\u{19}")
    }

    func sendArrowDown() { sendBareKey(.arrowDown) }
    func sendArrowUp() { sendBareKey(.arrowUp) }
    func sendEscape() { sendBareKey(.escape) }

    /// No `text:`, deliberately: none of these has a textual form, and ghostty's own key
    /// encoder is what turns the keycode into whatever the running program expects — which
    /// differs by keyboard protocol and is not this file's business to reproduce. Contrast
    /// `sendControl`, which states its byte because there the mapping is the thing worth
    /// reading beside the key.
    ///
    /// Press *and* release, matching `sendReturn` and `sendControl` — and the release is
    /// stated to be redundant rather than left looking load-bearing. It was measured: a build
    /// sending only `.press` moved a real claude permission dialog on a real surface exactly
    /// as the pair does, because libghostty encodes on press under the legacy keyboard
    /// protocol. It stays because the Kitty keyboard protocol lets a program subscribe to
    /// release events too, and such a program is entitled to sit waiting for the other half
    /// of a keystroke that never arrives.
    ///
    /// **No test can catch its removal.** Nothing under XCTest stands on a real surface, so
    /// deleting the second line breaks nothing in the suite and would be noticed only against
    /// a running terminal.
    private func sendBareKey(_ key: Ghostty.Input.Key) {
        guard let surfaceModel else { return }
        surfaceModel.sendKeyEvent(.init(key: key, action: .press))
        surfaceModel.sendKeyEvent(.init(key: key, action: .release))
        screenChanged()
    }

    /// Control keys go the same route as Return, and for the same reason — a control byte
    /// inside a bracketed paste is inserted as content, not acted on.
    ///
    /// `byte` is only honored under the legacy keyboard encoding — it is not "what the
    /// terminal must actually receive" in general. Under the kitty keyboard protocol, which
    /// Claude Code enables, ghostty's encoder never looks at it: traced through
    /// `vendor/ghostty/src/input/key_encode.zig` for `.u`, a non-functional key finds its
    /// entry via `unshifted_codepoint` (`{code: 117, final: 'u'}`); the utf8 short-circuit is
    /// `.enter`/`.backspace`-only so it doesn't fire; `plain_text` requires empty mods and
    /// ctrl is set here, so that's skipped too; and the `orelse` fallback that would write
    /// `event.utf8` (i.e. `byte`) is unreachable because an entry was found. It falls through
    /// to `KittySequence` and goes out built from `key` + `mods` alone — Ctrl+U as
    /// `ESC[117;5u`, discarding `byte` entirely. `byte` is kept as a parameter because it is
    /// the real payload on the legacy path, and writing it beside the key documents that
    /// mapping for a reader who has not traced the encoder. Full derivation:
    /// docs/HANDOFF-agent-surface-findings.md §4.
    private func sendControl(_ key: Ghostty.Input.Key, byte: String) {
        guard let surfaceModel else { return }
        surfaceModel.sendKeyEvent(.init(key: key, action: .press, text: byte, mods: .ctrl))
        surfaceModel.sendKeyEvent(.init(key: key, action: .release, mods: .ctrl))
        screenChanged()
    }

    /// Every send above ends here, and it is what makes reading the screen back honest.
    ///
    /// The cache `readViewport()` is served from holds a screen for 500ms, while a driver
    /// waits 120ms for the repaint before looking again (`SessionStore.injectionSettle`).
    /// Without this the read after a keystroke can be answered from *before* that keystroke:
    /// the answer drive then sees the cursor still on the row it started from, decides the key
    /// never landed and abandons the dialog half-answered — intermittently, because whether it
    /// happens depends on where the press fell in the cache's lifetime. Dropping the entry at
    /// the point the screen is known to have changed makes the next read fetch, and leaves the
    /// cache doing its job for the pollers that never touch the keyboard (`ClaudeTextChannel`,
    /// `SessionStore.viewport(of:)`).
    ///
    /// **No test can catch its removal**, for the same reason `sendBareKey`'s release cannot:
    /// nothing under XCTest stands on a real surface, so this whole extension is unreachable
    /// there. What the suite pins instead is the primitive and the shape — `CachedValue`
    /// really re-fetches after `invalidate()`, and a drive against a fake cache that is only
    /// cleared this way completes rather than aborting. See `ViewportFreshnessTests`.
    private func screenChanged() {
        cachedVisibleContents.invalidate()
    }

    /// The screen ghostty already keeps for accessibility, reused rather than re-read: it is
    /// cached for 500 ms, which is well inside the cadence a rename needs — and dropped by
    /// `screenChanged()` the moment this injector types, which is what a read-back needs.
    func readViewport() -> String? {
        cachedVisibleContents.get()
    }
}
