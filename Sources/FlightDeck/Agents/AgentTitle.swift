import Foundation

/// What every agent's title sanitizer has in common, so the part that differs is one
/// argument rather than two copies of the same trim-and-cap.
///
/// **Neither agent strips shell metacharacters, and the two converged on that answer for
/// different reasons — the channel the name travels down.** Codex's rename is
/// `thread/name/set` over JSON-RPC and touches no shell at any point, so the strip only ever
/// mangled the user's title: `fix build (part 2)` became `fix build part 2` in codex's own
/// thread list. Claude's rename is `/rename <name>` typed into a pty, which used to double as
/// a bare shell whenever `claude` itself was not yet running — an explicitly supported
/// degradation the strip existed to guard. `SessionStore.inject` now refuses to type anywhere
/// but a live, on-screen composer (see `ClaudeTextChannel`), so that bare-shell case cannot
/// reach this path any more, and claude dropped the strip too.
enum AgentTitle {
    /// Long enough for a sentence, short enough for a sidebar row and for `claude --name`.
    static let maxLength = 120

    /// Trims, strips control characters and `forbidden`, and caps length. Returns nil when
    /// nothing usable remains, which callers treat as "revert to the previous title".
    ///
    /// **Control characters are stripped for every agent, and that is not the shell rule
    /// wearing a disguise.** A newline in a title breaks the sidebar row and, for claude,
    /// would submit the injected `/rename` halfway through; neither has anything to do with
    /// metacharacters. Only `forbidden` is the per-agent part.
    static func sanitized(_ raw: String, removing forbidden: CharacterSet) -> String? {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !forbidden.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}
