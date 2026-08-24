// Sources/FlightDeck/ChoiceDialog.swift
import Foundation

/// The interlock in front of an irreversible keypress: **does the row I am about to press
/// really say what I think it says?**
///
/// **This is deliberately not a reader, and the distinction is the whole design.** Everything
/// the answer path needs to *know* it already has from structured data. An `AskUserQuestion`'s
/// options come from the tool call's own input — `PromptQuestion`, off the transcript the Mac
/// already tails — and a permission dialog needs no text at all, because the phone offers only
/// Allow and Deny: Deny is one Escape, and Allow is the first row. Arrows are relative, so the
/// one fact that is genuinely only on the screen is **where the cursor currently is**.
///
/// So in principle every answer is reachable blind: count from the focused row, press Return.
/// What stops that being good enough is visible in the captures. `question-single` has three
/// options in its transcript and **five** rows on screen:
///
/// ```text
/// ❯ 1. Rust
///   2. Go
///   3. Swift
///   4. Type something.        ← in no transcript
///   5. Chat about this        ← in no transcript, and below a full-width rule
/// ```
///
/// claude appends those at display time. Today they land *after* the real options, so
/// "transcript index N" and "screen row N" happen to agree — and **nothing guarantees that**.
/// A row prepended in some future build, or those two moving, would make blind counting select
/// the wrong option silently; on a permission dialog that is a decision nobody made, taken
/// from a pocket. Hence `row(_:reads:inViewport:)`: the caller says which row it believes it
/// is on and what it believes that row says, and gets back yes or no. A no is a refusal, never
/// a cue to fall back to counting.
///
/// ## What a real screen looks like
///
/// Every rule here comes from captures — the six claude 2.1.241 screens in
/// `Tests/FlightDeckTests/Fixtures/Claude/` and, since, the five codex-cli 0.148.0 screens in
/// `Fixtures/Codex/` — not from either binary's string table. **Every structural rule below
/// held unmodified against codex's screens; only the marker glyph differed**, which is why it
/// is now a parameter and why nothing else here is per-agent:
///
/// - The marker is `❯`, but **its column varies by dialog kind** — column 2 for a permission
///   and for folder-trust, column 1 for an `AskUserQuestion`. claude positions with absolute
///   column moves (`ESC[2G❯ESC[4G1.ESC[7GYes`), so nothing may be pinned to an indent.
/// - **Every option is numbered, in both kinds.** A rule that compared a whole row against a
///   label would see `1. Rust` where it wants `Rust` and confirm nothing, ever.
/// - **Labels wrap; they never elide.** At 60 columns a long option runs onto continuation
///   lines indented to the label column — no `…` appears in any capture — so a row reads as
///   its own text *and* as that text joined with the lines under it.
///
/// **And the trap.** claude echoes the user's own prompt as `❯ Run this exact bash command …`
/// — a marker at column 1 with **no number after it** — so every real screen carries two `❯`.
/// Keying on the marker alone finds the echo and reports the wrong row. A row here is the
/// marker **and** a number **and** a consecutively numbered neighbour; an unnumbered line is
/// not a row and cannot join a list.
///
/// The distrust `InputBar` documents applies throughout. `ghostty_surface_read_text` returns
/// plain text with no cell attributes, so nothing here can tell a dialog from a paragraph that
/// happens to contain the same words — which is why every uncertain answer is `nil` or `false`
/// rather than a best guess.
enum ChoiceDialog {
    /// U+276F, the marker **claude** draws on the focused row.
    ///
    /// The same glyph `InputBar` keys on — which is precisely why that type must never be
    /// pointed at a dialog: it would read the selected option as a draft and Ctrl-U it. And
    /// why the marker alone is not enough here; see the trap above.
    static let claudeMarker: Character = "❯"

    /// U+203A, the marker **codex** draws on the focused row — a *different character*, and
    /// the whole reason `marker` is a parameter below rather than a constant.
    ///
    /// Three glyphs are in play on one machine and conflating any two of them is the hazard:
    /// claude's `❯` (U+276F), codex's `›` (U+203A), and a shell prompt's `>` (U+003E), which
    /// is what this machine's fish draws. Established by codepoint dump of the captured lines
    /// in `Fixtures/Codex/tui.captured.provenance.json`, not by eye — on screen they are
    /// indistinguishable. Note what follows for `InputBar`, which tests `first == ❯`: it
    /// matches *nothing at all* on a codex screen, so it never could have mistaken codex's
    /// composer for a draft. The near-miss `SessionStore.rename` records is about a SHELL
    /// theme drawing `❯`, and is unchanged by anything here.
    static let codexMarker: Character = "›"

    /// Which row of the select list on screen the cursor is on, or nil when no list can be
    /// read, none is marked, or two are.
    ///
    /// The one fact that exists nowhere but the screen. Arrows are relative, so this is what
    /// turns a target row into a number of key presses — and it is all `.allow` needs, since
    /// the approval row carries no label the Mac can check against.
    ///
    /// **`marker` has no default, deliberately.** Widening the parser to a second agent is
    /// the moment a defaulted `❯` stops being a convenience and becomes claude's grammar
    /// silently applied to somebody else's screen. Every caller is a driver stating its own
    /// agent's glyph; there is no generic answer to fall back to.
    static func focusedRow(inViewport viewport: String, marker: Character) -> Int? {
        guard let list = list(inViewport: viewport, marker: marker) else { return nil }
        let marked = list.indices.filter { list[$0].isMarked }
        // A list with no cursor, or with two, is not a dialog anyone is being offered.
        guard marked.count == 1 else { return nil }
        return marked.first
    }

    /// Whether row `index` of the select list on screen reads exactly as `label`.
    ///
    /// **The interlock.** False means refuse — the screen is not the one the caller thinks it
    /// is looking at — and never means "count instead". `index` out of range is false rather
    /// than a trap, because the list on screen is shorter than the caller expected exactly when
    /// something has gone wrong.
    static func row(
        _ index: Int, reads label: String, inViewport viewport: String, marker: Character
    ) -> Bool {
        guard let list = list(inViewport: viewport, marker: marker),
              list.indices.contains(index)
        else { return false }
        return list[index].reads(normalized(label))
    }

    // MARK: - Reading the screen

    /// One row of a select list.
    private struct Row {
        var number: Int
        var isMarked: Bool
        /// The row's own text, with the marker and the `N.` removed.
        var label: String
        /// Unnumbered lines under it: a wrapped label at a narrow width, or an
        /// `AskUserQuestion` option's description. **The screen does not distinguish them** —
        /// both sit at the label's column.
        var continuations: [String] = []

        /// Whether this row reads as `expected`: as its own text, or as its text joined with a
        /// run of the lines under it. A wrapped label reassembles that way; a description
        /// simply never matches, because it is never *joined to* the label it follows.
        func reads(_ expected: String) -> Bool {
            if label == expected { return true }
            var joined = label
            for continuation in continuations {
                joined += " " + continuation
                if joined == expected { return true }
            }
            return false
        }
    }

    /// A select-list row: optional marker, then `N.`, then the label.
    ///
    /// **The number is not optional, and that is the point.** See the trap in this type's
    /// documentation: an unnumbered line carrying the marker is claude echoing what the user
    /// typed, and reading it as an option reports a row nobody is on.
    ///
    /// A multi-select row additionally checkboxes — `❯ 1. [ ] Trail mix` — and that box is
    /// deliberately *not* stripped. This feature refuses to answer a multi-select
    /// (`PromptQuestion.multiSelectReason`), so a screen it cannot drive is a screen the
    /// interlock must decline to confirm.
    private static func parse(_ line: String, marker: Character) -> Row? {
        var rest = Substring(line).drop(while: { $0 == " " })
        var isMarked = false
        if rest.first == marker {
            isMarked = true
            rest = rest.dropFirst()
            guard rest.first == " " else { return nil }
            rest = rest.drop(while: { $0 == " " })
        }

        let digits = rest.prefix(while: { $0.isNumber })
        guard let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }

        let label = normalized(rest)
        guard !label.isEmpty else { return nil }
        return Row(number: number, isMarked: isMarked, label: label)
    }

    /// The select list on screen, or nil when there is none.
    ///
    /// The **last** one wins: a dialog can appear both live and as a scrollback echo of an
    /// earlier one above it. Same rule, and the same reason, as `InputBar.read` locking onto
    /// the last input box.
    ///
    /// A list is a run of **at least two** rows numbered `1.`, `2.`, `3.` … with no gap. That
    /// contiguity is the second half of the defence against the echoed-prompt trap, and it is
    /// what keeps a numbered paragraph from being confirmed: one row is a citation or a diff
    /// hunk, not a choice. A blank line, a rule, or any other unindented text ends the run —
    /// which is what splits an `AskUserQuestion`'s options from the `5. Chat about this` claude
    /// draws below the closing rule.
    private static func list(inViewport viewport: String, marker: Character) -> [Row]? {
        var lists: [[Row]] = []
        var current: [Row] = []

        for line in viewport.components(separatedBy: "\n") {
            if let row = parse(line, marker: marker) {
                if row.number == current.count + 1 {
                    current.append(row)
                    continue
                }
                // The numbering broke. Close what is open; this row may still head a new list.
                lists.append(current)
                current = row.number == 1 ? [row] : []
            } else if !current.isEmpty, let continuation = continuation(line, marker: marker) {
                current[current.count - 1].continuations.append(continuation)
            } else {
                lists.append(current)
                current = []
            }
        }
        lists.append(current)
        return lists.last(where: { $0.count >= 2 })
    }

    /// A line belonging to the row above it: indented, non-empty, and not a row itself.
    ///
    /// Indentation is what excludes the footer (`Enter to select · ↑/↓ to navigate …`) and the
    /// full-width `─` rules, which claude draws from column 1.
    private static func continuation(_ line: String, marker: Character) -> String? {
        guard line.first == " ", parse(line, marker: marker) == nil else { return nil }
        let text = normalized(line)
        return text.isEmpty ? nil : text
    }

    /// What two strings are compared as: whitespace runs collapsed, ends trimmed.
    ///
    /// A terminal lays a label out on a fixed grid, so the space between two words on screen
    /// may be one cell or three, and the separator claude draws after the marker is U+00A0
    /// rather than a space — which `Character.isWhitespace` covers and a trim of plain spaces
    /// would not.
    private static func normalized<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
