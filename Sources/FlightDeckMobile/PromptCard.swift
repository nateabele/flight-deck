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
    /// The session's agent, straight off the wire and never a client-side enum — see
    /// `TimelineStyle.agentName`. Only ever used to *name* what is waiting; whether a card
    /// appears at all is `OpenPrompt.find`'s decision, which refuses an agent no Mac can
    /// answer for before this view is ever handed one.
    let agent: String?
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
        // Every question in the set, or none: the Mac walks the whole dialog and commits at
        // the end, so a set with one unanswerable question in it cannot be started.
        case .question(_, let questions):
            return !questions.isEmpty && questions.allSatisfy(\.isAnswerable)
        // Allow and Deny are intents, not payload, so there is nothing to be unanswerable
        // about.
        case .permission: return true
        }
    }

    /// Record a tap. Single-select replaces; multiSelect toggles.
    private func choose(question: Int, option: Int, multiSelect: Bool, call: String) {
        if picksFor != call {
            picks = [:]
            picksFor = call
        }
        var chosen = picks[question, default: []]
        if multiSelect {
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
        } else {
            chosen = [option]
        }
        picks[question] = chosen
    }

    /// The commit, offered only once every question has an answer.
    ///
    /// **Disabled rather than hidden while the set is incomplete**, so the reader can see that
    /// something is still owed rather than wondering where the button went. The Mac refuses an
    /// incomplete set too — `AnswerPlan.plan` returns nil — so this is the courteous half of a
    /// rule enforced on both sides.
    @ViewBuilder
    private func sendAnswers(
        call: String, questions: [PromptQuestion], enabled: Bool
    ) -> some View {
        let complete = picksFor == call
            && questions.indices.allSatisfy { !picks[$0, default: []].isEmpty }
        Button {
            let selections = questions.indices.map { index in
                picks[index, default: []].sorted().map {
                    AnswerSelection(index: $0, label: questions[index].options[$0].label)
                }
            }
            model.answerSet(selections, to: call)
        } label: {
            Text(questions.count == 1 ? "Send answer" : "Send answers")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled || !complete)
        .padding(.top, 2)
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
        // Only a genuine refusal now. Several questions is a shape the Mac drives, and so is
        // a question that takes several answers.
        if case .question(_, let questions) = open {
            return questions.compactMap(\.unanswerable).first
        }
        return nil
    }

    static let sentFootnote = "Sent to your Mac."

    /// **The agent's own name, from the wire, never a literal.** This used to say "Claude"
    /// whatever was on the other end — which was a lie the moment any other agent could reach
    /// this card, and a lie nothing in the type system would have caught.
    ///
    /// An agent the fleet did not name, or one this build has never heard of, gets the
    /// sentence with no name in it rather than an invented one — `TimelineStyle.agentName`
    /// answers `nil` there, and `WireSession.subagentSummary`'s rule applies: silence beats a
    /// guess. Belt and braces with `OpenPrompt.find`'s gate on purpose: the gate decides
    /// whether a card exists, this decides whose name is on it, and if the gate is ever
    /// widened for an agent that becomes answerable the copy is already honest.
    static func title(for open: OpenPrompt, agent: String?) -> String {
        switch open {
        case .question(_, let questions):
            // A set gets a count, not its first question's words — putting question one in the
            // title is what made a set of three look like a single question the phone had
            // decided to refuse.
            guard questions.count == 1, let only = questions.first else {
                return "\(questions.count) questions"
            }
            return only.question
        case .permission(_, let tool, _):
            let name = TimelineStyle.agentName(agent)
            guard let tool, !tool.isEmpty else {
                return name.map { "\($0) is waiting for you" } ?? "Waiting for you"
            }
            return name.map { "\($0) wants to run \(tool)" } ?? "Waiting to run \(tool)"
        }
    }

    /// The second line: an option's own words have their descriptions instead, so this is only
    /// ever a tool's command.
    static func subtitle(for open: OpenPrompt) -> String? {
        guard case .permission(_, _, let summary) = open, let summary, !summary.isEmpty
        else { return nil }
        return summary
    }

    /// What the reader has chosen so far, per question.
    ///
    /// **Keyed by the call, and cleared when it changes.** A set is answered as a unit, so the
    /// choices have to live somewhere between taps — and if they survived into the NEXT dialog
    /// the reader would be one tap from submitting answers they picked for a question they are
    /// no longer looking at.
    @State private var picks: [Int: Set<Int>] = [:]
    @State private var picksFor: String?

    var body: some View {
        if let open {
            VStack(alignment: .leading, spacing: 10) {
                // Only a single question's header sits up here; in a set each question draws
                // its own beside its options, where it says which question it belongs to.
                if case .question(_, let questions) = open, questions.count == 1,
                   let header = questions[0].header, !header.isEmpty {
                    Text(header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(Self.title(for: open, agent: agent))
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
        case .question(let call, let questions):
            // A lone single-select question answers on the tap, exactly as it always has: one
            // question, one decision, no second gesture to confirm what is already unambiguous.
            let immediate = questions.count == 1 && !questions[0].multiSelect
            // One block per question. A set draws every one of them — the whole point of the
            // change: a reader sent to their Mac to answer three questions could previously
            // see only the first, which told them neither what was being asked nor how much.
            ForEach(Array(questions.enumerated()), id: \.offset) { questionIndex, question in
            if questions.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(question.question)
                        .font(.footnote.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, questionIndex == 0 ? 0 : 6)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    if immediate {
                        model.answer(.option(index: index, label: option.label), to: call)
                    } else {
                        choose(question: questionIndex, option: index,
                               multiSelect: question.multiSelect, call: call)
                    }
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
                // The tick is the only thing saying a tap registered, because on a set the tap
                // no longer sends anything. Without it a reader taps and nothing happens.
                .overlay(alignment: .trailing) {
                    if !immediate, picks[questionIndex, default: []].contains(index) {
                        Image(systemName: question.multiSelect
                              ? "checkmark.square.fill" : "largecircle.fill.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.trailing, 10)
                    }
                }
            }
            }
            if !immediate {
                sendAnswers(call: call, questions: questions, enabled: enabled)
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
