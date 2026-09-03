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
    /// appears at all is decided before this view is ever handed one — by `OpenPrompt.find`,
    /// which refuses an agent no Mac can answer for, and then by the Mac's own
    /// `WireSession.openPromptCall`, which refuses a dialog it has moved on from.
    let agent: String?
    let state: SessionTimelineModel.AnswerState
    let model: SessionTimelineModel
    /// Whether the chase gave up on this dialog. **Latches** — see
    /// `SessionTimelineModel.blockedChaseExhausted`'s own comment — so this alone never says
    /// "blocked right now"; it is only safe to read alongside a live `open`, which is exactly
    /// what `showsBlocked` requires of its `hasCard`.
    let blockedChaseExhausted: Bool
    /// The Mac's own opt-in, straight off the wire (`WireSession.allowsBlockedAbort`) and never
    /// assumed — a Mac too old to run the driver that honours `FleetCommand.abortPrompt` has
    /// nothing on the other end of this button.
    let allowsBlockedAbort: Bool
    /// Sends `FleetCommand.abortPrompt`, via `FleetModel.abortBlockedPrompt(session:)`.
    ///
    /// A closure rather than a fourth verb on `model`'s `fleet` protocols: those three exist
    /// because each names a local state transition worth asserting without a socket — a send
    /// never answered, a refusal before the call returns (see `PromptSending`'s and
    /// `PromptAnswering`'s own comments). Abort changes nothing on `SessionTimelineModel` — the
    /// card leaves screen only when the Mac's own status moves on, which the existing chase
    /// already covers — so there is no transition here for a stub's seam to exist for, and the
    /// token dedup this exists to trigger is asserted directly against `FleetModel` instead.
    let onAbortBlocked: () async -> Void

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

    /// Blocked replaces the bare "Waiting for you" only once the chase has actually given up
    /// (~18s), never on a single failed fetch — the ordinary race must keep looking like one.
    ///
    /// **All three inputs are required; no pair of them is enough on its own.** `exhausted`
    /// alone would draw Blocked on a Mac too old to send `allowsBlockedAbort` — a button whose
    /// tap nothing on the other end honours. `allowsAbort` alone would draw it on the very
    /// first failed fetch, before the chase has even run. And dropping `hasCard` would draw it
    /// over a dialog that arrived late: `blockedChaseExhausted` **latches** — nothing clears it
    /// when a late transcript record finally supplies a card for the same still-open call, only
    /// a genuinely new dialog does (see that flag's own comment) — so the one thing standing
    /// between "the chase gave up, and nothing has changed since" and "the chase gave up, and
    /// then the card showed up anyway" is whether a card is on screen *right now*.
    ///
    /// **`hasCard` must therefore come from a LIVE `blocked(...)` call, taken at the same
    /// render as this one** — never a value cached alongside `exhausted`, and never `open`
    /// read back from a previous evaluation. A stale `hasCard` is precisely the exhausted-flag
    /// bug this predicate exists to not repeat, just moved one call up.
    static func showsBlocked(exhausted: Bool, allowsAbort: Bool, hasCard: Bool) -> Bool {
        exhausted && allowsAbort && !hasCard
    }

    /// Record a tap. Single-select replaces; multiSelect toggles.
    private func choose(question: Int, option: Int, multiSelect: Bool, call: String) {
        if picksFor != call {
            picks = [:]
            page = 0
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

    /// Back, and the button that either advances or commits.
    ///
    /// **The commit only appears on the last question**, and only lights once every question
    /// has an answer. A reader who skipped one is told by the dots above rather than by a
    /// button that silently does nothing; the Mac refuses an incomplete set as well
    /// (`AnswerPlan.plan` returns nil), so this is the courteous half of a rule enforced twice.
    @ViewBuilder
    private func navigation(
        call: String, questions: [PromptQuestion], index: Int, isLast: Bool, enabled: Bool
    ) -> some View {
        let complete = picksFor == call
            && questions.indices.allSatisfy { !picks[$0, default: []].isEmpty }
        let answeredHere = !picks[index, default: []].isEmpty
        HStack(spacing: 8) {
            if index > 0 {
                Button { page = index - 1 } label: {
                    Label("Back", systemImage: "chevron.left").font(.footnote)
                }
                .buttonStyle(.bordered)
            }
            if isLast {
                Button {
                    let selections = questions.indices.map { question in
                        picks[question, default: []].sorted().map {
                            AnswerSelection(index: $0,
                                            label: questions[question].options[$0].label)
                        }
                    }
                    model.answerSet(selections, to: call)
                } label: {
                    Text(questions.count == 1 ? "Send answer" : "Send answers")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled || !complete)
            } else {
                Button { page = index + 1 } label: {
                    Text("Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled || !answeredHere)
            }
        }
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
    /// Which question is on screen. Reset with the picks, for the same reason: a page left
    /// over from the last dialog would open this one part-way through.
    @State private var page = 0

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
            .modifier(CardChrome())
        } else if Self.showsBlocked(
            exhausted: blockedChaseExhausted, allowsAbort: allowsBlockedAbort,
            // `false`, not stale: `open` above is itself the live `blocked(...)` result this
            // render was handed, and this branch only runs once it has already tested nil.
            hasCard: false
        ) {
            blockedCard
        }
    }

    /// Flight Deck admitting it cannot read the dialog on screen, rather than a bare "Waiting
    /// for you" with no way out — see `showsBlocked` for when this replaces that. No footnote
    /// and no title variety: there are no words to show, because nothing here could read any.
    private var blockedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked")
                .font(.callout.weight(.medium))
            Text("This Mac can't read the dialog on screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                Task { await onAbortBlocked() }
            } label: {
                Text("Abort").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .modifier(CardChrome())
    }

    @ViewBuilder
    private func controls(for open: OpenPrompt) -> some View {
        let enabled = Self.showsControls(for: open, state: state)
        switch open {
        case .question(let call, let questions):
            // **One question at a time**, which is how the terminal presents them too: claude
            // draws a tab strip and shows the current question alone. A card that stacked all
            // of them ran off the bottom of the phone — three questions with described options
            // is well past a screen — and made the reader scroll to find out how much was left.
            //
            // The paging is the phone's own; nothing about the drive changes. Every answer is
            // collected here and sent as one command, which is what lets the Mac walk the whole
            // dialog in a single verified pass.
            let index = min(page, questions.count - 1)
            let question = questions[index]
            let isLast = index == questions.count - 1
            // A lone single-select question answers on the tap, exactly as it always has: one
            // question, one decision, and no second gesture to confirm the unambiguous.
            let immediate = questions.count == 1 && !question.multiSelect

            if questions.count > 1 {
                HStack(spacing: 6) {
                    Text("Question \(index + 1) of \(questions.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    // A dot per question, filled once it has an answer — the phone's reading of
                    // the strip claude puts above the dialog, so a reader can see what is left
                    // without paging through it.
                    ForEach(questions.indices, id: \.self) { dot in
                        Circle()
                            .fill(picks[dot, default: []].isEmpty
                                  ? Color.secondary.opacity(0.3) : Color.orange)
                            .frame(width: 6, height: 6)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let header = question.header, !header.isEmpty {
                    Text(header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if questions.count > 1 {
                    Text(question.question)
                        .font(.footnote.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(question.options.enumerated()), id: \.offset) { option, choice in
                Button {
                    if immediate {
                        model.answer(.option(index: option, label: choice.label), to: call)
                    } else {
                        choose(question: index, option: option,
                               multiSelect: question.multiSelect, call: call)
                        // Single-select advances by itself, the way the dialog does when you
                        // press Enter on a row. A checkbox question cannot: the reader is not
                        // finished until they say so.
                        if !question.multiSelect, !isLast { page = index + 1 }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.label)
                            .font(.footnote.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = choice.detail, !detail.isEmpty {
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
                // no longer sends anything.
                .overlay(alignment: .trailing) {
                    if !immediate, picks[index, default: []].contains(option) {
                        Image(systemName: question.multiSelect
                              ? "checkmark.square.fill" : "largecircle.fill.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.trailing, 10)
                    }
                }
            }

            if !immediate {
                navigation(call: call, questions: questions, index: index,
                           isLast: isLast, enabled: enabled)
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

/// The rounded, orange-bordered card shared by every state `PromptCard` draws. Factored out
/// when Blocked needed the identical padding, background and border a second place — copying
/// it would have let the two drift, and an orange border that stopped matching between an open
/// dialog and Blocked would read as two different features rather than one card's two states.
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
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
