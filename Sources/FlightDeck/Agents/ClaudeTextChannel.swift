import Foundation

/// Claude Code's input box, typed into and submitted.
///
/// **This is `SessionStore.inject`'s body, moved rather than rewritten.** What stayed behind
/// is the store's own bookkeeping — the capability question, the idle-status gate, finding
/// the injector, and the mid-injection mark that keeps a rename from racing a queued prompt.
/// What came here is everything that is *claude's*: `InputBar`'s one-row box, and a
/// kill-and-yank dance that works only because Claude Code keeps a deleted-text ring.
///
/// The gates below, and why each one:
///
/// - **One row only.** Ctrl+U kills a single logical line and yank-pop *replaces* rather than
///   appends, so a draft spanning rows cannot be taken apart and put back.
/// - **The kill IS the emptiness gate**, not a step before typing. Claude Code renders its
///   rotating placeholder hint in exactly the same shape as a real draft (see `InputBar`), so
///   the screen cannot be trusted to say whether the buffer is empty. So `submit` reads the
///   box, kills the line, lets it repaint, and reads again: if nothing changed the box was
///   empty (or held a placeholder / queued-messages hint, neither of which is editable
///   content) and the text is typed; if the kill removed something a real draft was there, so
///   it is yanked back and the whole injection BAILS — nothing typed, no Return, no `onSent`,
///   and the pending entry stays queued to retry when the box is free.
/// - **A draft is never typed over.** The old code always typed after the kill and yanked only
///   to restore; this refuses instead, because clobbering someone's half-written thought is
///   the one outcome the whole dance exists to prevent.
///
/// `sendText` and `sendReturn` are separate because a paste is not typing — see
/// `TextInjecting.sendReturn()`.
struct ClaudeTextChannel: AgentTextChannel {
    /// Claude shows this in the input box when messages are queued behind a running turn — the
    /// input itself is empty and typing appends another queued message, so it is a hint, not a
    /// draft. Version-pinned to Claude Code's wording (verified 2.1.268). If the wording drifts,
    /// this match simply fails and behaviour reverts to today's (refuse-until-idle) — never a
    /// clobber, because `submit()` still kills-and-compares.
    static let queuedMessagesHint = "Press up to edit queued messages"

    func isComposerEmpty(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport(),
              let bar = InputBar.read(fromViewport: viewport),
              bar.rows.count == 1
        else { return false }
        let content = bar.content.trimmingCharacters(in: .whitespaces)
        return content.isEmpty || content == Self.queuedMessagesHint
    }

    /// **The empirical fact everything here rests on: claude's composer is the FULL box.** A
    /// `─` rule sits on the line immediately above the `❯` marker, AND the run it opens is
    /// closed by a rule rather than trailing into a blank line. Verified against every fixture
    /// in `Fixtures/Claude/`: idle, mid-turn streaming, and the rotating placeholder hint all
    /// carry both rules; every permission prompt and `AskUserQuestion` dialog — including the
    /// tricky case where the cursor has been arrowed down to the list's last, unruled row —
    /// carries at most one, and a bare shell's own `❯`-drawing prompt carries neither.
    ///
    /// **Both rules, not one.** A dialog's own list is itself closed by a rule (`InputBar.read`
    /// relies on exactly that to end a reading), so checking only "closed by a rule" would pass
    /// on every `question-*` capture. And the list's last row sits directly under that same
    /// closing rule, so checking only "a rule immediately above" would pass on that row too.
    /// Only requiring both rejects every dialog shape while still accepting a real composer,
    /// whose second rule is the footer beneath it — never a dialog's list.
    ///
    /// **Presence, not emptiness.** This is `SessionStore.inject`'s gate now, replacing the
    /// status-file activity check — see `AgentTextChannel.hasComposerBox`. Whether the box is
    /// empty enough to type into is `submit`'s question, and its kill-probe IS that emptiness
    /// gate: it kills the line and compares, typing only when the kill removed nothing and
    /// DEFERRING when it removed a draft — never typing around one. This check only asks whether
    /// a real composer is there to probe at all, as opposed to a dialog, a shell, or a screen
    /// this build cannot read.
    static func isComposerBox(_ viewport: String) -> Bool {
        let lines = viewport.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.first == InputBar.claudeMarker }),
              start > 0, InputBar.isRule(lines[start - 1])
        else { return false }
        for line in lines[(start + 1)...] {
            if InputBar.isRule(line) { return true }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        // Ran off the bottom of the viewport without closing — not the shape a real composer
        // ever leaves on screen, so refuse rather than guess.
        return false
    }

    func hasComposerBox(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.isComposerBox(viewport)
    }

    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onSent: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let viewport = injector.readViewport(),
              let bar = InputBar.read(fromViewport: viewport),
              bar.rows.count == 1
        else { return false }

        let before = bar.content
        injector.sendKillLine()
        // Claude Code needs a moment to repaint before the screen reflects the kill.
        settle {
            // A closure rather than the `InputBar.read(fromViewport:)` function reference:
            // the reader now takes a marker, and a defaulted parameter cannot be spelled as
            // a bare function reference.
            let after = injector.readViewport().flatMap { InputBar.read(fromViewport: $0) }?.content
            // **Restore first, decide second.** A real draft was present and the kill removed
            // it (`after != before`), OR the screen went unreadable so we cannot confirm it was
            // empty. Either way we killed something we may owe back, so yank it out of Claude's
            // own kill-ring UNCONDITIONALLY — before any `stillWanted` check — and BAIL: type
            // nothing, press no Return, call no `onSent`. If we gated the restore on
            // `stillWanted`, a prompt superseded (or a tab closed / entry expired) during the
            // settle window would leave the killed draft destroyed, which is the one outcome
            // this whole dance exists to prevent. The pending entry, if still wanted, stays
            // queued and retries when the box is free. The unreadable case chooses safety over
            // the old code's "type anyway": clobbering a draft is worse than a deferral.
            if after != before {
                injector.sendYank()
                return
            }
            // `after == before`: the kill removed nothing — an empty box, a rotating
            // placeholder, or a queued-messages hint, none of which are editable buffer
            // content — so there is nothing to restore and it is safe to abandon here if the
            // request was superseded. Otherwise type it (Claude queues it if a turn is running)
            // and retire the entry.
            guard stillWanted() else { return }
            injector.sendText(text)
            injector.sendReturn()
            onSent()
        }
        return true
    }
}
