import FleetKit
import MarkdownUI
import SwiftUI

/// Pending thread diffs in the plan reader, in the gutter-bar form (spec §6, option B): the
/// proposed text reads as normal prose with a thin green bar beside it. The phone has no hover,
/// so tapping the bar shows the old text struck through with Accept / ✗.
///
/// Decided apart from SwiftUI so it can be tested (MOBILE-UI).
enum PhoneDiffGutter {
    /// What one block draws for its diffs.
    struct BlockDiffs: Equatable {
        /// The block's text with every inline diff applied.
        var text: String
        /// Diffs drawn inline in `text`, each with a bar.
        var bars: [WirePendingDiff] = []
        /// Diffs whose old passage could not be found exactly once in the block as drawn (the
        /// Mac placed them by rendered text): drawn as a card under the block, never guessed into it.
        var loose: [WirePendingDiff] = []
    }

    /// `blockText` with the plan's pending diffs for `block` applied. A diff the person already
    /// accepted draws as its new text with no bar (the runner applies it after the ack); one they
    /// rejected is not drawn at all. A stale diff is `loose`: it has no new text to read in place.
    static func apply(to blockText: String, block: Int, diffs: [WirePendingDiff], outbox: ThreadOutbox) -> BlockDiffs {
        var result = BlockDiffs(text: blockText)
        for diff in diffs where diff.blockIndex == block {
            let decision = outbox.decision(for: diff.id)
            if decision == false { continue }
            if diff.state == "stale" { result.loose.append(diff); continue }
            guard diff.state == "pending" else { continue }
            guard let replaced = replacing(diff.old, with: diff.new, in: result.text) else {
                if decision == nil { result.loose.append(diff) }
                continue
            }
            result.text = replaced
            if decision == nil { result.bars.append(diff) }
        }
        return result
    }

    /// Diffs the Mac could not place in any block (their passage is gone from the plan shown).
    static func detached(_ diffs: [WirePendingDiff], outbox: ThreadOutbox) -> [WirePendingDiff] {
        diffs.filter { $0.blockIndex == nil && outbox.decision(for: $0.id) == nil && ($0.state == "pending" || $0.state == "stale") }
    }

    /// Exactly once, as the Mac applies it: a passage found twice is an ambiguous edit, not one to guess.
    static func replacing(_ old: String, with new: String, in text: String) -> String? {
        guard !old.isEmpty else { return nil }
        let parts = text.components(separatedBy: old)
        return parts.count == 2 ? parts[0] + new + parts[1] : nil
    }

    /// Accept only on a pending diff of an intake that still takes steering — or on a stale one
    /// this phone already sent a ✓ for that wasn't acked (C-5): the edit landed and made it stale,
    /// the decision didn't, and the Mac completes the accept on the retry (`alreadyQueued`).
    static func canDecide(_ diff: WirePendingDiff, detail: WireIntakeDetail?, acceptSent: Bool = false) -> Bool {
        (diff.state == "pending" || (diff.state == "stale" && acceptSent)) && ThreadGate.canAsk(detail: detail)
    }
}

/// Proposed or old plan text, rendered as Markdown the way a reply is (the passages are plan
/// source, so `**bold**` must show as bold). The one place every diff surface draws its text.
/// `serif` in the plan reader, where the proposed words read as plan prose does; the thread's
/// conversation keeps the system sans.
struct DiffText: View {
    let text: String
    var old = false
    var serif = false

    /// `text` as it should be read aloud: inline Markdown interpreted and its markers dropped.
    static func spoken(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(parsed.characters)
    }

    var body: some View {
        let rendered = Markdown(text).markdownTheme(serif ? TimelineMarkdown.planTheme : TimelineMarkdown.theme)
        // Struck through by the theme's own text style: a SwiftUI `.strikethrough()` on the view
        // reaches only `Text` that reads it from the environment, which MarkdownUI's text need not.
        if old {
            rendered.markdownTextStyle { StrikethroughStyle(.single); ForegroundColor(.secondary) }
        } else { rendered }
    }
}

/// The 3 pt green bar and a small ✦, tappable. A column beside the text rather than a tap on the
/// text: a tap gesture there would compete with the press that starts a selection.
struct PhoneDiffBar: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(spacing: 2) {
                Image(systemName: "sparkle").font(.caption2.weight(.bold)).foregroundStyle(.green)
                Capsule().fill(Color.green).frame(width: 3).frame(maxHeight: .infinity)
            }
            .frame(width: 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 1 ? "Proposed change" : "\(count) proposed changes")
        .accessibilityHint("Shows the old text, with Accept and Reject")
    }
}

/// A diff opened from its bar: the old text struck through, the new text, and the decision.
struct PhoneDiffSheet: View {
    let diff: WirePendingDiff
    let canDecide: Bool
    let deciding: Bool
    let onDecide: (Bool) -> Void
    let onOpenThread: () -> Void
    /// Opened from the plan reader: the passages read in the plan's serif.
    var serif = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Proposed change").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                if !diff.old.isEmpty {
                    DiffText(text: diff.old, old: true, serif: serif)
                        .accessibilityLabel("Old text: \(DiffText.spoken(diff.old))")
                }
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(Color.green).frame(width: 3)
                    DiffText(text: diff.new, serif: serif)
                        .accessibilityLabel("New text: \(DiffText.spoken(diff.new))")
                }
                .fixedSize(horizontal: false, vertical: true)
                if diff.state == "stale" && canDecide {
                    // C-5: this phone's Accept reached the plan but maybe not the thread.
                    Text("Your Accept may not have finished on your Mac. Tap Accept again to finish it.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if diff.state == "stale" {
                    Text("A newer round changed this passage, so the change no longer fits. Open the thread to ask for it again.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if !canDecide {
                    Text("Decide on your Mac for now.").font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if canDecide {
                        Button { onDecide(true) } label: {
                            Text(deciding ? "Working…" : "Accept").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).tint(.green).disabled(deciding)
                        if diff.state == "pending" {
                            Button(role: .destructive) { onDecide(false) } label: {
                                Label("Reject", systemImage: "xmark").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.bordered).disabled(deciding)
                            .accessibilityLabel("Reject")
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: onOpenThread) { Text("Open thread").font(.subheadline).frame(minHeight: 44) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .presentationDetents([.medium])
    }
}
