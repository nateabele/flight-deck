import FleetKit
import MarkdownUI
import SwiftUI
import UIKit

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
/// **A MACHINE body is rendered, never parsed — in the ROW.** A body is cut at the per-item
/// byte cap wherever that lands (mid-object, mid-string, mid-escape), so a truncated tool
/// input is not parseable JSON by design, and a row that depended on decoding one would show
/// nothing for exactly the largest inputs. `TimelineStyle.commandLine` reads *lines* for that
/// reason.
///
/// The detail screen one tap away does parse, because there it can afford to fail: it draws a
/// tree when the whole body decodes and the same plain text as this row when it does not.
/// That is a screen with room for both; a three-line card is not.
///
/// Prose is the exception, and only prose: `.assistantText` and `.userTurn` are drawn as the
/// Markdown they were written in, because half of every real assistant message carries inline
/// code and one in seven a heading, a list or a fence that reads as literal syntax without a
/// parser. `TimelineStyle.rendersMarkdown` is the whole of that boundary, and its `false` arm
/// is why it is a function and not an `if`.
struct TimelineRow: View {
    let item: TimelineItem
    /// The `.toolResult` that answers `item`, folded into this row. Nil for a prose kind, for
    /// a call still running, and for a call whose result fell the other side of a page.
    var result: TimelineItem?
    /// The agent that wrote this, so its prose is headed with its name. Nil where the fleet
    /// no longer lists the session.
    var agent: String?
    /// Whether this row is currently drawing the whole of a message the ceiling cut.
    ///
    /// **Passed in, never `@State` here.** The set of open rows lives on the screen
    /// (`SessionTimelineScreen.Expansion`), and this row is a pure function of the flag it is
    /// handed — so nothing a `List` does to its cells can reach it, and the whole decision is
    /// drivable by a test with no window.
    ///
    /// The obvious alternative was a `@State` here, on the argument that a lazy `List` throws
    /// rows away and rebuilds them. That argument turns out to be **false on this SwiftUI**, and
    /// it was measured rather than assumed: `ProseExpansionRecyclingTests` scrolls a row six
    /// thousand points off screen and back at 30, 200 and 600 rows, and a probe row's own
    /// `@State` comes back intact every time — the cell is recycled, the state box is not. So
    /// this is not a rescue; it is a row that cannot be wrong about something it does not own.
    var isExpanded: Bool = false
    /// What More and Less do. `SessionTimelineScreen` is the only caller on the screen and it
    /// always passes one; it is optional so a row can be built with no screen behind it at all,
    /// which is what the offscreen harnesses and the filler rows in the tests do.
    var toggleExpanded: (() -> Void)?

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
        // The one thing the detail screen still offered a row that shows everything, put where
        // that row can reach it — and applied AFTER the label, so VoiceOver hangs the action
        // off the one element this row combines into rather than off a child it ignores.
        // Only on such a row: everywhere else the screen one tap away has a Copy button per
        // block, and two ways to copy one body a gesture apart is how a reader ends up unsure
        // which of them took. `rowCopyText(for:)` is that boundary.
        .modifier(CopyAction(text: TimelineStyle.rowCopyText(for: item)))
        // And the same for More: the row combines its children away, so the button below is
        // not reachable by touch exploration at all and the only way to offer it is an action
        // on the combined element. Named for what the next tap DOES, like the button is.
        .modifier(ExpandAction(name: expandActionName, action: toggleExpanded))
    }

    /// `nil` on every row with nothing cut, which is the same question the link asks.
    private var expandActionName: String? {
        guard TimelineStyle.expandsInPlace(item) else { return nil }
        return isExpanded ? "Show less" : "Show more"
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
        case .prompt:
            // A question the agent asked, rebuilt from the input the mapper carried. The
            // answer, when the feed holds one, is already folded in as `result` by
            // `entries(from:)` on `callID` — unchanged, because the RESULT is still a
            // `.toolResult`.
            HistoricalPromptBody(item: item)
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
            proseBody
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .padding(item.kind == .userTurn ? 10 : 0)
                .background(userTurnBackground)
        }
    }

    /// Markdown for the two kinds a human wrote (`TimelineStyle.rendersMarkdown`), plain text
    /// for the rest — and **whole or clamped on one decision**, `TimelineStyle.proseLineLimit`,
    /// which answers `nil` for a body drawn in full.
    ///
    /// An answer is read here now, in the conversation it belongs to, rather than one tap away
    /// from it. What still clamps, and why, is that function's own comment; what matters on
    /// this side is that the *same* `nil` also decides the More link
    /// (`TimelineStyle.expandsInPlace`), so a cut body always has a way to the rest of itself
    /// and an uncut one never offers one. `isExpanded` is the reader's answer to that link, and
    /// it reaches the clamp and nothing else — the row is otherwise identical in both states.
    ///
    /// The two sides are bounded differently, and they have to be: `.lineLimit` does not reach a
    /// `Markdown` view usefully. It is a `VStack` of blocks, so a limit lands on each paragraph
    /// *separately* — fourteen lines per paragraph is not a bound at all — and a heading or a
    /// table has no line count to limit. So the Markdown side is handed a shorter **document**
    /// (`TimelineStyle.proseText`), counted in the very same lines the plain side passes to
    /// `.lineLimit`.
    ///
    /// It used to be bounded by height instead — `maxHeight: 23 × 120`, clipped — and that is
    /// the defect the renders for this change found: a height and a line count are two different
    /// measurements of the same number, they disagree by about a tenth, and a real answer that
    /// measured 2,770.67pt in *both* states drew a More link that did nothing. That story is on
    /// `TimelineStyle.proseText`.
    @ViewBuilder
    private var proseBody: some View {
        if TimelineStyle.rendersMarkdown(item) {
            Markdown(TimelineStyle.proseText(for: item, expanded: isExpanded))
                .markdownTheme(TimelineMarkdown.theme)
                .font(proseFont)
                .foregroundStyle(proseColor)
        } else {
            Text(item.body.text)
                .font(proseFont)
                .italic(item.kind == .thinking)
                .foregroundStyle(proseColor)
                .lineLimit(TimelineStyle.proseLineLimit(for: item, expanded: isExpanded))
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

    /// What the Mac cut, and what this row cut — said on the row, in that order.
    ///
    /// A tool result truncated at the item cap looks exactly like a short one, and a reader who
    /// does not know the output was cut will act on a partial file read as though it were
    /// whole. Both halves of a folded card are counted, since either can be the one that was
    /// cut. **They are two different shortfalls and both can be true at once**: the scissors
    /// is bytes the Mac never sent, and the second chip is words this row had no room for.
    @ViewBuilder
    private var chips: some View {
        let dropped = item.body.truncatedBytes + (result?.body.truncatedBytes ?? 0)
        if let chip = TimelineStyle.truncationChip(dropped) {
            Label(chip, systemImage: "scissors")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if TimelineStyle.expandsInPlace(item) {
            moreLink
        }
    }

    /// The way out of the ceiling, **at the cut, because that is where the reader is.**
    ///
    /// It replaced "Read the whole message" and a push. The chevron a `List` floats at a row's
    /// vertical centre is two screenfuls above the cut on a row this tall
    /// (`ui-renders/prose-full/after/very-long-*.png` is that argument), and the screen it led
    /// to drew the identical words a second time. This is one word where the message stops, and
    /// the rest arrives under it without the conversation moving.
    ///
    /// **Both directions, one control.** A row that can open is a row that can shut again —
    /// four screenfuls of an answer a reader has finished with is four screenfuls between them
    /// and the next message — so the link says Less once it is open. The chevron points the way
    /// the content is about to move, which is the only thing that distinguishes the two states
    /// at this size.
    ///
    /// Accent-coloured rather than `.secondary` like the scissors chip beside it: that chip is
    /// a statement and this is a control, and the render is what settled it — in `.secondary`
    /// at `.caption2` it reads as a third line of footnote and nothing says it can be tapped.
    /// `.contentShape` keeps the touch target on the words: a `Button` whose label is a small
    /// `Label` in a 2,700pt row must not claim the row.
    private var moreLink: some View {
        Button {
            toggleExpanded?()
        } label: {
            Label(
                isExpanded ? "Less" : "More",
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption2.weight(.semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

/// More and Less, for a reader who cannot see the button.
///
/// The row combines its children away (`.accessibilityElement(children: .ignore)`), so the link
/// in `chips` is not reachable by touch exploration at all — an action on the combined element
/// is the only place it can go. Written as a modifier taking an optional name for exactly the
/// reason `CopyAction` is: the two arms of "does this row expand" are different view types, and
/// a `@ViewBuilder` around the whole row would erase every row in the list.
private struct ExpandAction: ViewModifier {
    /// `nil` for a row with nothing cut. Named for what the next activation does, so a listener
    /// hears "Show less" on a row that is already open.
    let name: String?
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let name, let action {
            content.accessibilityAction(named: Text(name), action)
        } else {
            content
        }
    }
}

/// Copy, for the rows that have nowhere to send a reader for it.
///
/// A modifier taking an optional string rather than a `.contextMenu` written inline, because
/// the two branches of `TimelineStyle.rowCopyText(for:)` are different view types and a
/// `@ViewBuilder` around the whole row would erase them on every row in the list. `nil` is
/// "this row leads somewhere that has a Copy button already", or "there is nothing to copy" —
/// that function decides both, so there is no second emptiness test here.
private struct CopyAction: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.contextMenu {
                Button {
                    // `UIPasteboard` directly, exactly as `TimelineBodyBlock.copyButton` does
                    // it: what is wanted is the message on the clipboard in one gesture, not a
                    // share sheet to dismiss afterwards.
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}
