import FleetKit
import SwiftUI

/// What the agent is blocked on, at the foot of the conversation.
///
/// **Above the composer and inside the safe-area inset, not a row in the `List`.** The list is
/// the conversation, every row of which is a record the agent has written; a dialog the agent
/// is *currently blocked on* is a state, and it must not scroll away from the finger that has
/// to answer it. The same placement decision, and the same reasoning, as `PromptComposer`'s
/// outbox rows.
///
/// **Two shapes, because the payloads genuinely differ.** A question has its own words and its
/// own options, read from the transcript. A permission request has none — the dialog's wording
/// is built in claude's TUI and exists nowhere Flight Deck reads — so its card describes the
/// *tool call*, which the phone has whole and which is more than the terminal's own one-line
/// summary shows, and offers the two intents `PromptAnswer` names.
///
/// **Allow and Deny, and no third button.** Claude's dialog offers "Yes, and don't ask again
/// for Bash commands in /Users/nate" in its middle rows — a durable grant, from a pocket, off a
/// possibly-truncated label. `PromptAnswer` has no case that names one, so there is nothing to
/// draw. See its own comment; this is not a `TODO`.
///
/// **Nothing here is monospaced** except a command, which is machine text. The screen's rule
/// (`TimelineRow`) reserves monospace for that, and a question written for a person is prose.
struct PromptCard: View {
    let open: OpenPrompt?
    let state: SessionTimelineModel.AnswerState
    let model: SessionTimelineModel

    /// Whether a finger can change anything.
    ///
    /// **Keyed on the call**, so a failure filed against a dialog that has since been replaced
    /// does not disable the replacement's buttons — the case where the session never left
    /// `waiting` and nothing tore the card down.
    static func showsControls(
        for open: OpenPrompt, state: SessionTimelineModel.AnswerState
    ) -> Bool {
        if let pending = state.call, pending == open.callID { return false }
        switch open {
        case .question(_, let question): return question.isAnswerable
        // Allow and Deny are intents, not payload, so there is nothing to be unanswerable
        // about.
        case .permission: return true
        }
    }

    /// The line under the controls, or none.
    ///
    /// **Also keyed on the call**, for the same reason `showsControls` is and with a worse
    /// failure if it were not: "Sent to your Mac." printed under a question nobody has answered
    /// tells a reader their tap landed on something they never saw.
    static func footnote(
        for open: OpenPrompt, state: SessionTimelineModel.AnswerState
    ) -> String? {
        if state.call == open.callID {
            switch state {
            case .sent: return sentFootnote
            case .failed(_, let reason): return reason
            case .idle: break
            }
        }
        // A shape this Mac will not drive says so in the Mac's own words, so a newer Mac that
        // learns to drive one simply stops producing the sentence.
        if case .question(_, let question) = open { return question.unanswerable }
        return nil
    }

    static let sentFootnote = "Sent to your Mac."

    static func title(for open: OpenPrompt) -> String {
        switch open {
        case .question(_, let question): return question.question
        case .permission(_, let tool, _):
            guard let tool, !tool.isEmpty else { return "Claude is waiting for you" }
            return "Claude wants to run \(tool)"
        }
    }

    /// The second line: an option's own words have their descriptions instead, so this is only
    /// ever a tool's command.
    static func subtitle(for open: OpenPrompt) -> String? {
        guard case .permission(_, _, let summary) = open, let summary, !summary.isEmpty
        else { return nil }
        return summary
    }

    var body: some View {
        if let open {
            VStack(alignment: .leading, spacing: 10) {
                if case .question(_, let question) = open, let header = question.header,
                   !header.isEmpty {
                    Text(header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(Self.title(for: open))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = Self.subtitle(for: open) {
                    Text(subtitle)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        // Three lines: a command is the thing being approved and clipping it to
                        // one is how a phone approves something nobody read. Beyond three, the
                        // full input is one tap away on the row above in the conversation.
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                controls(for: open)

                if let footnote = Self.footnote(for: open, state: state) {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.orange.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func controls(for open: OpenPrompt) -> some View {
        let enabled = Self.showsControls(for: open, state: state)
        switch open {
        case .question(let call, let question):
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    model.answer(.option(index: index, label: option.label), to: call)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.footnote.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                // A real description runs to a line and a half and is the only
                                // thing saying what the option MEANS. Clamped so four options
                                // still fit above the keyboard.
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.5)
            }
        case .permission(let call, _, _):
            HStack(spacing: 8) {
                // Deny first, and leading. It is the safe answer, it is one Escape with no
                // screen inference behind it, and it is the one a thumb should reach without
                // aiming.
                Button(role: .destructive) { model.answer(.deny, to: call) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                Button { model.answer(.allow, to: call) } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

/// A question already in the conversation, drawn as the question it was rather than as the
/// JSON of the call that asked it.
///
/// Rebuilt with the same parser the live card uses, over the body the mapper already carries.
/// `nil` from that parser is the ordinary outcome for a truncated body — see
/// `TimelineItem.Body.text` — and the fallback is the text, which is what this row did before.
struct HistoricalPromptBody: View {
    let item: TimelineItem

    var body: some View {
        if let question = PromptQuestion(toolInput: item.body.text) {
            VStack(alignment: .leading, spacing: 6) {
                Text(question.question)
                    .font(.footnote.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    Text("• \(option.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.body.text)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
