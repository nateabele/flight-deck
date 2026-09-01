// Sources/FlightDeck/InputBar.swift
import Foundation

/// Claude Code's prompt input box, as read off the terminal screen.
///
/// Flight Deck injects `/rename` by typing into the pty, and a paste lands wherever the
/// input cursor happens to be — so before injecting anything the store has to know the
/// shape of what is already in the box. This is that reading, and nothing more: it
/// reports how many rows the box occupies and what text they hold.
///
/// **What it deliberately does not tell you.** Whether a draft exists. Claude Code renders
/// its rotating placeholder hint (`Try "how does RootView.swift work?"`) in exactly the
/// same shape as a real draft — prompt marker, U+00A0, text — and the two differ only in
/// colour, which `ghostty_surface_read_text` does not return. Treating a hint as a draft
/// would be actively dangerous: the caller would kill an empty line, killing nothing,
/// then yank and paste the user's *previous* kill into the bar. `SessionStore` therefore
/// kills first and compares `content` before and after, which measures what actually
/// happened instead of guessing from appearance.
enum InputBar {
    struct Reading: Equatable {
        /// The box's content rows, top row first, with the prompt marker stripped.
        /// More than one row means the draft is wrapped or genuinely multiline — the
        /// caller cannot safely clear either, because Ctrl+U kills one logical line and
        /// yank-pop replaces rather than appends.
        var rows: [String]

        /// Every row joined, for before/after comparison across a kill.
        var content: String { rows.joined(separator: "\n").trimmingCharacters(in: .whitespaces) }
    }

    /// U+276F, the prompt marker Claude Code draws at the start of the input box.
    static let claudeMarker: Character = "❯"

    /// U+203A, the marker codex draws instead. A *different glyph*, not a variant spelling:
    /// on a codex screen `❯` matches nothing at all, which is why this reader used to return
    /// nil for every codex tab rather than mis-reading one. Verified against
    /// `Fixtures/Codex/tui-idle.captured.txt`.
    static let codexMarker: Character = "›"

    /// Reads the *last* box on screen. Earlier markers are echoes of submitted messages
    /// sitting in the scrollback; locking onto one would read a frozen old prompt. Both
    /// agents echo submitted prompts with their own marker, so this rule is shared, not
    /// claude-specific — see `Fixtures/Codex/tui-working.captured.txt`, which carries `›`
    /// twice.
    ///
    /// `marker` is a parameter rather than a constant because the two agents draw different
    /// glyphs; everything else about the shape — one marker line, continuation rows, a blank
    /// line or a rule closing the run — is common to both, checked against each agent's own
    /// captured screens.
    static func read(fromViewport viewport: String, marker: Character = claudeMarker) -> Reading? {
        let lines = viewport.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.first == marker }) else { return nil }

        var rows = [String(lines[start].dropFirst())]
        // Continuation rows are indented, but so is the status chrome below the box, so
        // the closing rule is what ends the run — not the indentation.
        for line in lines[(start + 1)...] {
            if isRule(line) || line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            rows.append(line)
        }
        return Reading(rows: rows.map(normalized))
    }

    /// A box border: a run of `─` and nothing else.
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
    }

    /// The separator after the marker is U+00A0, which `CharacterSet.whitespaces` covers
    /// but `Character.isWhitespace`-style trimming of plain spaces alone would not.
    private static func normalized(_ row: String) -> String {
        row.trimmingCharacters(in: .whitespaces)
    }
}
