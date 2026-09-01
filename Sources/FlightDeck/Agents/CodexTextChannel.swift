import Foundation

/// Codex's composer, typed into and submitted at the pty.
///
/// **Why this exists at all.** The app-server route to typing a turn is permanently closed —
/// a codex tab is a `codex resume` TUI holding the thread's writer lock, and `thread/resume`
/// answers `already has an active writer`. The pty route was never closed; it was unbuilt,
/// and the reason recorded for not building it turned out to be wrong. See the verdicts in
/// `Fixtures/Codex/tui.captured.provenance.json`: the shipped refusal said `InputBar` "locks
/// onto the last line starting `❯`, a glyph a plain shell prompt also draws", but codex draws
/// `›` (U+203A), so `InputBar` matched *nothing* on a codex screen. It could never have
/// confused codex's composer for a shell's — it could not find codex's composer at all.
///
/// Three facts from those captures shape everything below, and none of them is guessed:
///
/// 1. **The composer is a bare line, not a box.** `› Ask Codex to do anything`, followed by a
///    blank line and a status line. There is no border to key on.
/// 2. **A positive discriminator sits directly beneath it** — `gpt-5.6-sol default · <cwd>`,
///    model then mode then cwd — present in both the idle and working captures, and drawn by
///    no shell. That is what makes this safe on a tab sitting at a bare prompt.
/// 3. **The composer is byte-identical idle and mid-turn.** Codex keeps it up and accepting
///    during a turn, and the only busy signal is a separate `◦ Working (…)` line above. So
///    nothing here may infer "ready" from how the composer looks — and nothing does.
struct CodexTextChannel: AgentTextChannel {
    /// Codex's empty-composer placeholder, which is rendered in exactly the shape of a real
    /// draft and differs only in colour — which `ghostty_surface_read_text` does not return.
    /// Claude has the same hazard with a rotating hint; codex's is one fixed string, which is
    /// the only reason it can be named here at all.
    ///
    /// Matching an English literal is fragile, and it is deliberately not the last line of
    /// defence: `submit` below never trusts it, and instead kills and compares — the same
    /// measurement `InputBar`'s own doc comment prescribes. This constant only decides
    /// whether to *offer* to type, never whether it is safe to restore.
    static let placeholder = "Ask Codex to do anything"

    /// codex's status line — model, mode, cwd, separated by ` · ` — sitting DIRECTLY BELOW
    /// the composer, which is the only place it counts.
    ///
    /// **Position is the guard, not mere presence.** This is the single check standing between
    /// the user's words and a shell that happens to draw `›`, where those words would not be
    /// typed into a composer but RUN as a command. Scanning the whole screen for `" · "` would
    /// pass on any transcript that merely mentioned it — a listing, a path, a diff — so the
    /// window is pinned to the rows the real captures put it in: blank line, then footer,
    /// two below the marker in both `tui-idle` and `tui-working`. Three rows of slack, and
    /// no more.
    private func hasFooter(below start: Int, in lines: [String]) -> Bool {
        // Bounds first, THEN the range. `a...b` traps at construction when a > b, which is
        // every screen whose composer is the last line — a bare `› ls -la` at the bottom of a
        // shell, which is precisely the case this guard exists to reject.
        let lower = start + 1
        let upper = min(start + 3, lines.count - 1)
        guard lower <= upper else { return false }
        return lines[lower...upper].contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.contains(" · ") && !trimmed.hasPrefix(String(InputBar.codexMarker))
        }
    }

    private func composer(_ injector: TextInjecting) -> InputBar.Reading? {
        guard let viewport = injector.readViewport() else { return nil }
        let lines = viewport.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.first == InputBar.codexMarker }),
              hasFooter(below: start, in: lines),
              let bar = InputBar.read(fromViewport: viewport, marker: InputBar.codexMarker),
              // One row only, for the same reason as claude: a draft spanning rows cannot be
              // taken apart and put back a row at a time.
              bar.rows.count == 1
        else { return nil }
        return bar
    }

    func isComposerEmpty(_ injector: TextInjecting) -> Bool {
        guard let bar = composer(injector) else { return false }
        let content = bar.content.trimmingCharacters(in: .whitespaces)
        return content.isEmpty || content == Self.placeholder
    }

    /// **Restores the draft by re-typing it, not by yanking.**
    ///
    /// Claude's channel puts a killed draft back with Ctrl+Y, which works only because Claude
    /// Code keeps a deleted-text ring. Codex has never been shown to keep one, and that
    /// unknown is exactly what kept this unbuilt. It turns out not to matter: the draft is on
    /// screen before the kill, so it can be typed back from what was read rather than
    /// recovered from an editor feature codex may not have. That needs no ring, and it is
    /// verifiable from the screen either way.
    ///
    /// The ordering is claude's, and load-bearing for the same reasons: the kill happens
    /// before we know whether there was anything to kill, because comparing before and after
    /// is the only way to find out; and the restore happens after the Return, so a wrong
    /// guess can only leave text sitting in the composer, never submit it.
    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onSent: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let bar = composer(injector) else { return false }

        let before = bar.content
        injector.sendKillLine()
        settle {
            guard stillWanted() else { return }
            let after = self.composer(injector)?.content
            injector.sendText(text)
            injector.sendReturn()
            // Restore only on a CONFIRMED change, exactly as claude's channel does. An
            // unreadable screen means we do not know, and typing a remembered string into a
            // composer that may not have held it is worse than leaving the user one undo
            // away. A kill that changed nothing means the line was empty — or held only the
            // placeholder, which no kill can remove — so there is nothing to put back.
            if let after, after != before, before != Self.placeholder {
                injector.sendText(before)
            }
            onSent()
        }
        return true
    }
}
