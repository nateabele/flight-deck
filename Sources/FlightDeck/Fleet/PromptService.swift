import FleetKit
import Foundation

/// Carries out a phone's answer to the dialog a session is blocked on.
///
/// The only type that knows a `SessionStore` and a transcript on this path — the role
/// `TimelineService` plays for history, split from it for the same reason it is split from the
/// store: each stays testable without the other, and the thing needing both is here.
///
/// **There is no cache and there must not be one.** The open call is re-derived from the
/// transcript on every answer. A `served` table would be faster and would fail the case this
/// service exists for: the user approves a dialog in the terminal, claude raises the next one
/// immediately, and the session **never leaves `waiting`** — so no event is emitted, the
/// phone's card still shows the old dialog, and a cached entry still matches it. The
/// re-derivation does not match, because the new dialog is a different call.
///
/// The read is a tail — `TimelineLimits.window` at most, `tailRecords` records — done once per
/// human tap, on the main queue, inside `FleetSocketServer`'s synchronous `onCommand`. That is
/// a deliberate trade against a cache and it is the cheaper of the two: `TimelineService` takes
/// its read off the main actor because a *page* is parsed on every activity change, which is
/// two orders of magnitude more often and larger.
///
/// Changes no fleet state and emits no `FleetEvent`, exactly as `TimelineService` does not:
/// what the phone answered becomes visible through the status the agent writes and the
/// transcript it appends.
@MainActor
final class PromptService {
    private let store: SessionStore

    /// Test seam, in the shape and for the reason `TimelineService.reader` is one: the file
    /// read is the thing tests must substitute, and `@Sendable` and free of `self` so what
    /// crosses is a function value and two values, never the service or the store.
    var tail: @Sendable (URL, Int) -> [SourceLine] = { url, limit in
        TranscriptPager.page(url: url, anchor: .latest, limit: limit)?.lines ?? []
    }

    /// How many records back to look.
    ///
    /// **Small on purpose.** An open call is always among the last records — claude cannot
    /// proceed past a dialog — so one would nearly always do. A handful is read so that a
    /// `tool_result` for an *earlier* call is inside the window and cannot make an
    /// already-answered call look open, which is the only way this can be wrong in the
    /// dangerous direction.
    static let tailRecords = 8

    init(store: SessionStore) {
        self.store = store
    }

    /// Answer the dialog `session` is blocked on, if `call` still names it.
    ///
    /// Three refusals before anything is typed. `not_waiting` — nothing is blocked, so there
    /// is nothing to answer and a keystroke would land in the input bar. `unsupported_agent`
    /// — this build cannot type into that agent's terminal at all. `prompt_changed` — the
    /// newest unanswered call is not the one named, which covers both the user answering in
    /// the terminal and the agent having moved to its next dialog.
    ///
    /// Everything below this — the screen, the shape of the answer — is
    /// `SessionStore.answerPrompt`'s to refuse, and its code is forwarded verbatim. Splitting
    /// a check across two files is how the two drift, which is why the agent refusal here is
    /// `AgentAdapter.dialogDriver` — the *same question* the store asks, of the same object —
    /// plus `openPrompt`, which is this file's own half and is asked of the same adapter
    /// rather than hardcoded to one agent's transcript grammar.
    ///
    /// The three refusals themselves live in `openPrompt(inSession:)`, so a caller that needs
    /// to *see* the open dialog reads it through the same gauntlet this answers against — see
    /// that method for why it is not a second copy.
    func answer(
        session: UUID, call: String, answer: PromptAnswer, token: UUID
    ) -> Result<Void, TimelineErrorCode> {
        switch openPrompt(inSession: session) {
        case .failure(let code):
            return .failure(code)
        case .success(let open):
            // **The comparison this whole service exists for.** The derivation says what the
            // terminal is blocked on now; `call` says what the phone was showing when a thumb
            // came down. They are only the same dialog if they are the same call.
            guard open.callID == call else { return .failure("prompt_changed") }

            let outcome = store.answerPrompt(open, with: answer, in: session, token: token)
            if let code = outcome.errorCode { return .failure(TimelineErrorCode(code)) }
            return .success(())
        }
    }

    /// What `session` is blocked on right now, or why nothing here can be answered.
    ///
    /// **Split out of `answer` rather than copied for it.** The answer path and any reader of
    /// the open dialog must agree on all four questions below — is the tab there, is it
    /// waiting, can this build drive and read its agent, and does it have a transcript — and
    /// two copies of that sequence would drift the first time one of them gained a case. The
    /// call-id comparison deliberately stays in `answer`: it is a fact about what the *client*
    /// was looking at, not about what the terminal is blocked on, and a reader has nothing to
    /// compare against.
    ///
    /// Every code returned here is one `answer` has always returned, in the order it has
    /// always returned them.
    func openPrompt(inSession session: UUID) -> Result<OpenPrompt, TimelineErrorCode> {
        // Resolved once, up front. A tab closed between the tap and here is the ordinary case,
        // not an edge one — the same ruling `TimelineService.page` makes.
        let source = store.timelineSource(of: session)
        if case .unknownSession = source { return .failure("unknown_session") }
        // Checked before any read, because it is the answer most of the time and costs
        // nothing. `OpenPrompt.find` gates on it too and `SessionStore.answerPrompt` gates on
        // it again — a client is not trusted, and neither is a caller — but refusing here is
        // what keeps `not_waiting` distinguishable from `prompt_changed`, which are different
        // sentences on the phone.
        let activity = store.status(for: session)?.activity
        guard activity == .waiting else { return .failure("not_waiting") }

        // **Two facts that were one line for too long.** This used to read `guard case
        // .file(.claude, let url) = source else { return .failure("prompt_changed") }`, so a
        // codex tab — which has a perfectly real `.file(.codex, url)` — was told
        // `prompt_changed`, which the phone renders as "Your Mac has moved on from this."
        // That is untrue, it reads as transient, and it invites a retry that can never
        // succeed: the exact reasoning `submitPrompt` gives for putting its agent test before
        // its status test.
        //
        // Asked of the agent rather than of the source's shape, so a tab with no transcript
        // is not quietly exempted from the question — `.noTranscript` names no agent, and it
        // is the shape a codex sign-in tab has.
        //
        // **Two capabilities, and both are needed here.** Driving a dialog needs a screen
        // grammar (`dialogDriver`); knowing WHICH dialog is on screen needs a transcript
        // grammar (`openPrompt`), and an agent can have either without the other. Codex is
        // exactly that: its approval list is drivable, and it writes nothing to its rollout
        // when the list goes up, so there is no call id for a phone's tap to be checked
        // against. Asking only the first would answer such a tab `prompt_changed` two lines
        // below — *"Your Mac has moved on from this."* for a dialog this build cannot see at
        // all — which is the defect §4.2 of the audit records, through the other door.
        guard let agent = store.agent(of: session),
              agent.dialogDriver != nil,
              let reader = agent.openPromptReader
        else { return .failure("unsupported_agent") }
        // Whatever is left is a tab this Mac can drive AND read, but that has nothing to read
        // *from*: no transcript at all. `prompt_changed` is right for it, and is the only
        // thing that code now means.
        guard case .file(_, let url) = source else { return .failure("prompt_changed") }
        let lines = tail(url, Self.tailRecords)
        // A tab that is waiting on something this reader cannot name in the transcript. The
        // terminal has a dialog up; nothing here knows which call it belongs to, so there is
        // nothing safe to answer and nothing honest to show.
        guard let open = reader.openPrompt(inTranscriptTail: lines, activity: activity)
        else { return .failure("prompt_changed") }
        return .success(open)
    }
}

extension TimelineErrorCode {
    /// A code built at runtime rather than written as a literal. `ExpressibleByStringLiteral`
    /// covers every call site in `TimelineService`; this covers the one place a code arrives
    /// from `SessionStore.AnswerDispatch` as a `String`.
    init(_ code: String) { self.init(stringLiteral: code) }
}
