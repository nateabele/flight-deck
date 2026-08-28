import Foundation

/// What every agent's title sanitizer has in common, so the part that differs is one
/// argument rather than two copies of the same trim-and-cap.
///
/// The difference is real and it is about the **channel the name travels down**, not about
/// taste. Claude's rename is `/rename <name>` typed into a pty that may have no `claude`
/// running — an explicitly supported degradation where the text reaches a bare shell — so a
/// name that could act as shell syntax is stripped. Codex's rename is `thread/name/set` over
/// JSON-RPC and touches no shell at any point, so the same strip would only mangle the user's
/// title: `fix build (part 2)` became `fix build part 2` in codex's own thread list.
enum AgentTitle {
    /// Long enough for a sentence, short enough for a sidebar row and for `claude --name`.
    static let maxLength = 120

    /// Characters with special meaning to `sh`/`bash`/`zsh`. Kept minimal: ordinary
    /// punctuation people use in names is left alone.
    static let shellMetacharacters = CharacterSet(charactersIn: ";&|`$()<>")

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
