import Foundation

/// agy's composer, typed into and submitted.
///
/// **The screen grammar (agy 1.3.1, agy-tui-facts §3, re-captured 2026-10-08).** agy draws inline
/// on the primary screen, like Claude Code: a full-width `─` rule, a prompt row starting with
/// ASCII `>`, a second rule, and a footer (`? for shortcuts` idle, `esc to cancel` busy, the
/// model label at the right). So the shape is claude's rule sandwich with a different glyph,
/// and `ClaudeTextChannel`'s reasoning carries over: presence is the rule directly above the
/// LAST `>` row plus a rule closing the run below it.
///
/// **`>` is also what a shell prompt draws** (this machine's fish does — see
/// `ChoiceDialog.codexMarker`'s note), and agy echoes each submitted prompt as `> <text>` under a
/// 60-column rule. Neither defeats the sandwich: a shell draws no rules, and the echo is never the
/// LAST `>` row while agy's composer or a dialog is up below it.
///
/// **Draft handling is claude's kill-and-yank, verified for agy:** Ctrl-U kills the line and
/// Ctrl-Y yanks it back (agy-tui-facts §3). Submission is a bracketed paste followed by a real
/// Return, which agy accepts as one message (verified twice, including `/rename …` on
/// 2026-10-08). Enter while a turn runs QUEUES the message (agy's default `queuedMessages`), so
/// typing mid-turn is safe, as it is for claude.
struct GeminiTextChannel: AgentTextChannel {
    static let marker: Character = ">"

    /// What an empty composer shows in plan and accept-edits modes. A hint, not a draft: Ctrl-U
    /// kills nothing on it.
    static let modePlaceholderSuffix = "(shift+tab to cycle)"

    /// The hint every agy select list draws under its rows — the permission dialogs, the
    /// workspace-trust dialog (whose rows are NOT numbered, so the numbered-row rule alone
    /// misses it) and the slash-command menu. A composer never draws it.
    static let navigateHint = "↑/↓ Navigate"

    static func isComposerBox(_ viewport: String) -> Bool {
        let lines = viewport.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.first == marker }),
              start > 0, InputBar.isRule(lines[start - 1])
        else { return false }
        return lines[(start + 1)...].contains(where: InputBar.isRule)
    }

    static func isKnownNonComposer(_ viewport: String) -> Bool {
        viewport.contains(navigateHint)
            || ChoiceDialog.hasNumberedRowAtMarker(inViewport: viewport, marker: marker)
    }

    static func isEmptyContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasSuffix(modePlaceholderSuffix)
    }

    func isComposerEmpty(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport(), Self.isComposerBox(viewport),
              let bar = InputBar.read(fromViewport: viewport, marker: Self.marker), bar.rows.count == 1
        else { return false }
        return Self.isEmptyContent(bar.content)
    }

    /// See `AgentTextChannel.draft`. agy's placeholder is the mode hint `isEmptyContent` names.
    func draft(_ injector: TextInjecting) -> String? {
        guard let viewport = injector.readViewport(), Self.isComposerBox(viewport),
              let bar = InputBar.read(fromViewport: viewport, marker: Self.marker)
        else { return nil }
        let text = bar.rows.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return Self.isEmptyContent(text) ? "" : text
    }

    func hasComposerBox(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.isComposerBox(viewport)
    }

    /// Unreadable means no veto — the fail-open direction `AgentTextChannel` documents.
    func isKnownNonComposer(_ injector: TextInjecting) -> Bool {
        guard let viewport = injector.readViewport() else { return false }
        return Self.isKnownNonComposer(viewport)
    }

    /// `ClaudeTextChannel.submit`'s dance on agy's grammar: refuse a multi-row draft (Ctrl-U
    /// kills one line and the yank cannot put two back), kill, let agy repaint, type and Return
    /// regardless, then yank a draft back if the kill removed one. Superseded mid-settle: type
    /// nothing, still yank, and report `false` so the caller releases its mark.
    func submit(
        _ text: String,
        into injector: TextInjecting,
        settle: @escaping (@escaping () -> Void) -> Void,
        stillWanted: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let viewport = injector.readViewport(), Self.isComposerBox(viewport),
              let bar = InputBar.read(fromViewport: viewport, marker: Self.marker), bar.rows.count == 1
        else { return false }
        let before = bar.content
        injector.sendKillLine()
        settle {
            let after = injector.readViewport()
                .flatMap { InputBar.read(fromViewport: $0, marker: Self.marker) }?.content
            let killedADraft = after != nil && after != before && !Self.isEmptyContent(before)
            if stillWanted() {
                injector.sendText(text)
                injector.sendReturn()
                if killedADraft { injector.sendYank() }
                onFinished(true)
            } else {
                if killedADraft { injector.sendYank() }
                onFinished(false)
            }
        }
        return true
    }
}

/// agy's select-list dialogs, read and driven.
///
/// Captured shapes (agy 1.3.1): a file write — `> 1. Yes, allow creation` / `  2. No, deny
/// creation` — and a shell command — `> 1. Yes, run command` / `2. Yes, and always allow in
/// this conversation …` / `3. Yes, and always allow … (Persist to settings.json)` /
/// `4. No, cancel`. The focus marker is ASCII `>` and rows are `N. `, so `ChoiceDialog`'s
/// marker-number-neighbour model reads them unchanged.
struct GeminiDialogDriver: AgentDialogDriver {
    func focusedRow(inViewport viewport: String) -> Int? {
        ChoiceDialog.focusedRow(inViewport: viewport, marker: GeminiTextChannel.marker)
    }

    func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool {
        ChoiceDialog.row(index, reads: label, inViewport: viewport, marker: GeminiTextChannel.marker)
    }

    func hasSelectList(inViewport viewport: String) -> Bool {
        ChoiceDialog.hasNumberedRowAtMarker(inViewport: viewport, marker: GeminiTextChannel.marker)
    }

    /// Row 1 is the plain approval on both captured dialogs; row 2 of the command dialog is a
    /// DURABLE grant ("always allow in this conversation"), which is why this is stated from the
    /// capture and not inherited.
    let allowRow = 0

    /// **The last row, never Escape — and so, unlike claude's and codex's, this deny reads the
    /// screen.** Esc on an agy dialog cancels the whole TURN (the step becomes CANCELED and the
    /// screen prints `Interrupted`), not the one call. The deny is the last numbered row, whose
    /// position differs per dialog (row 2 for a file write, row 4 for a command), so it is found
    /// on screen, checked to read as a refusal (`No, …`), and reached with arrows and a Return —
    /// key events, because a digit sent as text is a bracketed paste. Verified 2026-10-08: ↓ then
    /// Return on `2. No, deny creation` → `User declined the tool call`, step status 7.
    ///
    /// When the screen cannot be read, or its last row does not read as a refusal, this presses
    /// nothing. Pressing Escape instead would cancel the user's whole turn on a guess.
    func deny(_ injector: TextInjecting) {
        guard let viewport = injector.readViewport(),
              let plan = Self.denyKeys(inViewport: viewport)
        else { return }
        for _ in 0..<plan.down { injector.sendArrowDown() }
        for _ in 0..<plan.up { injector.sendArrowUp() }
        injector.sendReturn()
    }

    /// How far to move from the focused row to the last row, or nil when that row is not a
    /// readable refusal.
    static func denyKeys(inViewport viewport: String) -> (down: Int, up: Int)? {
        let marker = GeminiTextChannel.marker
        guard let focused = ChoiceDialog.focusedRow(inViewport: viewport, marker: marker),
              let last = lastRow(inViewport: viewport),
              last.label.hasPrefix("No")
        else { return nil }
        let target = last.number - 1
        return target >= focused ? (target - focused, 0) : (0, focused - target)
    }

    /// The highest-numbered row of the LAST contiguously numbered run on screen.
    static func lastRow(inViewport viewport: String) -> (number: Int, label: String)? {
        var runs: [[(Int, String)]] = []
        var current: [(Int, String)] = []
        func close() {
            if current.count >= 2 { runs.append(current) }
            current = []
        }
        for line in viewport.components(separatedBy: "\n") {
            if let row = numbered(line) {
                if row.0 == (current.last?.0 ?? 0) + 1 {
                    current.append(row)
                } else {
                    close()
                    if row.0 == 1 { current = [row] }
                }
            } else if !current.isEmpty, !line.hasPrefix("     ") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A wrapped label continues under the label's column; anything else, a blank line
                // included, ends the list.
                close()
            }
        }
        close()
        guard let last = runs.last?.last else { return nil }
        return (last.0, last.1)
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        var rest = Substring(line).drop(while: { $0 == " " })
        if rest.first == GeminiTextChannel.marker { rest = rest.dropFirst().drop(while: { $0 == " " }) }
        let digits = rest.prefix(while: \.isNumber)
        guard let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        let label = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (number, label)
    }
}
