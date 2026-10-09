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
        /// `●` on a radio row. On a permission card that is the row Return would submit; on a
        /// question card it is the CHOSEN answer, not the cursor (grok draws its cursor in colour
        /// only, which a plain-text read never sees — facts-2 §1).
        let focused: Bool
        let label: String
        /// `[x]`/`[ ]` on a multi-select question's row, nil on a radio row. The one piece of a
        /// checkbox question's state the screen spells out, and so the only thing a drive can
        /// confirm a toggle against.
        var checked: Bool? = nil
    }

    /// Every answer row on screen, in order. Empty when no card is up.
    static func cardRows(inViewport viewport: String) -> [CardRow] {
        viewport.components(separatedBy: "\n").compactMap(cardRow)
    }

    /// `┃  <key> (●|○) <label>` or `┃  <key> [x|space] <label>`. Anything else on a `┃` line —
    /// the title, a blank rule, a description — is not a row.
    static func cardRow(_ line: String) -> CardRow? {
        let lead = trimmedLeading(line)
        guard lead.first == cardRule else { return nil }
        let body = trimmedLeading(String(lead.dropFirst()))
        let chars = Array(body)
        guard chars.count >= 6, chars[1] == " ", chars[5] == " " else { return nil }
        let key = chars[0]
        guard key.isASCII, key.isNumber || key.isLowercase else { return nil }
        let focused: Bool
        var checked: Bool?
        switch (chars[2], chars[3], chars[4]) {
        case ("(", "●", ")"): focused = true
        case ("(", "○", ")"): focused = false
        case ("[", "x", "]"): focused = false; checked = true
        case ("[", " ", "]"): focused = false; checked = false
        default: return nil
        }
        let label = stripScrollbar(String(chars[6...]))
        guard !label.isEmpty else { return nil }
        return CardRow(key: key, focused: focused, label: label, checked: checked)
    }

    /// grok draws its scrollback's scrollbar thumb (`█`) in the last column, and on a tall
    /// transcript it lands on card rows (seen live on every question row, facts-2 §1). Left in,
    /// a permission row would read `Yes …█` and the exact-"Yes" match would refuse every card.
    private static func stripScrollbar(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("█") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
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

    /// A question card (`ask_user_question`), read for a drive that answers it a key at a time.
    ///
    /// Probed on grok 1.0.30 (`.superpowers/grok-tui-facts-2.md` §1):
    /// ```text
    ///   ┃  Pick toppings
    ///   ┃  1 [x] Cheese  Cheese
    ///   ┃  2 [ ] Ham     Ham
    ///   ┃  z [ ] Type your answer here
    ///   ┃  [2/3] ↑/↓ navigate · ←/→ question · y copy                 Enter:select
    ///   Tab:next answer  │  Esc:unselect  │  Shift+x:dismiss
    /// ```
    struct QuestionCard: Equatable {
        struct Position: Equatable {
            /// 1-based, as grok prints it.
            let index: Int
            let count: Int
        }

        /// The first text line of the card above its rows: the question, or its first line
        /// when it wraps.
        let title: String?
        /// Every row but the free-text one, in order.
        let options: [CardRow]
        let freeText: CardRow
        /// `[i/n]` on a set; nil on a lone question, which prints none.
        let position: Position?
        /// The card has the keyboard. With it parked in the scrollback (one Escape) the card
        /// stays drawn but a digit goes to the scrollback instead, and the bar trades
        /// `Shift+x:dismiss` for `Tab/Space:question` (probed).
        let hasKeyboard: Bool
        /// The free-text row is open as an editor (`z (●) ❯ …`, bar `Esc:back`): what is typed
        /// now is text, not keys.
        let editorText: String?
    }

    static let questionKeyboardToken = "Shift+x:dismiss"
    static let editorBarToken = "Esc:back"
    static let editorMarker = "❯"

    /// The question card on screen, or nil when there is none. A permission card is not one: it
    /// has no free-text row.
    static func questionCard(inViewport viewport: String) -> QuestionCard? {
        let lines = viewport.components(separatedBy: "\n")
        var title: String?
        var rows: [CardRow] = []
        var position: QuestionCard.Position?
        var bar: [String] = []
        for line in lines {
            let lead = trimmedLeading(line)
            guard lead.first == cardRule else {
                if !lead.trimmingCharacters(in: .whitespaces).isEmpty { bar.append(lead) }
                continue
            }
            if let row = cardRow(line) {
                rows.append(row)
                continue
            }
            let text = stripScrollbar(String(lead.dropFirst()))
            if text.isEmpty { continue }
            if let parsed = parsePosition(text) {
                position = parsed
            } else if rows.isEmpty, title == nil, !text.contains("navigate") {
                title = text
            }
        }
        guard let free = rows.last, free.key == "z" else { return nil }
        let options = Array(rows.dropLast())
        // Only the lines below the card are its bar; a transcript line that happens to quote a
        // bar token above it must not count.
        let editing = bar.contains { $0.contains(editorBarToken) } && free.label.hasPrefix(editorMarker)
        let editorText = editing
            ? String(free.label.dropFirst(editorMarker.count)).trimmingCharacters(in: .whitespaces) : nil
        return QuestionCard(
            title: title, options: options, freeText: free, position: position,
            hasKeyboard: bar.contains { $0.contains(questionKeyboardToken) },
            editorText: editorText)
    }

    /// `[2/3] ↑/↓ navigate …` → (2, 3).
    private static func parsePosition(_ text: String) -> QuestionCard.Position? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let inner = text[text.index(after: text.startIndex)..<close].split(separator: "/")
        guard inner.count == 2, let index = Int(inner[0]), let count = Int(inner[1]),
              index >= 1, index <= count else { return nil }
        return .init(index: index, count: count)
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
