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
struct CodexTextChannel: AgentTextChannel, AgentRenameTyping {
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

    /// Reads codex's `/rename` modal off screen, or nil when it is not up.
    ///
    /// **Keys on the title, not on the glyph alone** — mirroring `hasFooter`'s own "position
    /// is the guard, not mere presence" idiom above. The modal's footer, `Press enter to
    /// confirm or esc to go back`, is one word away from `approval-command.captured.txt`'s
    /// `Press enter to confirm or esc to cancel`, so a footer-only check cannot tell the two
    /// dialogs apart; the title, `▌ Rename thread`, is unique to this one and is what this
    /// checks. The footer is real corroboration codex draws, but this reader does not need it
    /// to be certain, so it is not re-checked here.
    ///
    /// `InputBar.renameModalMarker`'s own doc explains why `InputBar.read` — unchanged —
    /// lands on the INPUT row rather than the title: `lastIndex(where:)` finds the *last*
    /// `▌`-prefixed line, and the modal draws three (title, a bare rule, then the input row).
    /// That single call both proves the modal is up (non-nil) and returns what the field
    /// already holds, which `submitRename` needs before it clears that field.
    private func renameModal(_ injector: TextInjecting) -> InputBar.Reading? {
        guard let viewport = injector.readViewport() else { return nil }
        let lines = viewport.components(separatedBy: "\n")
        guard let inputRow = lines.lastIndex(where: { $0.first == InputBar.renameModalMarker }),
              inputRow >= 2,
              lines[inputRow - 2].trimmingCharacters(in: .whitespaces) == "▌ Rename thread",
              let bar = InputBar.read(fromViewport: viewport, marker: InputBar.renameModalMarker),
              // Same one-row rule as `composer(_:)`: a field spanning rows cannot be taken
              // apart and put back a row at a time.
              bar.rows.count == 1
        else { return nil }
        return bar
    }

    /// Types the killed draft back, unless there was nothing real to restore. Shared by two of
    /// `submitRename`'s THREE exit paths — a refused modal and a committed one — because the
    /// draft is the same thing to protect either way, and the emptiness check is the same
    /// `isComposerEmpty` already uses: an empty box or the placeholder means there is nothing
    /// to put back.
    ///
    /// **The third path — cancellation — deliberately does not call this, and the draft is
    /// then simply gone.** `submitRename` kills the composer unconditionally before its first
    /// settle, because comparing before and after is the only way to learn whether anything
    /// was there; so by the time `stillWanted()` reads false, a real draft has already been
    /// destroyed and nothing types it back. The retry cannot recover it either — it re-reads
    /// the now-empty composer, so its own `before` is empty. Recorded here as known and
    /// intentional rather than left to look like an oversight.
    ///
    /// `ClaudeTextChannel.submit` also skips its restore on cancellation, but the two are not
    /// equally cheap, and the asymmetry is the part a reader needs. Claude leaves the draft one
    /// Ctrl+Y away in its own kill ring; this function re-types instead precisely because codex
    /// has never been shown to keep such a ring — see the doc above, which deliberately does
    /// not depend on one. Reaching this case at all takes two renames in flight at once.
    ///
    /// **This is not `submit`'s guard.** `submit` restores only on a CONFIRMED change — it
    /// re-reads the composer after the kill and compares `after != before` before typing
    /// anything back. This function drops that re-read: by the time either exit path calls
    /// it, the screen has moved through `/rename` and, on the success path, the modal's own
    /// submission — there is no "after the kill" screen left to read back against `before`.
    /// The emptiness check is what stands in its place, and it is a weaker guarantee: it
    /// protects against retyping nothing, not against retyping something the kill never
    /// actually removed.
    private func restoreDraft(_ before: String, into injector: TextInjecting) {
        guard !before.isEmpty, before != Self.placeholder else { return }
        injector.sendText(before)
    }

    /// **Types codex's `/rename` and, once the modal answers, the new name — never the other
    /// way around.**
    ///
    /// Two submissions, two repaints to wait through, so this calls `settle` twice rather
    /// than once — see `AgentRenameTyping`'s doc comment for why that is legal here and is
    /// not for `submit`. `onFinished` is what carries the one-shot guarantee instead, firing
    /// exactly once whichever of the three ways this ends: the name committed, the modal
    /// never came up, or the request was cancelled while codex repainted.
    ///
    /// **Stage two gates on a POSITIVE modal reading**, not an emptiness check. If `/rename`
    /// did not open a modal — a version mismatch, a slow repaint, codex refusing for a reason
    /// of its own — typing `<name>`⏎ anyway would submit it to the model as a real prompt,
    /// spending tokens and polluting the user's thread with a name nobody asked it about. So
    /// an unread or absent modal escapes and stops, exactly as `composer(_:)`'s own guard at
    /// the top of `submit` fails closed rather than guesses.
    ///
    /// **The modal's field is killed unconditionally before the name is typed, with no
    /// compare.** The captured field reads `session 2` — the thread's CURRENT name — and
    /// pyte cannot see ANSI dim, so the capture cannot prove whether that is real prefilled
    /// text or a dim placeholder hint. Typing straight into prefilled text would produce
    /// `session 2newname`, so the kill runs regardless of which reading is true: on the dim
    /// reading it is a no-op (`sendKillLine()` on an empty line is documented as one, both in
    /// `SpyInjector` and in the real injector), and on the prefilled reading it is the only
    /// thing standing between this call and a corrupted thread name. This is NOT the
    /// kill-and-compare the 54769a4 regression made — that regression bailed on typing when a
    /// read disagreed; this always types, and only ever varies whether it restores a draft
    /// afterward.
    func submitRename(
        _ name: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let bar = composer(injector) else { return false }
        let before = bar.content

        injector.sendKillLine()
        settle {
            guard stillWanted() else {
                onFinished(false)
                return
            }
            injector.sendText("/rename")
            injector.sendReturn()
            settle {
                guard self.renameModal(injector) != nil else {
                    // No `settle` between the Escape and the restore, unlike every other
                    // injection pair in this method. That is deliberate, not an oversight:
                    // `sendEscape` here is dismissing a modal that this branch has already
                    // established is NOT open (`renameModal` read nil), so there is nothing
                    // pending to wait out — the Escape is a defensive no-op for the case
                    // where the modal opened after this read but before this line runs, not
                    // a repaint this call depends on. Restoring immediately keeps the two
                    // keystrokes atomic from the terminal's point of view. Residual risk: if
                    // the modal really is mid-open and Escape has not yet been processed
                    // when `before` is typed, that text could land in the still-open modal's
                    // field rather than the composer — a narrow race, and the same class of
                    // risk `submit` accepts by typing right after `sendKillLine()` with no
                    // settle in between.
                    injector.sendEscape()
                    self.restoreDraft(before, into: injector)
                    onFinished(false)
                    return
                }
                injector.sendKillLine()
                injector.sendText(name)
                injector.sendReturn()
                settle {
                    self.restoreDraft(before, into: injector)
                    onFinished(true)
                }
            }
        }
        return true
    }
}
