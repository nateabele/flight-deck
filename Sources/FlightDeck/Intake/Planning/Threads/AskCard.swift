import IntakeKit
import SwiftUI

/// A thread's small outlined label: "answering", "stale", "needs you", "1 diff".
struct ThreadPillView: View {
    enum Tone { case live, diff, stale, question, plain }

    let text: String
    var tone: Tone = .plain

    init(_ text: String, tone: Tone = .plain) {
        self.text = text
        self.tone = tone
    }

    init(_ pill: ThreadPill) {
        self.text = pill.text
        self.tone = switch pill {
        case .answering: .live
        case .stale: .stale
        case .needsYou: .question
        }
    }

    private var color: Color {
        switch tone {
        case .live, .diff: .green
        case .stale: Instrument.amber
        case .question: .accentColor
        case .plain: .secondary
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tone == .diff ? color.opacity(0.1) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(tone == .plain ? Color.secondary.opacity(0.4) : color))
            .fixedSize()
    }
}

/// An Ask thread's card in the notes rail (spec §6): beside its quote like a note, with a title,
/// what the agent is doing or said last, the counts, and Open. A stale thread says so and offers
/// Re-propose.
struct AskCard: View {
    let card: AskCardModel
    let open: () -> Void
    /// Set only for a stale thread that has a diff to propose again.
    var repropose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("ASK", systemImage: "sparkle")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.accentColor)
                if let pill = card.pill { ThreadPillView(pill) }
                Spacer(minLength: 0)
            }
            Text(card.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let activity = card.activity {
                // R2: the reply text lands when the turn ends; until then, what the agent is doing.
                Text("● \(activity)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let excerpt = card.excerpt {
                Text("“\(excerpt)”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if card.pill == .stale {
                Text("Its diff no longer applies: a round rewrote this passage.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if card.pendingDiffs > 0 { ThreadPillView("\(card.pendingDiffs) diff\(card.pendingDiffs == 1 ? "" : "s")", tone: .diff) }
                if card.notes > 0 { ThreadPillView("\(card.notes) note\(card.notes == 1 ? "" : "s")") }
                if card.messages > 0 {
                    Text("\(card.messages) message\(card.messages == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if let repropose {
                    Button("Re-propose", action: repropose)
                        .controlSize(.small)
                        .accessibilityIdentifier("ask-card-repropose")
                }
                Button(action: open) { Text("Open ⤢").font(.system(size: 11.5)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ask-card-open")
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.85)))
        .shadow(color: Color.accentColor.opacity(card.pill == .answering ? 0.3 : 0.12), radius: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask thread: \(card.title)")
        .accessibilityIdentifier("ask-card")
    }
}
