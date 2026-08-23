import FleetKit
import SwiftUI

/// One entry in a conversation, as a row.
///
/// **Not a list of monospaced strings, and not chat bubbles either.** The first draft of this
/// screen was a `List` of near-raw text with a tool's pretty-printed JSON input dumped into a
/// row, and it was rejected on sight. What replaced it was chosen by rendering three whole
/// screens offscreen and looking at them (see docs/MOBILE.md): a dense terminal transcript, a
/// chat thread, and this — a structured feed where every entry has a named, tinted header and
/// its body is typeset for what it *is*.
///
/// The two things the renders settled, neither of which was visible in the code:
///
/// - **Monospace is for machine text only.** A long assistant message set in monospace at body
///   size fits about 38 characters to the line on a 393pt phone and turns into a grey wall.
///   Prose is set in the system font here; the terminal idiom (spec §7) is kept where it
///   carries meaning — commands, output, diffs — where column alignment is the whole point.
/// - **A call and its result belong in one card.** Rendered as two sibling rows they read as
///   two unrelated events, and a `⎿` marker did not join them across a row separator. Folded
///   into one card, a command and what it printed are one thing on screen, which is what they
///   are. `SessionTimelineScreen.entries(from:)` does the folding, on `callID` and never on
///   position.
///
/// **The text is rendered, never parsed — in the ROW.** A body is cut at the per-item byte cap
/// wherever that lands (mid-object, mid-string, mid-escape), so a truncated tool input is not
/// parseable JSON by design, and a row that depended on decoding one would show nothing for
/// exactly the largest inputs. `TimelineStyle.commandLine` reads *lines* for that reason.
///
/// The detail screen one tap away does parse, because there it can afford to fail: it draws a
/// tree when the whole body decodes and the same plain text as this row when it does not. That
/// is a screen with room for both; a three-line card is not.
struct TimelineRow: View {
    let item: TimelineItem
    /// The `.toolResult` that answers `item`, folded into this row. Nil for a prose kind, for
    /// a call still running, and for a call whose result fell the other side of a page.
    var result: TimelineItem?
    /// The agent that wrote this, so its prose is headed with its name. Nil where the fleet
    /// no longer lists the session.
    var agent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            chips
        }
        .padding(.vertical, 2)
        // One stop per row, one sentence. Combining would read a symbol, a heading, a chip and
        // two monospaced panels as five stops on a list hundreds of rows long.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            TimelineStyle.accessibilityLabel(for: item, result: result, agent: agent)
        )
    }

    // MARK: Header

    /// Symbol, name, and the time it happened. This is the line that makes the screen
    /// scannable: the renders showed that without it every row's first line is content, and a
    /// screenful of content with no labels is exactly the "text and raw JSON" that was
    /// rejected.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: TimelineStyle.symbol(for: item))
                .font(.caption2)
                .foregroundStyle(TimelineStyle.tint(for: item))
                // Fixed, so the headings line up down the list whatever symbol is beside
                // them — the same problem, and the same fix, as `SessionStatusGlyph.glyph`.
                .frame(width: 16, alignment: .center)
            Text(TimelineStyle.heading(for: item, agent: agent))
                // Every `Text` names its own font. `List { … }.font(…)` does not reach row
                // content — some rows inherited it and their neighbours did not, in the same
                // list, which is what sent `FleetListScreen` back from testing.
                .font(.caption.weight(.semibold))
                .foregroundStyle(headingColor)
            if isFailed { errorChip }
            Spacer(minLength: 8)
            if let time = TimelineStyle.time(item.at) {
                Text(time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// `.primary` for an agent's own prose rather than its tint, because that heading sits
    /// above the text a reader is actually here for and a coloured name pulls the eye off it.
    private var headingColor: Color {
        item.kind == .assistantText ? .primary : TimelineStyle.tint(for: item)
    }

    private var isFailed: Bool { item.body.isError || result?.body.isError == true }

    private var errorChip: some View {
        Text("Error")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.red.opacity(0.12), in: Capsule())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .toolCall, .toolResult:
            toolCard
        default:
            prose
        }
    }

    /// Prose, in the system font, at the size its kind deserves.
    ///
    /// A user's own turn gets a tinted panel — it is the only kind a reader writes, and in a
    /// long transcript those are the landmarks they scroll to find. That is the one idea taken
    /// from the chat-thread render; the bubble, the tail and the right alignment are not, since
    /// they cost half the width of every line and this screen holds command output.
    @ViewBuilder
    private var prose: some View {
        if !item.body.text.isEmpty {
            Text(item.body.text)
                .font(proseFont)
                .italic(item.kind == .thinking)
                .foregroundStyle(proseColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                // Clamped, and the row taps through for the rest. Unclamped, one long
                // assistant message fills the screen and the conversation around it is
                // invisible — which the renders showed and the code did not.
                .lineLimit(proseLineLimit)
                .padding(item.kind == .userTurn ? 10 : 0)
                .background(userTurnBackground)
        }
    }

    private var proseFont: Font {
        switch item.kind {
        case .thinking: return .callout
        case .unknown: return .system(.footnote, design: .monospaced)
        default: return .body
        }
    }

    private var proseColor: Color {
        item.kind == .thinking || item.kind == .unknown ? .secondary : .primary
    }

    private var proseLineLimit: Int {
        switch item.kind {
        // A reader's own prompt is short and is the thing they are looking for; clamping it
        // hides the one row on the screen they already know the shape of.
        case .userTurn: return 20
        case .thinking: return 6
        default: return 14
        }
    }

    @ViewBuilder
    private var userTurnBackground: some View {
        if item.kind == .userTurn {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        }
    }

    // MARK: The tool card

    /// A command and what it printed, as one object.
    ///
    /// Monospaced, because this is the content the terminal idiom is actually *for*: a
    /// column-aligned `ls`, a diff, a stack trace. The surface is what separates it from the
    /// prose above and below it without a rule or a bubble.
    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.kind == .toolCall {
                Text(commandText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(commandText == Self.emptyBody ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            if let output, !output.body.text.isEmpty {
                if item.kind == .toolCall { Divider() }
                Text(output.body.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(output.body.isError ? .red : .secondary)
                    // Six lines of output is enough to recognise it and not enough to bury
                    // the conversation; the row taps through to all of it.
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFailed ? Color.red.opacity(0.35) : Color.clear)
        )
    }

    private var output: TimelineItem? { TimelineStyle.outputBody(of: item, result: result) }

    /// The command slot's text. A tool call whose input the Mac summarized shows the summary;
    /// one it did not shows the first line of the body that carries anything. A call with
    /// neither — an input of `{}`, or a record with no body at all — says so rather than
    /// collapsing the card to a bar of empty grey.
    private var commandText: String {
        let line = TimelineStyle.commandLine(for: item)
        return line.isEmpty ? Self.emptyBody : line
    }

    private static let emptyBody = "(no input)"

    // MARK: Chips

    /// What the Mac cut, said on the row.
    ///
    /// A tool result truncated at the item cap looks exactly like a short one, and a reader who
    /// does not know the output was cut will act on a partial file read as though it were
    /// whole. Both halves of a folded card are counted, since either can be the one that was
    /// cut.
    @ViewBuilder
    private var chips: some View {
        let dropped = item.body.truncatedBytes + (result?.body.truncatedBytes ?? 0)
        if let chip = TimelineStyle.truncationChip(dropped) {
            Label(chip, systemImage: "scissors")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
