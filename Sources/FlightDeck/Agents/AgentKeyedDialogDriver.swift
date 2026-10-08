import Foundation

/// **A dialog answered by one keypress that names the row — never by Return.**
///
/// The arrows-then-Return drive in `SessionStore.answerPrompt` is right for claude and codex,
/// whose lists open on the plain answer. It is wrong for an agent whose list opens on a
/// DURABLE grant: grok's first permission card of a session focuses "Yes, and don't ask again
/// for anything (always-approve mode)" (probed live, grok 1.0.30), so any Return that lands
/// before the cursor has demonstrably moved grants always-approve. grok also numbers its rows
/// and picks-and-submits on the number, so the safe drive is shorter, not longer: read the row
/// whose label is the answer, press its key, done.
///
/// A sub-protocol checked with `as?` at the one call site, so claude's and codex's drivers —
/// and anything another track is building — are untouched by its existence.
@MainActor
protocol AgentKeyedDialogDriver: AgentDialogDriver {
    /// The key of the plain one-time approval ("Yes" and nothing more), or nil when the screen
    /// shows no such row. Read off the screen every time: grok's row ORDER differs between
    /// dialog kinds, so a remembered index is exactly the bug this type exists to avoid.
    func allowKey(inViewport viewport: String) -> Character?

    /// The key of option `index` of a single question, or nil unless that row reads `label`.
    func optionKey(_ index: Int, label: String, inViewport viewport: String) -> Character?
}
