import FleetKit
import SwiftUI

/// The field at the foot of a session screen, and the outbox above it.
///
/// **The outbox rows sit here rather than in the `List`**, and that is the same decision
/// `PromptOutbox`'s comment argues: the list is the conversation, every row of which is a
/// record the agent has written, and a message the agent has not taken yet does not belong in
/// it. Above the field, dimmed, with its own state, it reads as what it is — something on its
/// way — rather than as something that happened.
///
/// **Nothing here is monospaced**, and that is the screen's rule rather than this view's
/// taste: monospace is reserved for machine text (see `TimelineRow`, whose renders settled
/// it), and a message a person is typing is prose — the same prose that comes back as a
/// `.userTurn` set in the system font one row above. Monospaced body text also fits about 38
/// characters to the line on a 393pt phone, which is the wall those renders rejected, and a
/// composer is the one place on the screen where a person is reading their own sentence back.
struct PromptComposer: View {
    /// Read live from the fleet by the screen above, so a session going to a shell, or
    /// closing on the Mac, disables this within a second rather than at the next push.
    let session: WireSession?
    let model: SessionTimelineModel

    /// **The draft lives on the model, not here.** Reply, on a selection in a timeline row,
    /// has to reach the box from a view that knows nothing about this one — see
    /// `SessionTimelineModel.draft`. What stayed is everything about the *field*: its focus,
    /// its deferred repaint, and when it may be sent.
    private var draft: Binding<String> {
        Binding { model.draft } set: { model.draft = $0 }
    }

    /// Taken when a quotation arrives, so the reader is typing into the space it just made
    /// rather than hunting for the field. Never taken on an ordinary draft change: focusing a
    /// composer on every keystroke is how a keyboard fights the person using it.
    @FocusState private var isFocused: Bool

    /// The `draft` parameter is gone with the `@State` it seeded; the offscreen render harness
    /// sets `model.draft` before building the composer, which is one fewer way for the two to
    /// disagree about what is in the box.
    init(session: WireSession?, model: SessionTimelineModel) {
        self.session = session
        self.model = model
    }

    /// Why this tab cannot take a message right now, or `nil` when it can.
    ///
    /// **Refused here as well as on the Mac, and the two are not redundant.** The Mac's
    /// refusal is the guarantee — `SessionStore.submitPrompt` re-checks everything regardless
    /// of what a client claims — and this one is the difference between a disabled field with
    /// a sentence under it and a message someone composed, sent, and got an error for.
    ///
    /// `busy` and `waiting` are deliberately AVAILABLE. A prompt arriving mid-turn is the
    /// ordinary case — mid-turn is when a person reaches for their phone — and the Mac holds
    /// it in `promptQueue` until the input box is free. A composer that disabled itself
    /// during a turn would stop working exactly when it is most wanted.
    ///
    /// The three sentences are the same copy `SessionTimelineModel.promptMessage(for:)` gives
    /// for the wire codes the Mac answers with (`unsupported_agent`, `not_running`,
    /// `unknown_session`), because they are the same three refusals: the phone saying it early
    /// and the Mac saying it late must not be two different explanations of one fact.
    static func unavailable(for session: WireSession?) -> String? {
        guard let session else { return "This session is no longer open on your Mac." }
        // A string comparison, not an enum, for the reason `WireSession.agent` is a `String`:
        // a client-side enum would throw on an agent added after this build shipped. An
        // unrecognised agent falls here, which is right — an agent nobody has heard of has no
        // known input box either.
        //
        // codex is refused for two reasons that both stand alone. Its tab holds the thread's
        // writer lock, so the app-server cannot start a turn while a message is being typed;
        // and the terminal route has no input box that can be found safely — `InputBar.read`
        // locks onto a line beginning `❯`, which a plain shell draws too.
        guard session.agent == "claude" else {
            return "Flight Deck can only type into a Claude session from here."
        }
        // `nil` is "no agent process registered" and is NOT `idle` — a statusless tab has no
        // input box. `"shell"` used to be refused alongside it on the theory that it was a
        // bare prompt; it is not, and never was: it is `idle` with a background task, which
        // is a tab at its prompt waiting for exactly this.
        guard session.activity != nil else {
            return "There's no agent running in this tab right now."
        }
        return nil
    }

    /// Whether the Send button does anything.
    ///
    /// `isSending` is the double-tap guard: one message in flight at a time, so a second tap
    /// before the first ack cannot become two messages in the agent's queue.
    static func canSend(draft: String, unavailable: String?, isSending: Bool) -> Bool {
        unavailable == nil && !isSending && PromptText(draft) != nil
    }

    private var unavailableReason: String? { Self.unavailable(for: session) }

    private var sendable: Bool {
        Self.canSend(
            draft: model.draft, unavailable: unavailableReason, isSending: model.outbox.isSending
        )
    }

    /// **A hairline and an opaque colour, not a `Material`, and the render is what settled
    /// it.** `.background(.bar)` was the first construction, and it failed twice: with nothing
    /// but a blur between the bar and a `.plain` list on the same colour, there was no edge at
    /// all in either theme — and a material makes SwiftUI blend `.secondary` content over it
    /// *vibrantly*, which in dark mode took the outbox row's own message text and the Send
    /// glyph down to invisible. A rule and `systemBackground` is what every composer on this
    /// phone actually is, and it is drawn from the same vocabulary as the rest of the screen,
    /// which uses explicit colours and no materials anywhere.
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.outbox.entries) { entry in
                    outboxRow(entry)
                }
                if let reason = unavailableReason {
                    unavailableNote(reason)
                } else {
                    field
                }
            }
            // Matches the leading inset of every row in the list above, so the field's left
            // edge lines up with the conversation rather than sitting a few points inside it.
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
    }

    // MARK: The field

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // `axis: .vertical` so a pasted paragraph grows the field instead of scrolling a
            // single line the writer cannot see the start of. `lineLimit` caps the growth so
            // a long message does not push the conversation off screen entirely.
            TextField("Message", text: draft, axis: .vertical)
                .focused($isFocused)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.body)
                // Autocorrect ON, autocapitalisation OFF, and the split is deliberate.
                //
                // Both used to be off, on the reasoning that this text goes into a terminal
                // and an autocorrected file path is a message that means something else. That
                // holds for capitalisation — a flag turned into `-Rf` by a capital is silently
                // a different command — and does not hold for the rest: most of what gets
                // typed here is a sentence to an agent, not a shell word, and typing prose on
                // a phone with autocorrect off is its own kind of wrong message.
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    // The one surface on this bar, and it is what says "type here". The same
                    // fill the tool cards and the failure notice use, so the composer is drawn
                    // from the screen's own vocabulary rather than a second one.
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            sendButton
        }
        // A quotation has just been appended. Take focus so the keyboard is up under the space
        // the quote made — `quoteTicks` and not `model.draft`, so this fires for a Reply and
        // never for typing.
        .onChange(of: model.quoteTicks) { isFocused = true }
    }

    /// The glyph, not a worded button. This is the one control on the screen with an
    /// established platform shape — every composer on this phone puts an arrow in a circle at
    /// the trailing end of the field — and the `Copy`/`Raw` construction the detail screen
    /// uses is for a caption-sized control in a panel header, which this is not.
    private var sendButton: some View {
        Button {
            model.send(model.draft)
            model.draft = ""
            // And again on the next turn of the run loop, which is not redundant.
            //
            // `TextField(axis: .vertical)` is UITextView-backed, and clearing its binding in
            // the same update cycle as the tap — while the field still holds focus — leaves
            // the view painting the OLD text over the new, empty state. The state itself is
            // correct; only the pixels are wrong, which is a genuinely confusing bug to look
            // at because the message did send.
            //
            // How that was pinned down, since "the text does not clear" reads like the
            // opposite: the Send button goes DISABLED after the tap. `canSend` disables only
            // when the tab is unavailable, a send is in flight, or `PromptText(draft) == nil`.
            // Editing the field re-enables it, which rules out the in-flight case — so the
            // reason it was disabled is that `draft` was already empty, while the field went
            // on showing its contents. Typing merely re-syncs the binding, which is why
            // editing "fixed" it.
            //
            // The keyboard is deliberately NOT dismissed — nothing here resigns focus,
            // because the next thing a person does after sending is usually to send again,
            // and putting the keyboard away costs them a tap to say one more thing. That
            // rules out the other common fix for this (resigning first responder, or giving
            // the field a new `.id()`), both of which drop the keyboard.
            DispatchQueue.main.async { model.draft = "" }
        } label: {
            // Two layers, arrow and disc, because one tint is not readable in both states in
            // both themes: a single `.secondary` fill on black is a glyph that is simply not
            // there, which the dark render showed. The arrow is punched out in the page's own
            // colour, so enabled reads as a filled accent disc and disabled as a grey one.
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    Color(.systemBackground),
                    sendable ? Color.accentColor : Color(.tertiaryLabel)
                )
        }
        .buttonStyle(.plain)
        .disabled(!sendable)
        // Stated rather than left to the glyph, which announces nothing useful.
        .accessibilityLabel("Send")
        // A disabled control is dimmed, and dimmed is also what "nothing typed yet" looks
        // like. VoiceOver gets the reason said out loud instead of inferred from a tint.
        .accessibilityHint(sendHint)
        // 44pt, because the glyph is 22 and a tap target that size is missed.
        .frame(width: 44, height: 40)
    }

    private var sendHint: String {
        if model.outbox.isSending { return "Waiting for your Mac to confirm the last message" }
        return model.draft.isEmpty ? "Type a message first" : "Sends this message to the agent"
    }

    /// Why there is no field. A sentence rather than a disabled field, because a field that
    /// cannot be used still invites typing into it, and the reason is the whole content of
    /// this state.
    ///
    /// `fixedSize` vertically so it wraps rather than truncating — the same thing the pairing
    /// screen's failure slot needed, and the longest of the three sentences runs past one line
    /// at the larger text sizes.
    private func unavailableNote(_ reason: String) -> some View {
        Text(reason)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The outbox

    /// One message on its way, with what is known about it and nothing more.
    private func outboxRow(_ entry: PromptOutboxEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                status(of: entry.state)
            }
            .accessibilityElement(children: .combine)
            if case .failed = entry.state { dismissButton(entry.id) }
        }
    }

    @ViewBuilder
    private func status(of state: PromptOutboxEntry.State) -> some View {
        switch state {
        case .sending:
            Label("Sending…", systemImage: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .accepted:
            // NOT "Sent to Claude". The Mac acked, which means dispatched and not done —
            // it may be queued behind a turn that is still running. This row disappears
            // when the agent's own transcript comes back holding the message, and that is
            // the only moment anything here can honestly claim it arrived.
            Label("Waiting for your Mac to type this", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Built exactly as `TimelineBodyBlock`'s Copy button is — same font, same label style,
    /// same borderless button — because this app has one small worded control and a second
    /// construction for the same job reads as an unrelated widget.
    ///
    /// A button rather than the whole failure line being tappable: the reason is the thing a
    /// reader is here to read, and a paragraph that dismisses itself when touched is how
    /// somebody loses the explanation before they have finished it.
    private func dismissButton(_ id: UUID) -> some View {
        Button {
            model.dismiss(id)
        } label: {
            Label("Dismiss", systemImage: "xmark")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Removes this message from the outbox. It is not sent again.")
    }
}
