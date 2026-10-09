import Foundation

/// grok's composer, typed into and submitted at the pty.
///
/// **Draft handling uses grok's own stash, not a kill ring.** Claude's channel kills a draft
/// with Ctrl+E Ctrl+U and yanks it back; on grok both keys mean something else outside the
/// prompt editor (its keyboard guide binds Ctrl+E to "expand thinking blocks" and Ctrl+U to a
/// half-page scroll in the scrollback pane), and grok keeps no yank. What it has instead
/// (grok 1.0.30, user guide ch. 3, Ctrl+S verified live): **Ctrl+S on a non-empty composer
/// stashes the draft and empties the box, and "a chord-stashed draft restores automatically
/// after you send your next prompt"** — exactly the kill/submit/restore dance, done by grok.
///
/// **Why not `Esc Esc`**, the other way grok clears a draft: it only works while idle (mid-turn,
/// Escape just shows a "press Ctrl+C" toast), its stash is a *discard* that is NOT restored
/// after the next send, and on an EMPTY composer the same two keys open the rewind picker. So
/// this channel never sends Escape at all.
///
/// Because grok draws no placeholder (see `GrokScreen`), whether there is a draft is read off
/// the screen directly. The stash is still verified before anything is typed: a box that is
/// not empty after Ctrl+S means the chord did not land, and typing then would splice the
/// message into somebody's text.
///
/// The text and its Return are two settle hops, for codex's reason (`CodexTextChannel.submit`):
/// a Return arriving in the same burst as a paste can be folded into it. grok was not shown to
/// paste-detect, but the hop costs 120 ms and the failure it prevents is a message that sits
/// typed and unsent.
struct GrokTextChannel: AgentTextChannel {
    func isComposerEmpty(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport(),
              let composer = GrokScreen.composer(inViewport: viewport)
        else { return false }
        return composer.draft.isEmpty
    }

    /// See `AgentTextChannel.draft`. grok draws no placeholder (`GrokScreen`), so what the box
    /// holds is the draft.
    func draft(_ injector: TextInjecting) -> String? {
        guard let viewport = injector.readViewport(),
              let composer = GrokScreen.composer(inViewport: viewport)
        else { return nil }
        return composer.draft
    }

    func hasComposerBox(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return GrokScreen.composer(inViewport: viewport) != nil
    }

    /// A permission or question card replaces the composer. Unreadable means no veto, for the
    /// reason `AgentTextChannel.isKnownNonComposer` gives.
    func isKnownNonComposer(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return GrokScreen.hasCard(inViewport: viewport)
    }

    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let viewport = injector.readViewport(),
              let composer = GrokScreen.composer(inViewport: viewport)
        else { return false }
        let stashed = !composer.draft.isEmpty
        if stashed { injector.sendControlKey("s") }

        settle {
            if stashed {
                // Verified, not assumed. A box still holding text means the stash did not land;
                // an unreadable box means we do not know. Either way nothing is typed, and the
                // draft is either where it was or one Ctrl+S away in grok's stash.
                guard let after = injector.readViewport().flatMap(GrokScreen.composer(inViewport:)),
                      after.draft.isEmpty
                else {
                    onFinished(false)
                    return
                }
            }
            guard stillWanted() else {
                // Ctrl+S on the now-empty box pops the stash straight back.
                if stashed { injector.sendControlKey("s") }
                onFinished(false)
                return
            }
            injector.sendText(text)
            settle {
                injector.sendReturn()
                guard stashed else {
                    onFinished(true)
                    return
                }
                settle {
                    // grok restores a chord-stashed draft after the send by itself. Pop it only
                    // if the box is still empty: a Ctrl+S on a box grok already refilled would
                    // stash the draft straight away again.
                    if let now = injector.readViewport().flatMap(GrokScreen.composer(inViewport:)),
                       now.draft.isEmpty {
                        injector.sendControlKey("s")
                    }
                    onFinished(true)
                }
            }
        }
        return true
    }
}
