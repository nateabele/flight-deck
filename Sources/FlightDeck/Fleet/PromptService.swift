import FleetKit
import Foundation

/// Carries out a phone's answer to the dialog a session is blocked on.
///
/// The only type that knows a `SessionStore` and a transcript on this path — the role
/// `TimelineService` plays for history, split from it for the same reason it is split from the
/// store: each stays testable without the other, and the thing needing both is here.
///
/// **The answer path has no cache and must not have one.** The open call is re-derived from the
/// transcript on every answer. A `served` table would be faster and would fail the case this
/// service exists for: the user approves a dialog in the terminal, claude raises the next one
/// immediately, and the session **never leaves `waiting`** — so the phone's card can still be
/// showing the old dialog when a thumb comes down, and a cached entry would still match it.
/// The re-derivation does not match, because the new dialog is a different call.
///
/// `WireSession.openPromptCall` now pushes that supersede, so a phone should learn about it and
/// stop offering the old card. That reduces how often a stale answer is *sent*; it does not
/// make this check optional. A frame can be in flight, dropped, or applied by a client that
/// ignores the field, and this is the only thing standing between any of those and a keystroke
/// at a real terminal.
///
/// The *push* side (`pushedOpenPrompt`, `polledOpenPrompt`) does cache, keyed on the transcript
/// file's stamp rather than on the session — a different thing from the `served` table above,
/// and safe for the reason `derive(_:polled:)` gives.
///
/// The read is a tail — `tailRecords` records the overwhelmingly common time, widening (see
/// `maxTailRecords`) up to a handful of times only when a smaller read proves inconclusive —
/// done once per human tap, on the main queue, inline in `FleetService.apply`'s `.answerPrompt`
/// arm, which (unlike `.newSession`) always answers synchronously. That is a deliberate trade
/// against a cache and it is the cheaper of the two in the ordinary case: `TimelineService`
/// takes its read off the main actor because a *page* is parsed on every activity change, which
/// is two orders of magnitude more often and larger. A widened read is not cheap — see
/// `maxTailRecords` — but it stays rare: it only happens when the common case has already missed.
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
    ///
    /// **"Last records" means last *conversational* records, and `hasMore` is why that
    /// distinction is carried up here at all.** Claude Code interleaves its own bookkeeping
    /// lines — `last-prompt`, `custom-title`, `mode`, and others — into the same transcript
    /// file, and `ClaudeTimelineMapper` correctly maps every one of them to no items. A small
    /// fixed window can therefore land entirely on a run of bookkeeping and read as "nothing
    /// open" when a real dialog sits one line above it — not a one-time artifact: the same
    /// batch recurs for as long as a session sits idle. `TranscriptPager.page` already computes
    /// whether more history precedes the window it returned; `hasMore` carries that fact up so
    /// `openPrompt(inSession:)` can widen instead of trusting an empty read that had somewhere
    /// else to look. See the widen loop there.
    var tail: @Sendable (URL, Int) -> (lines: [SourceLine], hasMore: Bool) = { url, limit in
        let page = TranscriptPager.page(url: url, anchor: .latest, limit: limit)
        return (page?.lines ?? [], page?.hasMore ?? false)
    }

    /// How many records back to look, first.
    ///
    /// **Small on purpose, and almost always enough.** An open call is always among the last
    /// *conversational* records — claude cannot proceed past a dialog — so one would nearly
    /// always do. A handful is read so that a `tool_result` for an *earlier* call is inside the
    /// window and cannot make an already-answered call look open, which is the only way this
    /// can be wrong in the dangerous direction. What it is not proof against is a run of
    /// non-conversational bookkeeping lines crowding the real dialog out of the window — see
    /// `maxTailRecords` and the widen loop in `openPrompt(inSession:)`.
    nonisolated static let tailRecords = 8

    /// The hard ceiling the widen loop in `openPrompt(inSession:)` will not read past.
    ///
    /// A stop, not a suggestion: the loop must terminate fast on a hot path (every registry
    /// tick, per waiting session), and this is what bounds it when a transcript is nothing but
    /// bookkeeping all the way up — a malformed file, or a session old enough to predate the
    /// window entirely. Reached, or `hasMore` false first, and the answer is `"prompt_changed"`,
    /// exactly what a miss has always meant.
    ///
    /// **This number's own headroom is theoretical past roughly 1000 records on a typical
    /// transcript, not a promise of "always this cheap."** `TranscriptPager.backwards` reads in
    /// 512KB windows up to its own `maxScan` ceiling (`TimelineLimits.window * 16`, 8MB), and
    /// real Claude transcripts run several KB per raw line near the tail — so a `limit: 4096`
    /// request can force the pager to exhaust its whole byte budget without ever returning that
    /// many lines. `TranscriptPager` itself is the real limiter above that point; this constant
    /// only bounds how many *widen attempts* the loop below will make. The loop's own progress
    /// guard (`lines.count > previousCount`) is what keeps a session stuck at the pager's byte
    /// ceiling from paying for repeat widenings that cannot possibly return more.
    nonisolated static let maxTailRecords = 4096

    /// Where a `PromptLifecycleRecord` goes. A seam on the SINK rather than a `#if DEBUG`
    /// around the recording, for the reason `SessionStore.answerAbortSink` is one: the failure
    /// this exists for reproduces only on the installed Release build, so what gets recorded
    /// must be identical in both configurations and only the destination is replaced in a test.
    ///
    /// `PromptLifecycleObserver` files through this property too rather than owning a second
    /// one, so a dialog's whole life — opened on the push side, refused here — reads as one
    /// stream and a test substitutes one closure to see all of it.
    var lifecycleSink: (PromptLifecycleRecord) -> Void = PromptLifecycleLog.record

    /// The last answer the scheduled probe derived for each tab, keyed by the transcript it
    /// read and that file's stamp at the time. See `derive(_:polled:)`.
    private var derived: [UUID: Derived] = [:]

    private struct Derived {
        let url: URL
        let stamp: TranscriptStamp
        let result: Result<OpenPrompt, TimelineErrorCode>
    }

    /// Tabs with a widened read running off the main actor. At most one per tab: a
    /// transcript growing faster than an 8MB scan finishes must not stack scans up.
    private var widening: Set<UUID> = []

    /// Called on the main actor when an off-main widen lands an answer the last poll could
    /// not give. `FleetService` points this at `SessionStore.recommitStatuses`, so the answer
    /// reaches the wire now rather than on the next registry tick.
    var onPolledSettled: (() -> Void)?

    /// Where a widened scan runs. Concurrent because widens for different tabs are
    /// independent; `widening` already keeps one tab from having two.
    private static let widenQueue = DispatchQueue(
        label: "dev.flightdeck.prompt-widen", qos: .utility, attributes: .concurrent
    )

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
            // **The pairing the prompt log exists for, in the case that produces the report.**
            // A tap refused here reaches the phone as *"Your Mac has moved on from this"* with
            // nothing anywhere saying what this Mac thought was open instead — and `open=none`
            // is a different fault from `open=<some other call>`: the first is a Mac that has
            // no dialog at all while a phone draws one, the second is an ordinary race.
            record(session, sent: call, open: nil, code: code.code)
            return .failure(code)
        case .success(let open):
            // **The comparison this whole service exists for.** The derivation says what the
            // terminal is blocked on now; `call` says what the phone was showing when a thumb
            // came down. They are only the same dialog if they are the same call.
            guard open.callID == call else {
                record(session, sent: call, open: open.callID, code: "prompt_changed")
                return .failure("prompt_changed")
            }

            let outcome = store.answerPrompt(open, with: answer, in: session, token: token)
            // Accepted answers are recorded too, and that is not noise: without a line for the
            // tap that matched, a log holding no refusal cannot be told apart from one where
            // the tap never arrived at the Mac at all.
            record(session, sent: call, open: open.callID, code: outcome.errorCode)
            if let code = outcome.errorCode { return .failure(TimelineErrorCode(code)) }
            return .success(())
        }
    }

    private func record(_ session: UUID, sent: String, open: String?, code: String?) {
        lifecycleSink(PromptLifecycleRecord(
            session: session, event: .answer(sent: sent, open: open, code: code)
        ))
    }

    /// The same question `openPrompt` answers, asked the way the **push** side has to ask it:
    /// without waking anything up.
    ///
    /// Two callers, both of which run on a schedule rather than on a tap —
    /// `SessionStore.commitStatuses` on every registry tick, and `PromptLifecycleObserver` on
    /// every activity edge. The agent test runs FIRST and exists only to keep this free of
    /// side effects: `openPrompt` resolves the tab's transcript, and that resolution builds
    /// and memoizes the agent's adapter — for codex, a whole `CodexStack` with a runtime and
    /// an index watcher in it. Reporting what is on screen must never be the thing that brings
    /// one into existence.
    ///
    /// The refusal is the same string from the same property `openPrompt` would have returned,
    /// so nothing is decided differently here; only the order is.
    func pushedOpenPrompt(inSession session: UUID) -> Result<OpenPrompt, TimelineErrorCode> {
        guard let agent = store.agent(of: session),
              agent.dialogDriver != nil,
              agent.openPromptReader != nil
        else { return .failure("unsupported_agent") }
        // Never nil: an unpolled derive always settles inline.
        return derive(session, polled: false) ?? .failure("prompt_changed")
    }

    /// `pushedOpenPrompt` for `SessionStore`'s registry tick, which must never block the main
    /// actor on a widened read. Nil means "not known yet": the first window missed, a wider
    /// read is running off the main actor, and `onPolledSettled` fires when it lands.
    func polledOpenPrompt(inSession session: UUID) -> Result<OpenPrompt, TimelineErrorCode>? {
        guard let agent = store.agent(of: session),
              agent.dialogDriver != nil,
              agent.openPromptReader != nil
        else { return .failure("unsupported_agent") }
        return derive(session, polled: true)
    }

    /// The scheduled side's read, cached on the transcript's stamp.
    ///
    /// **Why a cache is safe here when `answer` must never have one.** The `served` table the
    /// type doc rules out is keyed on the *session*, and a session's open dialog changes with
    /// the session still `waiting`. This is keyed on the *file*: claude writes the next
    /// dialog's `tool_use` when it raises it (see `ClaudeOpenCall`), so a new dialog is an
    /// append, an append moves the stamp, and a moved stamp is a fresh derivation. What the
    /// cache skips is only the re-read of bytes that have not changed, whose answer cannot
    /// have either. `answer` still re-derives inline regardless — a tap is the one place a
    /// microsecond-old answer is not good enough.
    ///
    /// **The failure this exists for (2026-10-05):** a tab `waiting` on a dialog that never
    /// reached its transcript has nothing to find, so every tick widened to the pager's scan
    /// ceiling — a whole 7MB transcript, twice, every 500ms, on the main actor — and Flight
    /// Deck sat at 112% CPU for as long as the tab stayed `waiting`. That tab now costs one
    /// `stat` a tick.
    ///
    /// When `polled`, only the first window is read inline (the common case, and the one that
    /// keeps a freshly blocked tab's card from arriving a poll late); a widen goes to
    /// `widenQueue`. While one is in flight the last *refusal* is served, so a stuck episode
    /// is not reset by a transcript that keeps growing under it — but never the last *call*:
    /// offering a phone a dialog that may be gone is the dangerous direction.
    private func derive(_ session: UUID, polled: Bool) -> Result<OpenPrompt, TimelineErrorCode>? {
        // Entries for tabs no longer waiting are dead weight and, worse, would be served as a
        // stale refusal at the start of the tab's next episode.
        derived = derived.filter { store.status(for: $0.key)?.activity == .waiting }
        let read: TranscriptRead
        switch preflight(session) {
        case .failure(let code): return .failure(code)
        case .success(let r): read = r
        }
        // Taken BEFORE the read, so an append racing the read leaves the entry keyed on the
        // older stamp and the next tick re-derives — the safe direction.
        guard let stamp = TranscriptStamp(of: read.url) else {
            // Nothing on disk to key on (not written yet). The pager reads nothing for a
            // missing file, so the uncached derivation is as cheap as a cache hit.
            return Self.scanToEnd(read, tail: tail)
        }
        if let hit = derived[session], hit.url == read.url, hit.stamp == stamp {
            return hit.result
        }
        if !polled {
            let result = Self.scanToEnd(read, tail: tail)
            derived[session] = Derived(url: read.url, stamp: stamp, result: result)
            return result
        }
        if widening.contains(session) { return staleRefusal(session) }
        switch Self.scan(read, tail: tail, reads: 1) {
        case .settled(let result):
            derived[session] = Derived(url: read.url, stamp: stamp, result: result)
            return result
        case .needsWider(let step):
            widen(session, read, stamp: stamp, from: step)
            return staleRefusal(session)
        }
    }

    private func staleRefusal(_ session: UUID) -> Result<OpenPrompt, TimelineErrorCode>? {
        guard let last = derived[session]?.result, case .failure = last else { return nil }
        return last
    }

    private func widen(
        _ session: UUID, _ read: TranscriptRead, stamp: TranscriptStamp, from step: WidenStep
    ) {
        widening.insert(session)
        let tail = self.tail
        Self.widenQueue.async { [weak self] in
            let result = Self.scanToEnd(read, tail: tail, from: step)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.widening.remove(session)
                    self.derived[session] = Derived(url: read.url, stamp: stamp, result: result)
                    self.onPolledSettled?()
                }
            }
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
        preflight(session).flatMap { Self.scanToEnd($0, tail: tail) }
    }

    /// Everything `openPrompt` decides before reading a byte, split out so the scheduled
    /// probe (`derive`) asks the same four questions in the same order and only then decides
    /// whether the read itself can be skipped or moved off the main actor.
    private func preflight(_ session: UUID) -> Result<TranscriptRead, TimelineErrorCode> {
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
        return .success(TranscriptRead(url: url, reader: reader, activity: activity))
    }

    /// The inputs `scan` needs, and nothing that lives on the main actor — which is what lets
    /// a widened read be handed to a background queue whole.
    struct TranscriptRead: Sendable {
        let url: URL
        let reader: any AgentOpenPromptReader
        let activity: SessionActivity?
    }

    /// Where the widen loop is up to: the next `limit` to ask for, and how many lines the
    /// last read returned (`-1` before any read). A value, so a loop paused on the main actor
    /// can be resumed on another queue exactly where it stopped.
    struct WidenStep: Sendable, Equatable {
        var limit: Int
        var previousCount: Int
        static let first = WidenStep(limit: max(1, tailRecords), previousCount: -1)
    }

    enum ScanOutcome: Sendable {
        case settled(Result<OpenPrompt, TimelineErrorCode>)
        /// `reads` ran out before the loop did; resume from this step.
        case needsWider(WidenStep)
    }

    /// **A bounded widen-retry, not a bigger constant.** `Self.tailRecords` finds the open
    /// call the overwhelmingly common time, so the loop starts there and its body runs once
    /// in the ordinary case. But Claude Code interleaves non-conversational bookkeeping
    /// lines into the same transcript file — `last-prompt`, `custom-title`, `mode`, and
    /// others seen in practice, with no promise that list is exhaustive or that a batch of
    /// them is a one-time artifact rather than something that recurs for as long as a
    /// session sits idle — and `ClaudeTimelineMapper` correctly maps every one of them to no
    /// items. A small fixed window can land entirely on such a run and read as "nothing
    /// open" while a real dialog sits just outside it. Rather than guess a bigger constant
    /// and bet against internals this build does not control, each read's own `hasMore`
    /// says whether more history precedes the window just read — "nothing found, but more
    /// exists above" is the signal to look further, not a name for what pushed the dialog
    /// out. `Self.maxTailRecords` is the hard stop: reached, or `hasMore` false, and the
    /// answer is `"prompt_changed"` — exactly what a miss has always meant, never worse.
    ///
    /// `previousCount` is a second, cheaper stop than the record-count ceiling alone. A wider
    /// read is always a superset of a narrower one — `TranscriptPager` only ever extends
    /// backwards from the same anchor — so if a bigger `limit` came back with the same
    /// number of lines as the last attempt, the file itself has run out before the requested
    /// count did (see `maxTailRecords`'s own doc comment: `TranscriptPager`'s byte-scan
    /// ceiling, not this loop's record ceiling, is what actually limits a real transcript).
    /// Widening again in that state cannot possibly find more, only pay for another full
    /// scan of the same bytes — exactly the sustained cost a multi-hour `answerless` episode,
    /// probed on every registry tick, cannot afford to repeat.
    ///
    /// `nonisolated` and static, so the same loop runs inline for a tap and off the main
    /// actor for a scheduled widen — one copy, not two that drift. `reads` caps how many
    /// reads this call performs: `nil` runs the loop to its end, `1` reads the first window
    /// only and hands back the step to resume from.
    nonisolated static func scan(
        _ read: TranscriptRead,
        tail: (URL, Int) -> (lines: [SourceLine], hasMore: Bool),
        from start: WidenStep = .first,
        reads: Int? = nil
    ) -> ScanOutcome {
        var step = start
        var performed = 0
        while true {
            let (lines, hasMore) = tail(read.url, step.limit)
            performed += 1
            if let open = read.reader.openPrompt(inTranscriptTail: lines, activity: read.activity) {
                return .settled(.success(open))
            }
            guard hasMore, step.limit < maxTailRecords, lines.count > step.previousCount
            else { return .settled(.failure("prompt_changed")) }
            step = WidenStep(limit: step.limit * 8, previousCount: lines.count)
            if let reads, performed >= reads { return .needsWider(step) }
        }
    }

    /// `scan` with no read budget, which therefore always settles.
    nonisolated static func scanToEnd(
        _ read: TranscriptRead, tail: (URL, Int) -> (lines: [SourceLine], hasMore: Bool),
        from start: WidenStep = .first
    ) -> Result<OpenPrompt, TimelineErrorCode> {
        guard case .settled(let result) = scan(read, tail: tail, from: start)
        else { preconditionFailure("an unbudgeted scan always settles") }
        return result
    }
}

/// A transcript's identity and extent, from one `stat`: what the scheduled probe keys its
/// cache on. The inode catches a file replaced rather than appended to; size and the
/// nanosecond mtime catch every append. `stat` rather than `URL.resourceValues`, which
/// caches on the URL object and can answer with the value from an earlier look.
struct TranscriptStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mtimeSeconds: Int
    let mtimeNanoseconds: Int

    init?(of url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        mtimeSeconds = info.st_mtimespec.tv_sec
        mtimeNanoseconds = info.st_mtimespec.tv_nsec
    }
}

extension TimelineErrorCode {
    /// A code built at runtime rather than written as a literal. `ExpressibleByStringLiteral`
    /// covers every call site in `TimelineService`; this covers the one place a code arrives
    /// from `SessionStore.AnswerDispatch` as a `String`.
    init(_ code: String) { self.init(stringLiteral: code) }
}
