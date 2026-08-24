import FleetKit
import MarkdownUI
import SwiftUI

/// The vocabulary the session screen draws with, in one place: what an item is called, which
/// symbol and tint stand for it, and how its bytes and its timestamp are said.
///
/// It is an `enum` of static functions rather than modifiers on a view for the reason
/// `SessionStatusGlyph.label(for:)` is: these are the decisions in the screen, and a decision
/// reachable without SwiftUI is a decision a test can run. Everything here is pure — no
/// environment, no state — so the row and the detail screen cannot describe the same item two
/// different ways two taps apart, which is the same disagreement that comment guards against.
///
/// **A MACHINE body never reaches the Markdown parser, and the one parse it does get is
/// attempted, never relied on.** A `.toolCall`'s text is pretty-printed JSON cut at the byte
/// cap wherever that lands, so it is structurally incomplete by design (see
/// `TimelineItem.Body.text`); a `.toolResult`'s is command output, where a leading `-` is a
/// deleted line and not a bullet.
///
/// So `rendersMarkdown(_:)` hands the Markdown parser only the two kinds a human wrote as
/// prose, and `jsonDocument(for:)` — the one function here that looks at structure at all —
/// is strict, whole-document, and returns `nil` far more often than not. `nil` means "draw the
/// text", which is what every other function here does. `commandLine(for:)` still reads
/// *lines*, never structure.
enum TimelineStyle {

    // MARK: What it is called

    /// The name at the head of a row, and the detail screen's title.
    ///
    /// The agent's own name is used for its prose when the fleet gave one, because "Claude"
    /// beside a message reads as a participant and "Assistant" reads as a category. An agent
    /// string this build has never heard of is still shown — capitalized, verbatim — for the
    /// same reason `WireSession.agent` is a `String` at all: the Mac may be newer, and the
    /// honest answer to a name we do not know is the name.
    static func heading(for item: TimelineItem, agent: String? = nil) -> String {
        switch item.kind {
        case .userTurn:
            return "You"
        case .assistantText:
            return agentName(agent) ?? "Assistant"
        case .thinking:
            return "Thinking"
        case .toolCall, .toolResult:
            // The tool's own name is the heading. A record that carried none still gets a
            // word rather than an empty header row.
            return item.body.tool ?? "Tool"
        case .prompt:
            // Slice 2 (spec §9) emits these. Worded exactly as `SessionStatusGlyph.label`
            // words the same state, so the fleet row and this screen agree.
            return "Waiting for you"
        case .systemNotice:
            // The wrapper's own name, humanised — "Task notification", "System reminder".
            // Named rather than lumped under one word because the reader's first question
            // about a row that is not their own words is which machine wrote it.
            guard let tag = item.body.tool, !tag.isEmpty else { return "Notice" }
            let words = tag.split(separator: "-").joined(separator: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        case .unknown:
            return "Unrecognized"
        }
    }

    /// `nil` for an agent the fleet did not name at all — an empty string included, which is
    /// what a wire field with nothing in it looks like.
    static func agentName(_ agent: String?) -> String? {
        guard let agent, !agent.isEmpty else { return nil }
        switch agent {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }

    // MARK: What it looks like

    /// The symbol that stands for a kind. Deliberately the same symbols the fleet list already
    /// uses where the state is the same one — `questionmark.circle.fill` for waiting and
    /// `circle.dotted` for "this build does not know what this is" — because a reader arrives
    /// here from that list and a second vocabulary for one state costs them a translation.
    static func symbol(for item: TimelineItem) -> String {
        switch item.kind {
        case .userTurn: return "person.fill"
        case .assistantText: return "sparkle"
        case .thinking: return "brain"
        case .toolCall, .toolResult: return symbol(forTool: item.body.tool)
        case .prompt: return "questionmark.circle.fill"
        case .systemNotice: return "gearshape.fill"
        case .unknown: return "circle.dotted"
        }
    }

    /// A tool's own symbol, so a screenful of tool cards is scannable by shape rather than by
    /// reading every name. An unrecognised tool — and there will be many, since tools are
    /// whatever the agent has been given — gets the generic one rather than nothing.
    static func symbol(forTool tool: String?) -> String {
        switch tool {
        case "Bash", "Shell", "shell", "local_shell": return "terminal.fill"
        case "Read", "read_file", "NotebookRead": return "doc.text.fill"
        case "Write", "Edit", "MultiEdit", "apply_patch": return "square.and.pencil"
        case "Grep", "Glob", "Search": return "magnifyingglass"
        case "Task", "Agent": return "person.2.fill"
        case "WebFetch", "WebSearch", "web_search": return "globe"
        case "TodoWrite": return "checklist"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    /// The tint for a kind's symbol and heading. Semantic colours only, so both themes resolve
    /// them — an explicit RGB that reads on white disappears on black, and this screen ships
    /// in both.
    static func tint(for item: TimelineItem) -> Color {
        if item.body.isError { return .red }
        switch item.kind {
        case .userTurn: return .accentColor
        case .assistantText: return .primary
        case .thinking: return .secondary
        case .toolCall, .toolResult: return .green
        case .prompt: return .orange
        case .systemNotice: return .secondary
        case .unknown: return .secondary
        }
    }

    // MARK: What it says

    /// The one line under a tool's name.
    ///
    /// The Mac's own `summary` first — that field exists precisely because a tool call's text
    /// is JSON and `{` is not a useful row. Without one, the first line of the body that
    /// carries anything, **skipping a bare JSON delimiter**, which is what the first line of a
    /// pretty-printed object always is. Empty when there is nothing worth putting there, and
    /// the card then shows the tool's name alone rather than a line reading `{`.
    static func commandLine(for item: TimelineItem) -> String {
        if let summary = item.body.summary, !summary.isEmpty { return summary }
        for line in item.body.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Closing delimiters as well as opening ones: a call whose whole input is
            // `{}` pretty-prints to two lines, and a card reading `}` is noise with a
            // border around it. Nothing usable resolves to nothing, and the row says so.
            if trimmed.isEmpty || trimmed == "{" || trimmed == "["
                || trimmed == "}" || trimmed == "]" { continue }
            return trimmed
        }
        return ""
    }

    /// Which record supplies a tool row's OUTPUT panel — **and the reason it is not simply the
    /// paired result.**
    ///
    /// A `.toolResult` reaches a row on its own whenever its call is not in the feed, which one
    /// page boundary is enough to cause. Read through `commandLine` instead, that row showed
    /// the *first line* of a 64 KB file read and silently dropped the rest: `Read`, one line,
    /// `68 KB more`, and nothing to say that what was on screen was a fragment of a fragment.
    /// The code read as correct; the render of the end of a real conversation is what showed
    /// it. A result is output wherever it lands.
    static func outputBody(of item: TimelineItem, result: TimelineItem?) -> TimelineItem? {
        item.kind == .toolResult ? item : result
    }

    /// `HH:MM` in the reader's own locale, from the string the agent wrote.
    ///
    /// The Mac never parses this (see `TimelineItem.at`), so the client is the first thing to
    /// look at it, and a string it cannot read gets `nil` — the row then shows no time at all
    /// rather than a formatted lie about a date nobody has.
    static func time(_ raw: String?) -> String? {
        guard let raw, let date = date(raw) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// The whole instant, for the detail screen's header.
    static func timestamp(_ raw: String?) -> String? {
        guard let raw, let date = date(raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    /// Both spellings ISO-8601 arrives in. Claude writes fractional seconds and codex does
    /// not, and `ISO8601DateFormatter` fails the one it was not configured for rather than
    /// coping — so both are tried, and neither matching means `nil`.
    private static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// The chip under a body the Mac cut. `truncatedBytes > 0` means the body on screen is a
    /// fragment, and a fragment that looks exactly like a whole result is the failure that
    /// field exists to prevent — so the shortfall is said on the ROW, not only one tap deeper.
    static func truncationChip(_ dropped: Int) -> String? {
        guard dropped > 0 else { return nil }
        return "\(bytes(dropped)) more"
    }

    /// The two numbers, on the detail screen. "Truncated" on its own does not tell a reader
    /// whether they are missing a line or a megabyte, and that is the difference between
    /// reading on and walking to the Mac.
    static func truncationNotice(shown: Int, dropped: Int) -> String {
        "Showing the first \(bytes(shown)) of \(bytes(shown + dropped)). "
            + "Open this session on your Mac to see the rest."
    }

    // MARK: What is prose and what is machine text

    /// Whether a body is read as **Markdown** or shown exactly as it arrived.
    ///
    /// The `true` arm is the smaller claim: both agents write Markdown, and the transcripts on
    /// this machine say how much of it — of 7,944 real assistant messages, 51.6% carry inline
    /// code, 36.5% bold, and 14.9% a block construct (heading, list, fence, table, quote or
    /// rule) that renders as literal syntax without a parser. User turns are not a lesser case:
    /// 29.9% of them carry a block construct too, because that is how people write briefs.
    ///
    /// **The `false` arm is the load-bearing one**, and each of its five cases is a different
    /// way to be wrong:
    ///
    /// - `.toolCall` and `.toolResult` are the "render it, never parse it" rule itself (see
    ///   `TimelineItem.Body.text`). A diff's leading `-` is a deleted line, not a bullet; a
    ///   `***` in a stack trace is not a horizontal rule; `__init__` is not emphasis; and the
    ///   indentation of a JSON input the byte cap cut mid-object is the only structure it has
    ///   left, which a Markdown parser reflows away. The bodies most worth reading are exactly
    ///   the truncated ones, so this is not an edge case.
    /// - `.unknown` is machine text from a newer Mac by definition — the screen already says it
    ///   is being shown verbatim, and reflowing it would make that sentence false.
    /// - `.thinking` is styled *as a whole* — italic, secondary, clamped to six lines — and
    ///   that whole-block treatment is the only thing separating it from an answer. Per-block
    ///   Markdown styling would undo it. It is also the one kind no evidence was available for:
    ///   the transcripts on this machine store no `thinking` records at all.
    /// - `.prompt` is a sentence the Mac composed, not something an agent wrote (spec §9).
    static func rendersMarkdown(_ item: TimelineItem) -> Bool {
        switch item.kind {
        case .assistantText, .userTurn: return true
        case .thinking, .toolCall, .toolResult, .prompt, .unknown, .systemNotice: return false
        }
    }

    /// The same words, without the syntax that was carrying them.
    ///
    /// **VoiceOver has the same bug the screen had, one layer down, and worse.** A raw body
    /// reaches a label as it was written, so `**Fixed**` is announced with its asterisks and
    /// `## Baselines` opens on two number signs — and a listener cannot skim past that the way
    /// a reader skims past a stray `*`. Flattened through the same parser that draws the view,
    /// so the label and the row can never disagree about what the message says.
    ///
    /// Machine text is returned untouched, for the reason `rendersMarkdown(_:)` gives: a diff
    /// read aloud with its `-` markers stripped is a diff that says the opposite of what it is.
    static func spoken(_ item: TimelineItem) -> String {
        guard rendersMarkdown(item) else { return item.body.text }
        let plain = MarkdownContent(item.body.text).renderPlainText()
        // cmark returns the empty string for a document it could make nothing of. The raw text
        // is worse than the flattened text and infinitely better than silence.
        return plain.isEmpty ? item.body.text : plain
    }

    // MARK: How much of a body the row shows

    /// The prose column, in characters. 370pt of row at `.body` fits about 42 of them.
    ///
    /// **Measured, not guessed** — `UIFont.preferredFont(forTextStyle: .body)` laid out against
    /// the row's real width in the offscreen harness — and it is only ever used to *estimate*.
    /// It is a conservative one: real prose fits ten to fifteen per cent more than this, so the
    /// count comes out high.
    ///
    /// **Nothing is laid out from it, and that is what makes its inaccuracy harmless.** Both
    /// halves of the ceiling — whether a body is over it (`exceeds(_:_:)`) and where the
    /// collapsed row stops (`firstLines(_:of:)`) — are the same count of the same characters, so
    /// an estimate that runs high or low moves *where* the cut lands and can never produce a cut
    /// with no More link on it, or a More link with nothing behind it. It was not always so:
    /// `proseText(for:expanded:)` records what happened when the cut was a height instead.
    static let proseColumns = 42

    /// The most of one message a row will ever draw: 120 lines, about four screenfuls of
    /// phone.
    ///
    /// **Not a compromise on "prose renders in full" — it is what stops one message from
    /// being the whole screen.** The corpus on this machine says how rarely it bites: of 7,987
    /// real assistant messages, 98.8% are under it and the longest is 312 lines. Of 2,133 real
    /// user turns only 82.3% are, and that asymmetry is the case it exists for — a user turn
    /// is where a whole file, a stack trace or a 64 KB paste arrives. The largest turn on this
    /// machine is 89 KB; cut to `TimelineLimits.maxItemBytes` it is still upwards of fifteen
    /// hundred lines, which is fifty screenfuls with the conversation nowhere near it.
    ///
    /// A body that hits it is cut mid-line and carries a **More** link at the cut, so the
    /// ceiling is the one case where a prose row still has more to show — and the only clamp on
    /// this screen the reader is handed a way out of.
    static let proseCeilingLines = 120

    /// Whether a body runs past `limit` lines in the prose column — hard breaks plus wraps.
    ///
    /// **It stops the moment the answer is known**, which is what makes it safe to call from a
    /// row body. A 64 KB paste costs the same as a six-line answer: the loop cannot run past
    /// `(limit + 1) × columns` characters before it has its `true`, so the work is bounded by
    /// the ceiling rather than by the body. A `String.count` over 64 KB is grapheme-walking on
    /// the scroll path, and this list can be hundreds of rows long.
    static func exceeds(_ limit: Int, _ text: String, columns: Int = proseColumns) -> Bool {
        var lines = 1
        var column = 0
        for character in text {
            if character == "\n" {
                lines += 1
                column = 0
            } else {
                column += 1
                if column > columns {
                    lines += 1
                    column = 1
                }
            }
            if lines > limit { return true }
        }
        return false
    }

    /// How many lines of a body the ROW draws, or `nil` for one it draws WHOLE.
    ///
    /// **Prose is drawn whole, and that is the whole of this change.** It used to be cut at
    /// fourteen lines' worth of height with a chevron into a screen that showed the same words
    /// again — and 75.7% of real assistant messages are under fourteen lines, so for three
    /// messages in four the chevron led to nothing at all and for the fourth it led to reading
    /// the answer somewhere other than the conversation it belongs to.
    ///
    /// Everything that is not prose keeps its clamp, and each one keeps it for its own reason:
    ///
    /// - `.thinking` is styled *as a whole* — italic, secondary, six lines — and that
    ///   whole-block treatment is the only thing separating it from an answer. It is also not
    ///   what a reader came for; see `rendersMarkdown(_:)`, which refuses it for the same
    ///   reason.
    /// - `.prompt` and `.unknown` are machine text (spec §9, and a kind from a newer Mac), and
    ///   a tool body is 64 KB of command output at the per-item cap. Fourteen lines of that is
    ///   enough to recognise it; the whole of it inline would bury the conversation, which is
    ///   the case the detail screen exists for.
    ///
    /// A tool row never reaches this — its card has two clamps of its own, in
    /// `TimelineRow.toolCard` — and the answer it would get is the conservative one anyway.
    ///
    /// **`expanded` moves the ceiling and nothing else.** It is the reader's own answer to the
    /// one clamp they are offered a way out of: a row past `proseCeilingLines` draws a More
    /// link at the cut and opens *in place* when it is tapped. The other three clamps ignore it
    /// on purpose — a thinking block's six lines are a style rather than a shortfall, and a
    /// `.prompt` or an `.unknown` is machine text with a screen of its own one tap away — so a
    /// `true` arriving on one of those kinds must change nothing, which is what the `switch`
    /// below says by not reading the flag in those arms.
    static func proseLineLimit(for item: TimelineItem, expanded: Bool = false) -> Int? {
        switch item.kind {
        case .assistantText, .userTurn:
            guard !expanded else { return nil }
            return exceeds(proseCeilingLines, item.body.text) ? proseCeilingLines : nil
        case .thinking:
            return 6
        case .prompt, .unknown, .toolCall, .toolResult, .systemNotice:
            return 14
        }
    }

    /// The prose a row actually DRAWS: the whole body, or the first `proseCeilingLines` lines
    /// of it.
    ///
    /// **The collapsed row is given a shorter document, rather than the whole one behind a
    /// height clamp, and a render is why.** The clamp was `maxHeight: 23 × 120` with the
    /// overflow clipped — two different measurements of "a hundred and twenty lines", and they
    /// disagree: `exceeds(_:_:)` counts a wrap at 42 characters, and real prose at 370pt in the
    /// system font fits more than that, so the estimate over-counts lines by ten to fifteen per
    /// cent. A real message the estimate called 134 lines laid out at **2,770.67pt collapsed
    /// and 2,770.67pt expanded** — the same number, because the clamp never bit — so the row
    /// drew a More link and tapping it moved nothing at all. Four of the nine over-ceiling
    /// messages in this machine's transcripts sit in that dead band, so it was not an edge
    /// case. `ui-renders/expand/over-ceiling-*.png` is what showed it; with the text cut, the
    /// same message is 2,527pt collapsed and 2,770.67pt expanded.
    ///
    /// Cutting the text instead makes the two agree by construction: if the estimate says the
    /// body is over, the collapsed document is strictly shorter than the whole one, so More
    /// always has something to add. It is also less work, not more — a collapsed row parses and
    /// lays out a fraction of a 64 KB body instead of laying all of it out and throwing most of
    /// it away.
    ///
    /// **Cutting a Markdown document mid-line is safe, which is not obvious.** The dangerous
    /// case looks like an unterminated fence — but a fence opened before the cut and closed
    /// after it renders its contents as code up to the end of the truncated document, which is
    /// exactly what the whole document renders up to that same point. A cut table is a shorter
    /// table, and a cut heading is a heading. Nothing changes meaning.
    static func proseText(for item: TimelineItem, expanded: Bool = false) -> String {
        guard rendersMarkdown(item),
              let limit = proseLineLimit(for: item, expanded: expanded) else {
            return item.body.text
        }
        return firstLines(limit, of: item.body.text)
    }

    /// The first `limit` lines of `text` in the prose column — hard breaks plus wraps, counted
    /// exactly as `exceeds(_:_:)` counts them, because a disagreement between the two is a row
    /// that offers More and has nothing to show.
    ///
    /// **It stops at the cut**, so a 64 KB paste costs the same as a six-line answer: the walk
    /// cannot pass `(limit + 1) × columns` characters. The cut lands wherever the count runs
    /// out, mid-line and mid-word on purpose — a row that ends on a whole line looks finished,
    /// and one that stops in the middle of a sentence cannot be read as the end of a message.
    static func firstLines(_ limit: Int, of text: String, columns: Int = proseColumns) -> String {
        var lines = 1
        var column = 0
        for index in text.indices {
            if text[index] == "\n" {
                lines += 1
                column = 0
            } else {
                column += 1
                if column > columns {
                    lines += 1
                    column = 1
                }
            }
            if lines > limit { return String(text[text.startIndex..<index]) }
        }
        return text
    }

    /// Whether this row carries a **More** link at the cut — that is, whether it is prose the
    /// ceiling actually bit.
    ///
    /// **The one clamp with a way out, and the way out is here rather than a push.** It used to
    /// be a chevron into the detail screen, which is the wrong shape twice over: the screen
    /// repeated the words the row had already drawn a hundred and twenty lines of, and a `List`
    /// floats a link's disclosure indicator at the row's *vertical centre* — two screenfuls
    /// above the cut on a row this tall, pointing at nothing. So the rest of the message opens
    /// where it stopped, and `opensDetail(_:)` now answers `false` for every prose kind that
    /// renders as Markdown.
    ///
    /// Deliberately independent of the expansion state: a row that can expand is a row that can
    /// collapse again, and the link is drawn in both states (More, then Less). What it must
    /// never do is appear on a body that had nothing cut, which is what the `nil` from
    /// `proseLineLimit(for:)` — asked **unexpanded**, since an expanded row's limit is `nil` by
    /// construction — rules out.
    static func expandsInPlace(_ item: TimelineItem) -> Bool {
        rendersMarkdown(item) && proseLineLimit(for: item) != nil
    }

    /// Whether tapping this row leads anywhere — that is, whether the detail screen has
    /// anything on it the row does not already show.
    ///
    /// **A row that shows everything gets no chevron and no tap**, and the alternatives were
    /// both worse. A chevron onto a screen with the identical words is a promise of more that
    /// is not there; a row that opens one with no chevron is a hidden gesture, and this app has
    /// already paid for the mirror of that — "tapping a session does nothing" came back three
    /// times on the fleet list, and it was true. What the detail screen still offered such a
    /// row was Copy, so Copy moved onto the row itself (`rowCopyText(for:)`).
    ///
    /// **No prose row leads anywhere now, not even one past the ceiling**, and that is one
    /// decision with two halves. A long answer opens where it stopped instead
    /// (`expandsInPlace(_:)`), so the screen one tap away would once again be the same words —
    /// and, mechanically, a `NavigationLink` eats the tap on any control inside it, so a row
    /// that is a link cannot also carry a More button. The `.assistantText`/`.userTurn` arm is
    /// therefore an unconditional `false`, not a clamp read.
    ///
    /// The three that stay are the three with no way out on the row: `.thinking` is six lines
    /// of a block styled as a whole, and `.prompt` and `.unknown` are machine text the screen
    /// says it is showing verbatim. A tool row always leads somewhere too: its card is two
    /// clamped slots of machine text, its input is frequently a JSON tree, and either half may
    /// have been cut at the byte cap.
    static func opensDetail(_ item: TimelineItem) -> Bool {
        switch item.kind {
        case .toolCall, .toolResult:
            return true
        case .assistantText, .userTurn:
            return false
        case .thinking, .prompt, .unknown, .systemNotice:
            return proseLineLimit(for: item) != nil
        }
    }

    /// What a long press on the ROW puts on the clipboard, or `nil` for a row that leads to a
    /// screen with a Copy button of its own.
    ///
    /// Two ways to copy one body a gesture apart is how a reader ends up unsure which of them
    /// took, so this is the exact complement of `opensDetail(_:)` — which now means every prose
    /// row has it, including the long ones that used to hand the job to the detail screen.
    ///
    /// **The whole body, never the visible part.** A collapsed row is drawing a hundred and
    /// twenty lines of a message; what a reader wants on the clipboard is the message. An empty
    /// body answers `nil` rather than putting a Copy item on a menu that would clear the
    /// pasteboard.
    static func rowCopyText(for item: TimelineItem) -> String? {
        guard !opensDetail(item), !item.body.text.isEmpty else { return nil }
        return item.body.text
    }

    // MARK: What a body IS

    /// The body as a JSON tree, when drawing it as one is better than drawing the text.
    ///
    /// Three gates, and each one is a real body this has to say no to:
    ///
    /// - **The kind.** Only a tool call or a tool result. An `.unknown` body may well be JSON —
    ///   the fixture's is — but that block's whole promise is that it shows what arrived
    ///   "exactly as it arrived", and a tree is an interpretation. Prose is not JSON and asking
    ///   is a waste.
    /// - **It parses.** Strictly, whole, or not at all. This is the gate a truncated body fails:
    ///   the Mac cuts at `TimelineLimits.maxItemBytes` mid-object, mid-string, mid-escape, so
    ///   `truncatedBytes > 0` almost always lands here — and lands here on its own, without a
    ///   separate rule about truncation, which is why there is not one.
    /// - **It has structure.** An object or an array. A result whose entire text is `42` or
    ///   `"done"` is legal JSON and a one-node tree of it is worse than the text it replaces.
    ///
    /// Everything that fails renders exactly as it did before this existed.
    static func jsonDocument(for item: TimelineItem) -> JSONValue? {
        switch item.kind {
        case .toolCall, .toolResult: return JSONValue.document(from: item.body.text)
        default: return nil
        }
    }

    /// What sits left of the colon: an object key, or an array position.
    static func jsonLabel(for row: JSONTreeRow) -> String {
        if let key = row.key { return key }
        if let index = row.index { return String(index) }
        return ""
    }

    /// What sits right of it.
    ///
    /// A container says how many children it has in BOTH states, not just collapsed. Chrome can
    /// afford to drop the count when it opens a node because the closing brace is a line you
    /// can see; here the panel is 360pt of wrapped prose and the count is the only thing
    /// telling a reader whether they have seen all four options or scrolled past one.
    ///
    /// Strings keep their quotes. The tree tints by type, but a tint is not readable in
    /// greyscale or by a reader who cannot distinguish it, and `"true"` and `true` are two
    /// different answers to a tool's flag.
    static func jsonValueText(for value: JSONValue) -> String {
        switch value {
        case .object(let members): return members.isEmpty ? "{}" : "{\(members.count)}"
        case .array(let elements): return elements.isEmpty ? "[]" : "[\(elements.count)]"
        case .string(let text): return "\"\(text)\""
        case .number(let lexeme): return lexeme
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// The tint for a leaf, borrowed from the colour family every JSON viewer already uses so a
    /// reader arriving from a browser's network tab is not learning a second one. Semantic
    /// colours only — the same rule, and the same reason, as `tint(for:)`: this screen ships in
    /// both themes and an explicit RGB that reads on white disappears on black.
    static func jsonTint(for value: JSONValue) -> Color {
        switch value {
        case .string: return .primary
        case .number: return .blue
        case .bool: return .purple
        case .null: return .secondary
        case .object, .array: return .secondary
        }
    }

    /// One row of the tree, as one sentence.
    ///
    /// A container says its size and whether it is open, because the row is a button and a
    /// VoiceOver user has no chevron to look at. **The value is capped** for the same reason a
    /// whole row's label is: an `AskUserQuestion` option's `description` runs past three hundred
    /// characters, and a tree of them is forty rows of that.
    static func accessibilityLabel(forJSON row: JSONTreeRow) -> String {
        // Spoken 1-based. "Item 0" is a programmer's index read aloud to someone counting.
        let name = row.key ?? row.index.map { "Item \($0 + 1)" } ?? ""
        var parts = name.isEmpty ? [] : [name]
        switch row.value {
        case .object(let members):
            parts.append("Object, \(members.count) \(members.count == 1 ? "entry" : "entries")")
        case .array(let elements):
            parts.append("Array, \(elements.count) \(elements.count == 1 ? "item" : "items")")
        case .string(let text):
            parts.append(text.isEmpty ? "Empty text" : clipped(text))
        case .number(let lexeme):
            parts.append(lexeme)
        case .bool(let flag):
            parts.append(flag ? "true" : "false")
        case .null:
            parts.append("null")
        }
        if row.isContainer && row.childCount > 0 {
            parts.append(row.isExpanded ? "Expanded" : "Collapsed")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: What VoiceOver hears

    /// One sentence for a whole row, because the alternative — SwiftUI's own combining — reads
    /// a symbol, a heading, a chip and two monospaced panels as five separate stops on a list
    /// that may be hundreds of rows long.
    ///
    /// **The body is capped.** A `.toolResult` can be 64 KB, and a label that long is a
    /// VoiceOver user trapped on one row with no way to skip to the next.
    static func accessibilityLabel(
        for item: TimelineItem, result: TimelineItem? = nil, agent: String? = nil
    ) -> String {
        var parts = [heading(for: item, agent: agent)]
        switch item.kind {
        case .toolCall:
            // The command, not the JSON around it — the row says the same thing.
            let line = commandLine(for: item)
            if !line.isEmpty { parts.append(clipped(line)) }
        case .toolResult:
            // A result standing on its own is OUTPUT, and reading it as a command line would
            // announce the first line of a file read as though it were the whole row. Same
            // rule, same reason, as `TimelineRow.output`.
            if !item.body.text.isEmpty {
                parts.append("Output")
                parts.append(clipped(item.body.text))
            }
        default:
            // Prose, said the way it is now drawn: flattened through the Markdown parser, so a
            // listener hears "Fixed the parser" rather than four asterisks and a backtick.
            if !item.body.text.isEmpty { parts.append(clipped(spoken(item))) }
        }
        if let result {
            parts.append(result.body.isError ? "Failed" : "Output")
            // Never flattened — a result is machine text whatever the row it landed in.
            if !result.body.text.isEmpty { parts.append(clipped(result.body.text)) }
        } else if item.body.isError {
            parts.append("Failed")
        }
        let dropped = item.body.truncatedBytes + (result?.body.truncatedBytes ?? 0)
        if dropped > 0 { parts.append("Truncated, \(bytes(dropped)) not shown") }
        return parts.joined(separator: ". ")
    }

    /// 240 characters is about fifteen seconds of speech — long enough to know what a row is,
    /// short enough to move on from.
    static func clipped(_ text: String, limit: Int = 240) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit) + "…"
    }
}
