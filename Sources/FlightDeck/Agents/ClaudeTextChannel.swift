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
/// - **The kill happens BEFORE we know whether there was anything to kill**, because that is
///   the only way to find out. Claude Code renders its rotating placeholder hint in exactly
///   the same shape as a real draft (see `InputBar`), so the screen cannot be trusted to say
///   whether the buffer is empty. Killing and then comparing measures the effect instead. A
///   kill that changed nothing means the line was empty and there is nothing to restore —
///   yanking there would paste the user's *previous* kill into the bar.
/// - **The yank comes after the Return**, so a wrong guess can only leave text sitting in the
///   bar, never submit it.
///
/// `sendText` and `sendReturn` are separate because a paste is not typing — see
/// `TextInjecting.sendReturn()`.
struct ClaudeTextChannel: AgentTextChannel {
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
            guard stillWanted() else { return }
            let after = injector.readViewport().flatMap(InputBar.read(fromViewport:))?.content
            injector.sendText(text)
            injector.sendReturn()
            // Restore only on a *confirmed* change. If the screen went unreadable we do not
            // know, and the draft is one Ctrl+Y away in Claude's own ring — better than
            // pasting text the user never typed into a bar that was empty.
            if let after, after != before { injector.sendYank() }
            onSent()
        }
        return true
    }
}
