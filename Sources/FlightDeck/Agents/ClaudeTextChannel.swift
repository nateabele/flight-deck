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
///   appends, so a draft spanning rows cannot be taken apart and put back — so a multi-row box
///   is refused untouched.
/// - **The kill probes; it does not gate typing.** Claude Code renders its rotating placeholder
///   hint in exactly the same shape as a real draft (see `InputBar`), so the screen cannot be
///   trusted to say whether the buffer is empty — and an idle box shows that placeholder, so
///   treating "the kill removed something" as "a draft is here, defer" refused to type into
///   idle boxes and broke 100% of sidebar renames. So `submit` reads the box, kills the line,
///   then types the pending text and Returns it regardless (Claude queues it if a turn is
///   running), and uses the before/after change ONLY to decide whether it owes a draft back: if
///   the kill removed real content, the draft is yanked back out of the ring AFTER the text was
///   submitted.
/// - **A draft is never clobbered.** The text is typed *around* a draft, not over it — the yank
///   puts the draft back — and when the request is superseded mid-settle the text is not typed
///   at all but a killed draft is still yanked back, because leaving someone's half-written
///   thought destroyed is the one outcome the whole dance exists to prevent.
///
/// `sendText` and `sendReturn` are separate because a paste is not typing — see
/// `TextInjecting.sendReturn()`.
struct ClaudeTextChannel: AgentTextChannel {
    /// Claude shows this in the input box when messages are queued behind a running turn — the
    /// input itself is empty and typing appends another queued message, so it is a hint, not a
    /// draft. Version-pinned to Claude Code's wording (verified 2.1.268). Only `isComposerEmpty`
    /// reads it now, and `isComposerEmpty` only feeds the `composer=` diagnostic string
    /// (`promptTypingComposerState`) — nothing gates typing on it. So a wording drift merely
    /// mislabels that log line; it can never cause a clobber, because injection is gated on
    /// `hasComposerBox` and `submit()` kills-and-compares regardless.
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
    /// empty enough to type into is `submit`'s question, and its kill-probe answers it: it kills
    /// the line and compares, types the text regardless — Claude queues it mid-turn — and yanks
    /// a killed draft back afterward so a draft is typed around, never clobbered. This check only
    /// asks whether a real composer is there to probe at all, as opposed to a dialog, a shell,
    /// or a screen this build cannot read.
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

    /// Every ordinary claude dialog carries this footer token, and a composer never does: a
    /// permission prompt shows `Esc to cancel · Tab to amend`, an `AskUserQuestion`
    /// `Esc to cancel`, the unprompted auto-mode nudge `Enter to confirm · Esc to cancel`.
    /// Matching user-facing copy with a fixed meaning is markedly more stable than matching
    /// box-drawing geometry. Fourteen of the fifteen dialog captures in `Fixtures/Claude/`
    /// carry it — every one but `question-two-review`.
    ///
    /// **Matched whole, never shortened to an `Esc to ` prefix.** A running turn's interrupt
    /// hint begins with those same words, and injection must stay allowed mid-turn because
    /// claude queues what it receives. `CodexTextChannel.dialogFooterTokens` states the same
    /// constraint, where it is a live collision with codex's captured `esc to interrupt`.
    ///
    /// The casing is claude's own, as printed, but **nothing rests on the comparison being
    /// case-sensitive and no test pins it**: no composer capture in `Fixtures/Claude` carries
    /// this phrase in any casing — the fourteen dialog footers are its only occurrences — and
    /// `esc to interrupt` cannot contain `esc to cancel` at any casing anyway. Said plainly
    /// because the reverse was claimed here before and was not true.
    static let dialogFooterToken = "Esc to cancel"

    /// **The one dialog shape in the corpus that carries no `Esc to cancel` footer at all:**
    /// `question-two-review`'s confirmation step — `Ready to submit your answers?` closed by
    /// `❯ 1. Submit answers` / `  2. Cancel` — is a plain confirmation, not a cancellable
    /// prompt, so it never prints that token.
    ///
    /// What it shares with most other dialogs, and with nothing a composer draws, is the
    /// marker-plus-number shape `ChoiceDialog.hasNumberedRowAtMarker` recognises.
    ///
    /// The converse also holds, which is why neither rule may be dropped for the other:
    /// `question-checkbox-submit-focused` puts the marker on the UNNUMBERED action row
    /// (`❯    Submit`), so no numbered row sits at its marker and only `Esc to cancel`
    /// catches it.
    ///
    /// `❯` is stated here rather than defaulted there for the reason
    /// `ChoiceDialog.focusedRow` gives: codex draws `›`, and an agent that inherited claude's
    /// glyph would be reading claude's screen grammar off somebody else's screen.
    static func hasNumberedMarkerRow(_ viewport: String) -> Bool {
        ChoiceDialog.hasNumberedRowAtMarker(inViewport: viewport, marker: ChoiceDialog.claudeMarker)
    }

    /// Either recognised dialog shape is enough. The two are independent on purpose: the
    /// footer is copy claude can reword in any release, the row shape is layout it can restyle,
    /// and a screen only has to trip one of them to be refused.
    static func isKnownNonComposer(_ viewport: String) -> Bool {
        viewport.contains(dialogFooterToken) || hasNumberedMarkerRow(viewport)
    }

    /// Unreadable screen means *no veto*, not a veto — the fail-open direction
    /// `AgentTextChannel.isKnownNonComposer` documents. Answering true here would make a
    /// transient read failure look exactly like a dialog and drop the message.
    ///
    /// **The caller does not rely on that nil passing through, and must not start.**
    /// `SessionStore.injectionGate` reads the viewport itself before asking this on the
    /// `.live` path, precisely because this answer is "unsure", not "clear" — see the comment
    /// there. The `.unknown` path is covered by `hasComposerBox`, which fails closed on nil
    /// under its own rule.
    func isKnownNonComposer(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.isKnownNonComposer(viewport)
    }

    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
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
            // **A changed, readable screen means a real draft was killed — but that CANNOT
            // decide whether we type.** An idle box shows Claude's rotating placeholder, which
            // the real screen reader returns as `before` content and which the kill clears, so
            // `after != before` fires on essentially every idle box. Treating that as "a draft
            // is here, defer" — as an earlier version did — refused to type into idle boxes and
            // broke 100% of sidebar renames. So always type the pending text (Claude queues it
            // if a turn is running); use the change ONLY to restore a draft we may owe back.
            //
            // The one thing we still never do is clobber a real draft: when the request was
            // superseded (or the tab closed / entry expired) mid-settle we do not type, but we
            // still yank a killed draft back rather than leave the box empty.
            let killedADraft = after != nil && after != before
            if stillWanted() {
                injector.sendText(text)
                injector.sendReturn()
                // Restore a real draft AFTER the pending text was submitted. On an empty box or
                // a placeholder this yanks whatever is in Claude's kill-ring — usually nothing,
                // and harmless since nothing was submitted from it.
                if killedADraft { injector.sendYank() }
                onFinished(true)
            } else {
                if killedADraft { injector.sendYank() }
                // **Reported, not merely returned from.** This method has already committed
                // to `true`, so `SessionStore.inject` has marked the tab mid-injection and is
                // waiting here to release it. Falling off the end of this branch — which is
                // what this used to do — left that mark set with no path left to clear it,
                // and the tab then refused every later rename and phone prompt for the life
                // of the process. `false` because nothing was submitted, which is also what
                // stops the caller retiring a pending entry that now holds a newer request.
                onFinished(false)
            }
        }
        return true
    }
}
