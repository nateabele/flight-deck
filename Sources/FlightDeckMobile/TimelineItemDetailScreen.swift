import FleetKit
import MarkdownUI
import SwiftUI
import UIKit

/// The third of spec §7's screens: the whole of one item, and — for a tool call — what came
/// back from it.
///
/// **What "whole" means is stated on screen rather than assumed.** An item is capped at
/// `TimelineLimits.maxItemBytes` on the Mac, which covers essentially every command output
/// and most file reads and does not cover all of them. A screen that simply stopped at the
/// cap would be indistinguishable from one showing a complete result, which is exactly the
/// failure `Body.truncatedBytes` exists to prevent.
///
/// Each block carries its own copy button, because the reason to open this screen at all is
/// usually to take something off it — a command to re-run, a path out of a stack trace. On a
/// phone, selecting sixty lines of monospaced text by dragging is not a way to do that.
struct TimelineItemDetailScreen: View {
    let item: TimelineItem
    /// The result that answers this call, when the feed holds it. Paired on the agent's own
    /// `callID`, never on `id` — `id` is a byte offset and pairs nothing.
    let result: TimelineItem?
    /// The agent that wrote it, so its prose is titled with its name rather than "Assistant".
    var agent: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                block(title: primaryTitle, item: item)
                if let result {
                    block(title: result.body.isError ? "Error" : "Output", item: result)
                }
                if item.kind == .unknown { unrecognizedNote }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(TimelineStyle.heading(for: item, agent: agent))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The symbol and name this item carries in the list, repeated here so a reader who tapped
    /// a green `terminal.fill` lands on a screen that looks like the row they tapped, plus the
    /// one thing the row had no space for: when it happened, in full.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: TimelineStyle.symbol(for: item))
                .font(.footnote)
                .foregroundStyle(TimelineStyle.tint(for: item))
            Text(TimelineStyle.heading(for: item, agent: agent))
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            // The agent's own timestamp, verbatim off the wire and formatted here — the Mac
            // deliberately never parses it (see `TimelineItem.at`). A string that does not
            // parse renders as nothing rather than as a formatted lie about a date nobody has.
            if let stamp = TimelineStyle.timestamp(item.at) {
                Text(stamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    /// "Input" for a tool call, because the block below it is that call's arguments and
    /// "Bash" would repeat the title already in the bar. Every other kind is its own name.
    private var primaryTitle: String {
        switch item.kind {
        case .toolCall: return "Input"
        case .toolResult: return item.body.isError ? "Error" : "Output"
        default: return TimelineStyle.heading(for: item, agent: agent)
        }
    }

    /// Monospace is for machine text. A long assistant message set in it is a grey wall that
    /// fits about 38 characters to the line on a phone; a tool's JSON input set in anything
    /// else loses the indentation that is the only structure it has left after the byte cap
    /// cut it.
    private func isMachineText(_ item: TimelineItem) -> Bool {
        switch item.kind {
        case .toolCall, .toolResult, .unknown: return true
        default: return false
        }
    }

    private func block(title: String, item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.body.isError ? .red : .secondary)
                Spacer()
                copyButton(item.body.text)
            }
            body(of: item)
                // Selectable as well as copyable: the button takes the whole body, and a
                // reader who wants one path out of forty lines still needs to reach it.
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(panelled(item) ? 12 : 0)
                .background(panel(when: panelled(item)))
            if item.body.truncatedBytes > 0 {
                truncationNotice(
                    shown: item.body.text.utf8.count, dropped: item.body.truncatedBytes
                )
            }
        }
    }

    /// The whole body, as Markdown for the two kinds a human wrote it in and verbatim for
    /// everything else. Same rule, same function, as the row: `TimelineStyle.rendersMarkdown`,
    /// so a message cannot be an essay on one screen and a wall of asterisks on the other.
    ///
    /// Unclamped here, which is the point of the screen — the row cuts a long answer at
    /// fourteen lines' worth of height and this is where the rest of it is.
    @ViewBuilder
    private func body(of item: TimelineItem) -> some View {
        if item.body.text.isEmpty {
            Text("(empty)").font(.body).foregroundStyle(.secondary)
        } else if TimelineStyle.rendersMarkdown(item) {
            Markdown(item.body.text)
                .markdownTheme(TimelineMarkdown.theme)
                .font(.body)
        } else {
            Text(item.body.text)
                .font(isMachineText(item) ? .system(.footnote, design: .monospaced) : .body)
                .foregroundStyle(item.body.isError ? .red : .primary)
        }
    }

    /// **Prose gets no panel, and that is what makes a fenced block inside it visible.**
    ///
    /// The grey surface is how machine text says it is machine text — it is the same fill the
    /// row's tool card uses, and `TimelineMarkdown.theme` gives a fenced code block that very
    /// same fill so a block of code in an answer reads as the same kind of object. Two of them
    /// nested is one rectangle: `secondarySystemBackground` on `secondarySystemBackground` has
    /// no edge in either theme. So the outer one goes, for prose only, and an answer sits on
    /// the page the way an answer does — with its code blocks standing off it.
    private func panelled(_ item: TimelineItem) -> Bool {
        !TimelineStyle.rendersMarkdown(item) || item.body.text.isEmpty
    }

    @ViewBuilder
    private func panel(when on: Bool) -> some View {
        if on {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        }
    }

    /// `UIPasteboard` directly rather than a `ShareLink`: the thing wanted here is the text on
    /// the clipboard in one tap, not a share sheet to dismiss afterwards.
    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .disabled(text.isEmpty)
    }

    /// Says both numbers, because "truncated" alone does not tell a reader whether they are
    /// missing a line or a megabyte — and that is the difference between reading on and going
    /// to the Mac.
    private func truncationNotice(shown: Int, dropped: Int) -> some View {
        Label(
            TimelineStyle.truncationNotice(shown: shown, dropped: dropped),
            systemImage: "scissors"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A kind this build has never heard of, from a newer Mac. The body is still shown — it is
    /// what the Mac sent, and it is more use than a blank screen — but the reader is told why
    /// it looks like nothing else on the screen, rather than being left to conclude the app is
    /// broken. Same rule, same reason, as `TimelineItem.Kind` decoding it at all.
    private var unrecognizedNote: some View {
        Label(
            "Your Mac sent something this version of Flight Deck doesn't recognize. "
            + "It's shown here exactly as it arrived.",
            systemImage: "circle.dotted"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
