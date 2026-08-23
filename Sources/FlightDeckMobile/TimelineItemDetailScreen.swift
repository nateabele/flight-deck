import FleetKit
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
///
/// A block whose body is whole JSON also carries a tree/raw toggle beside that button, and
/// opens on the tree — see `TimelineBodyBlock`.
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
                TimelineBodyBlock(
                    title: primaryTitle, item: item, monospaced: isMachineText(item)
                )
                if let result {
                    TimelineBodyBlock(
                        title: result.body.isError ? "Error" : "Output",
                        item: result, monospaced: true
                    )
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

/// One titled panel: a body, a Copy button, and — when the body is whole JSON — a toggle
/// between the tree and the text the Mac actually sent.
///
/// **A view rather than a function on the screen**, because the toggle needs state and the
/// screen draws two of these. Its own `@State` per panel is also the only correct place for it:
/// a tool call's input is frequently JSON while its output is a stack trace, so one shared mode
/// would put a raw-text-only panel into a mode it cannot honour.
///
/// **The tree is the default, and the choice is not remembered.** Every push of this screen
/// opens on the tree for a JSON body. Remembering the mode was considered and rejected: the raw
/// view is an escape hatch — "show me the bytes the Mac sent" — not a mode to live in, since
/// Copy already yields the exact text in either mode. A remembered choice would mean one glance
/// at raw text silently switches the feature off for every item opened afterwards, which is the
/// standard way a sticky view preference becomes a bug report about a missing feature. There is
/// nowhere to remember it *per item* in any case: an item is a value on a `NavigationPath`.
struct TimelineBodyBlock: View {
    let title: String
    let item: TimelineItem
    /// Whether the RAW view is monospaced. The tree never is — see `JSONTreeView`.
    let monospaced: Bool

    @State private var showsRaw: Bool

    /// `showsRaw` is a parameter only so the offscreen render harness can look at both modes —
    /// SwiftUI offers nothing to tap in a `layer.render(in:)` pass. Every caller on the screen
    /// takes the default, which is the tree.
    init(title: String, item: TimelineItem, monospaced: Bool, showsRaw: Bool = false) {
        self.title = title
        self.item = item
        self.monospaced = monospaced
        _showsRaw = State(initialValue: showsRaw)
    }

    /// `nil` for every body that is not whole, structured JSON, which is most of them: prose,
    /// command output, and — the case this had to be built around — any tool input the Mac cut
    /// at the byte cap, which is structurally incomplete by design. `nil` means no toggle and
    /// the text, exactly as this screen drew it before the tree existed.
    private var document: JSONValue? { TimelineStyle.jsonDocument(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.body.isError ? .red : .secondary)
                Spacer()
                if document != nil { modeButton }
                copyButton
            }
            panel
            if item.body.truncatedBytes > 0 {
                truncationNotice(
                    shown: item.body.text.utf8.count, dropped: item.body.truncatedBytes
                )
            }
        }
    }

    /// The tree and the text share one surface, so switching modes changes the content of the
    /// panel rather than swapping one card for a different-looking one.
    @ViewBuilder
    private var panel: some View {
        Group {
            if let document, !showsRaw {
                JSONTreeView(document: document)
            } else {
                Text(item.body.text.isEmpty ? "(empty)" : item.body.text)
                    .font(monospaced ? .system(.footnote, design: .monospaced) : .body)
                    .foregroundStyle(item.body.isError ? .red : .primary)
                    // Selectable as well as copyable: the button takes the whole body, and a
                    // reader who wants one path out of forty lines still needs to reach it.
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Named for what it switches TO, the way Copy is named for what it does. Built exactly as
    /// `copyButton` is — same font, same label style, same borderless button — because it sits
    /// beside it and a second button style on one line reads as two unrelated controls.
    private var modeButton: some View {
        Button {
            showsRaw.toggle()
        } label: {
            // The symbol names the destination, like the word beside it does. Paired the
            // other way — `curlybraces` next to "Raw" — the render read as two controls
            // disagreeing about which mode the panel was in.
            Label(
                showsRaw ? "Tree" : "Raw",
                systemImage: showsRaw ? "list.bullet.indent" : "text.alignleft"
            )
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(showsRaw ? "Show as a tree" : "Show the raw text")
    }

    /// `UIPasteboard` directly rather than a `ShareLink`: the thing wanted here is the text on
    /// the clipboard in one tap, not a share sheet to dismiss afterwards.
    ///
    /// It copies `body.text` in both modes, and that is the point — what a reader wants on the
    /// clipboard is the JSON the Mac sent, not a transcript of the rows currently open.
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = item.body.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .disabled(item.body.text.isEmpty)
    }

    /// Says both numbers, because "truncated" alone does not tell a reader whether they are
    /// missing a line or a megabyte — and that is the difference between reading on and going
    /// to the Mac.
    ///
    /// Unconditional on the mode, and it has to be: a cut body does not parse, so it is always
    /// the raw panel that is showing when this appears.
    private func truncationNotice(shown: Int, dropped: Int) -> some View {
        Label(
            TimelineStyle.truncationNotice(shown: shown, dropped: dropped),
            systemImage: "scissors"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
