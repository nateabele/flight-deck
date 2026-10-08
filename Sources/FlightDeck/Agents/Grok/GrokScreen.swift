import Foundation

/// grok's screen grammar, read from plain text — the only thing `readViewport()` returns.
///
/// Everything here comes from the live probe of grok 1.0.30 (`.superpowers/grok-tui-facts.md`
/// §3–§4); the fixtures in `Fixtures/Grok/` are synthetic screens rebuilt in that captured
/// shape. Two surfaces matter, and they never share the screen — a blocking card REPLACES the
/// composer box:
///
/// **The composer**, a rounded box:
/// ```text
///   ╭──────────────────────────────── [Stashed · ][<title>] ──╮
///   │ ❯ <draft, first row>                                     │
///   │   <draft, continuation rows>                             │
///   ╰──────────────────────────────────────── Grok 4.7 (high) ─╯
/// ```
/// An EMPTY composer is `│ ❯` and spaces: unlike claude and codex, grok draws no placeholder
/// hint, so what is in the box is the draft, and emptiness is readable rather than inferred.
///
/// **A blocking card** (permission or question), `┃`-ruled, one row per answer:
/// ```text
///   ┃  Allow Edit to /repo/a.txt?
///   ┃  1 (●) Yes, and don't ask again for anything (always-approve mode)
///   ┃  2 (○) Yes, allow all edits during this session
///   ┃  3 (○) Yes
///   ┃  4 (○) No, reject (type to add feedback)
/// ```
/// `●` marks the focused row; the leading key (`1`–`9`, `a`–`f`, or `z` for a question's
/// free-text row) picks that row in one press.
enum GrokScreen {
    static let composerMarker = "│ ❯"
    static let cardRule: Character = "┃"

    /// What the composer box holds, or nil when no box is on screen.
    struct Composer: Equatable {
        /// The draft, rows joined by newlines; empty for an empty box.
        let draft: String
    }

    static func composer(inViewport viewport: String) -> Composer? {
        let lines = viewport.components(separatedBy: "\n")
        guard let marker = lines.lastIndex(where: { trimmedLeading($0).hasPrefix(composerMarker) }),
              marker > 0
        else { return nil }
        // The box's own top edge, directly above. A shell that happens to print `│ ❯` draws
        // no rounded corner over it, and this is what keeps text from being typed into one.
        let top = trimmed(lines[marker - 1])
        guard top.hasPrefix("╭"), top.hasSuffix("╮") else { return nil }

        var rows = [contentOfRow(lines[marker], dropping: composerMarker)]
        var index = marker + 1
        while index < lines.count {
            let line = trimmed(lines[index])
            if line.hasPrefix("╰") {
                guard line.hasSuffix("╯") else { return nil }
                let draft = rows.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Composer(draft: draft)
            }
            guard line.hasPrefix("│") else { return nil }
            rows.append(contentOfRow(lines[index], dropping: "│"))
            index += 1
        }
        // A box with no bottom edge on screen is not a box this build can vouch for.
        return nil
    }

    /// One row of a blocking card.
    struct CardRow: Equatable {
        let key: Character
        let focused: Bool
        let label: String
    }

    /// Every answer row on screen, in order. Empty when no card is up.
    static func cardRows(inViewport viewport: String) -> [CardRow] {
        viewport.components(separatedBy: "\n").compactMap(cardRow)
    }

    /// `┃  <key> (●|○) <label>`. Anything else on a `┃` line — the title, a blank rule, a
    /// description — is not a row.
    static func cardRow(_ line: String) -> CardRow? {
        let lead = trimmedLeading(line)
        guard lead.first == cardRule else { return nil }
        let body = trimmedLeading(String(lead.dropFirst()))
        let chars = Array(body)
        guard chars.count >= 6, chars[1] == " ", chars[2] == "(", chars[4] == ")", chars[5] == " "
        else { return nil }
        let key = chars[0]
        guard key.isASCII, key.isNumber || key.isLowercase else { return nil }
        let focused: Bool
        switch chars[3] {
        case "●": focused = true
        case "○": focused = false
        default: return nil
        }
        let label = String(chars[6...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return CardRow(key: key, focused: focused, label: label)
    }

    /// The card's own shortcut-bar token, drawn under both a permission card and a question
    /// card and under nothing else this build has seen.
    static let cardBarToken = "Esc:scrollback"

    /// A card is up: a row parses, or the card's bar is drawn.
    static func hasCard(inViewport viewport: String) -> Bool {
        !cardRows(inViewport: viewport).isEmpty || viewport.contains(cardBarToken)
    }

    /// Does `row` read `label`? A question row is `<label>  <description>`, so the label must
    /// be a prefix that ends at the end of the row or at whitespace — `Red` reads `Red   Choose
    /// red.`, and does not read `Reddish`.
    static func row(_ row: CardRow, reads label: String) -> Bool {
        guard row.label.hasPrefix(label) else { return false }
        let rest = row.label.dropFirst(label.count)
        return rest.isEmpty || rest.first?.isWhitespace == true
    }

    private static func contentOfRow(_ line: String, dropping prefix: String) -> String {
        var text = trimmedLeading(line)
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("│") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func trimmedLeading(_ line: String) -> String {
        String(line.drop(while: { $0 == " " }))
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
