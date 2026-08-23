import FleetKit
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
/// **Nothing here parses a body.** A `.toolCall`'s text is pretty-printed JSON cut at the byte
/// cap wherever that lands, so it is structurally incomplete by design (see
/// `TimelineItem.Body.text`). `commandLine(for:)` reads *lines*, never structure.
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
            if !item.body.text.isEmpty { parts.append(clipped(item.body.text)) }
        }
        if let result {
            parts.append(result.body.isError ? "Failed" : "Output")
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
