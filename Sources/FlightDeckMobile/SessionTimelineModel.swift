import FleetKit
import Foundation
import Observation

/// What a session screen needs from the fleet: a page, or a reason there is not one — and a
/// way to say the reader is looking at this session.
///
/// A protocol over `FleetModel`'s methods rather than `FleetModel` itself, for exactly one
/// reason: `FleetModel`'s connector is private and answers nothing without a real socket, a
/// real pairing and a real Mac, so a screen model that took the concrete type could not have
/// a single phase transition asserted — and the phases below are where a spinner gets stuck
/// and where an error gets swallowed.
///
/// **`markRead` is here rather than on the list screen, and that placement is the fix to a
/// real bug.** The fleet list used to send it from a `.simultaneousGesture(TapGesture())`
/// hung off each row's `NavigationLink`, which is a second recogniser competing for the tap
/// that opens the session — and it swallowed enough of them that rows stopped opening at
/// all. Opening the conversation is the "I have looked at this" the mark means, so the mark
/// belongs where the conversation opens. See `FleetListScreen.sessionRow`.
///
/// Deliberately no wider than these two. Anything else a screen wants from the fleet is a
/// seam this app can drift into using for something that is not a session screen.
@MainActor
protocol TimelinePaging: AnyObject {
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    )

    /// Tells the Mac this session has been looked at. Fire and forget in both directions:
    /// the command is a no-op while disconnected, and the row does not change until the Mac
    /// echoes the fact back as an event.
    func markRead(_ id: UUID)
}

/// The other half of `TimelinePaging`: asking the Mac to **do** something, and hearing that
/// it heard.
///
/// A second protocol rather than a second method on that one, for the reason that one is a
/// protocol at all: a screen model that took the concrete `FleetModel` could not be stood up
/// without a socket, a pairing and a real Mac, and the transitions worth asserting here — a
/// send that is never answered, a refusal delivered before the call returns — are exactly the
/// ones no real link produces on demand. Two protocols, so a stub can answer one verb and
/// leave the other outstanding.
/// Telling the Mac which session this phone is looking at.
///
/// Its own protocol for the reason the others are: a screen model that took the concrete
/// `FleetModel` could not be stood up in a test without a socket.
@MainActor
protocol PresenceReporting: AnyObject {
    func viewing(_ session: UUID?)
}

@MainActor
protocol PromptSending: AnyObject {
    func sendPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    )
}

/// The third verb a session screen needs: here is an answer to the dialog this session is
/// blocked on.
///
/// **There is no `pendingPrompt` verb beside it, and that absence is the design.** What the
/// session is blocked on is *derived* from the feed this model already holds and the `activity`
/// the fleet already pushes — see `blocked(activity:)`. Nothing about a question is fetched,
/// so there is nothing here to fetch it with.
///
/// A third protocol rather than a third method on either existing one, for the reason there are
/// two already: a stub must be able to leave one verb outstanding while answering another, and
/// the transition worth asserting here — an answer nobody confirms — is one no real link
/// produces on demand.
@MainActor
protocol PromptAnswering: AnyObject {
    func answerPrompt(
        _ command: FleetCommand,
        then completion: @escaping (Result<Void, FleetRequestError>) -> Void
    )
}

/// One open session screen.
///
/// Thin on purpose, in the same spirit as `FleetModel`: it owns a `TimelineFeed` — which is
/// in `FleetKit` and unit-tested — plus the four things a screen genuinely adds, which are
/// *which* fetch is in flight, whether one already is, **how long one is allowed to take**,
/// and what to say when one fails. Anything here that starts to be about ordering, cursors
/// or dedupe belongs in `TimelineFeed` instead.
@MainActor
@Observable
final class SessionTimelineModel {
    /// What the screen draws when the feed is empty, and what it draws at the top while
    /// paging. Deliberately not a bare `isLoading` flag: "still loading", "this conversation
    /// is empty", and "the Mac refused" are the same empty list and three different screens,
    /// and collapsing them is how an empty state ends up claiming a session has no history
    /// when the fetch simply failed.
    enum Phase: Equatable {
        case idle
        case loading
        /// The Mac answered, and there is nothing to show **yet**.
        ///
        /// **Not a failure, and keeping it out of `.failed` is the whole point of the case.**
        /// A tab between being created and taking its first turn has no transcript, so the Mac
        /// answers `unreadable` — the honest answer to "what is in this file" when the file
        /// does not exist. Routed into `.failed`, that drew a warning and a "Try again" button
        /// over a session where nothing had gone wrong and where retrying fixes nothing: what
        /// ends this state is the agent taking a turn. Every new session passes through here,
        /// so it is the first thing a reader sees on a tab they just made.
        case notStarted
        case failed(String)
    }

    let sessionID: UUID

    private(set) var feed = TimelineFeed()
    private(set) var phase = Phase.idle
    /// Whether a page fetched upwards is in flight, so the scroll trigger cannot fire five
    /// times while the first one is still reading.
    private(set) var isLoadingOlder = false
    /// Why the last read of older history failed, or `nil`.
    ///
    /// **Separate from `phase`, and that separation is the whole reason a background prefetch
    /// is safe.** A read the reader never asked for must not be able to take the conversation
    /// off the screen: `phase` is what the screen draws *instead of* content, so a prefetch
    /// reaching it would replace a session full of history with "Not connected to your Mac"
    /// because the link dropped while somebody was reading. This is drawn above the oldest
    /// row instead, where the history that is missing would have been.
    private(set) var olderFailure: String?

    /// How many pages of history the phone keeps ahead of the reader.
    ///
    /// Three, because one is not a buffer. A page is `TimelineLimits.defaultLimit` records
    /// and a flick covers that, so a single page of runway puts the reader back on a spinner
    /// — which is the wait the "Load earlier" button used to make explicit, now made
    /// surprising. Three pages is roughly the distance a fast scroll covers in the time a
    /// page takes to arrive on a slow link, and it is a ceiling rather than a quota: a
    /// conversation with two pages of history left fetches two.
    ///
    /// Deliberately not "all of it". Backfilling a whole transcript is unbounded work on a
    /// phone, and `maxPageBytes` says a page can be 128 KB.
    static let prefetchPages = 3
    /// Messages this screen has sent and not yet seen come back. Drawn beside the
    /// conversation, never inside it — see `PromptOutbox`, which is where the reasoning lives.
    /// What is in the composer, held here rather than in the composer itself.
    ///
    /// **It moved because Reply fires from a timeline row.** A `@State` inside `PromptComposer`
    /// is reachable only from inside `PromptComposer`, and the whole point of the Reply action
    /// on a selection is that a row twenty rows up can put a quotation into the box. This model
    /// already owns everything else about the screen's send path, so the draft belongs beside
    /// the outbox it becomes.
    ///
    /// The composer still owns the *field* — its focus, its deferred repaint, its enablement.
    /// Only the string moved.
    var draft = ""

    /// Bumped every time a quotation is appended, so the composer can take focus.
    ///
    /// A counter rather than a `Bool` anyone has to reset: the second Reply in a row must be
    /// distinguishable from the first, and a flag that is already `true` is not. The composer
    /// watches this and nothing else — it never asks whether the draft changed, because a
    /// person typing must not be re-focused on every keystroke.
    private(set) var quoteTicks = 0

    /// Append `selection` to the draft as a quotation, the way replying to a message quotes it.
    ///
    /// - every line is prefixed, not just the first: a two-line quote with one marker is not a
    ///   quote, it is a quote and a stray sentence;
    /// - two trailing newlines, so the reader's own words start on a blank line under it;
    /// - it **appends**. A draft already being written is not discarded because someone
    ///   highlighted a sentence, and a second Reply stacks a second quotation rather than
    ///   replacing the first.
    ///
    /// An all-whitespace selection is dropped. The edit menu can be raised on one — a drag that
    /// caught only a paragraph break — and quoting it would put two blank markers in the box.
    func quote(_ selection: String) {
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let quoted = selection
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        let separator = draft.isEmpty || draft.hasSuffix("\n") ? "" : "\n"
        draft += separator + quoted + "\n\n"
        quoteTicks += 1
    }

    private(set) var outbox = PromptOutbox()

    /// Where the one answer this screen may have in flight has got to.
    ///
    /// **Keyed on the call, not a bare enum**, and that is what makes the harder race safe on
    /// this side: the user approves in the terminal, claude raises the next dialog, and the
    /// session never leaves `waiting` — so this state is never torn down by a screen
    /// transition. Filed against `toolu_ONE`, it must not disable the buttons for `toolu_TWO`.
    enum AnswerState: Equatable {
        case idle
        /// Dispatched. `ack` means *dispatched, not done* — the Mac's driver refuses to press
        /// Return on a screen it cannot confirm — so what clears this card is the transcript:
        /// the `tool_result` arrives, `blocked(activity:)` returns nil, and the card goes.
        case sent(call: String)
        /// The Mac refused, or nobody confirmed. The question stays visible with the reason
        /// under it, because the reader has to see what they were being asked.
        case failed(call: String, String)

        var call: String? {
            switch self {
            case .idle: return nil
            case .sent(let call), .failed(let call, _): return call
            }
        }
    }

    private(set) var answerState = AnswerState.idle

    @ObservationIgnored private let fleet:
        any TimelinePaging & PromptSending & PromptAnswering & PresenceReporting
    @ObservationIgnored private let timeout: Duration
    /// The fetch whose answer is still allowed to change anything, or `nil` when none is.
    ///
    /// A number rather than a `Bool`, and that is what makes the deadline below safe: an
    /// answer that arrives after its own deadline has already fired carries a number nobody
    /// is waiting on any more, so it is dropped instead of clearing a flag a *later* fetch
    /// set. With a `Bool` the late answer to a dead request would open the gate on a live
    /// one, and two fetches computed from the same cursor would run at once — which is the
    /// exact overlap the gate exists to prevent.
    @ObservationIgnored private var inFlight: Int?
    @ObservationIgnored private var lastFetch = 0
    @ObservationIgnored private var deadline: Task<Void, Never>?
    /// Pages of history read since the reader last came near the top, against
    /// `prefetchPages`. Reset by each trigger rather than accumulated, so the runway is a
    /// distance ahead of the reader and not a budget for the session.
    @ObservationIgnored private var olderRun = 0
    /// Whether the runway is still short and should keep filling once the slot is free.
    ///
    /// Separate from `isLoadingOlder`, which is only ever "a request is out right now". The
    /// runway spans several requests with gaps between them — and a gap can be a *forward*
    /// fetch that jumped the queue — so the intent has to outlive any one of them or the
    /// remaining pages are simply dropped.
    @ObservationIgnored private var wantsOlder = false
    /// A forward fetch that was refused because a prefetch held the slot, owed back.
    ///
    /// **The live edge outranks the runway**, which is why this exists at all. Every fetch
    /// shares one slot, and the prefetch now runs on a scroll rather than on a tap — so the
    /// read that follows a live turn, and the one that confirms a sent message reached the
    /// agent, are suddenly competing with three background reads and would simply be dropped.
    /// A dropped one leaves the conversation ending in the middle, or an outbox row saying a
    /// message never landed when it did. A `Bool` rather than a queue because every forward
    /// fetch computes its own anchor from `feed.newerAnchor` when it finally runs: two owed
    /// reads are the same read.
    @ObservationIgnored private var deferredNewer = false
    /// One deadline per send in flight, keyed by the send's own token.
    ///
    /// A table rather than the single `deadline` a fetch uses, because a person can tap Send
    /// twice before either answer lands and a shared slot would leave the first send with no
    /// deadline at all — the exact "waits forever" case this whole mechanism exists for.
    @ObservationIgnored private var promptDeadlines: [UUID: Task<Void, Never>] = [:]
    /// The answer whose result is still allowed to change anything, or `nil` when none is.
    /// A single slot rather than the table a send needs, because `answer(_:to:)` refuses a
    /// second answer while one is outstanding — one dialog, one decision.
    @ObservationIgnored private var answerInFlight: UUID?
    @ObservationIgnored private var answerDeadline: Task<Void, Never>?

    /// `timeout` is injectable so `SessionTimelineModelTests` can watch a deadline expire in
    /// milliseconds rather than in fifteen seconds. Nothing in the app passes it.
    init(
        sessionID: UUID,
        fleet: any TimelinePaging & PromptSending & PromptAnswering & PresenceReporting,
        timeout: Duration = .seconds(15)
    ) {
        self.sessionID = sessionID
        self.fleet = fleet
        self.timeout = timeout
    }

    /// The screen came on: the reader is looking at this session, and the feed has to be
    /// current.
    ///
    /// Both halves, in that order, because they are one event. Marking read first costs
    /// nothing if the fetch fails — the reader is still looking at the session either way,
    /// and spec §8's unread is about attention rather than about content having arrived.
    ///
    /// Called from `SessionTimelineScreen`'s `.task(id:)`, so it runs again whenever the
    /// screen comes back, which is correct for both halves: a session that went unread again
    /// while the reader was elsewhere is being looked at again now, and `loadLatest` asks for
    /// what is new rather than for the end of the file (see below). An unread mark for a
    /// session that is already read costs one frame and changes nothing — the Mac's
    /// `setUnread` returns early on an unchanged flag and emits no event.
    func open() {
        fleet.markRead(sessionID)
        loadLatest()
    }

    /// Make the screen current: the opening fetch, the fetch on coming back to a screen whose
    /// model was kept, and the recovery after a `reset`.
    ///
    /// **It asks for `.latest` only when the feed is empty**, and that is the one deliberate
    /// departure from this task's brief. `TimelineFeed`'s invariant is "ordered and deduped",
    /// not "contiguous": a `.latest` page landing on a feed that already holds an older range
    /// merges correctly and leaves a hole in the middle that nothing can see and nothing can
    /// close — the conversation's beginning, then a silent jump, then its end. `newerAnchor`
    /// is `.latest` on an empty feed and `.after(newest)` otherwise, so the hole cannot be
    /// opened in the first place; `chase` below is what walks the rest of the way to the live
    /// edge when the feed has been away long enough for that to be several pages.
    func loadLatest() {
        fetch(anchor: feed.newerAnchor, older: false)
    }

    /// Called when the reader comes within a page of the oldest history the phone holds —
    /// **not** when they reach it.
    ///
    /// **There is no "Load earlier" any more, and this is what replaced it.** The button was
    /// a deliberate choice once: an `onAppear` hung off the *top* row re-fires on every bounce
    /// of an over-scroll and lands its page while the list is still settling, which drags the
    /// reader upward. What made it tolerable was that the reader was never surprised by the
    /// wait — they had asked for it. That is the wrong trade: the wait is the defect, and the
    /// fix is to have already done the reading. The trigger now sits a page BELOW the top
    /// (`SessionTimelineScreen.prefetchTrigger`), which is both far enough from the rubber-band
    /// to be untouched by it and early enough that the page lands before the reader arrives.
    ///
    /// **Both conditions, and `hasOlder` is the one that stops the fetch.** `olderAnchor` is
    /// non-nil at the top of history too — a feed sitting on the first record still has a
    /// perfectly good `oldest` — so checking only the cursor would re-request the same first
    /// page forever. Under a tap that was a wasted round trip per tap; under a scroll trigger
    /// it is a loop for the life of the screen.
    ///
    /// Clearing `olderFailure` here is what makes a retry a retry: the screen re-arms this on
    /// the reader's own scroll, and a reason left over from the last attempt sitting above a
    /// running one is the same stale-explanation defect `topNotice` is suppressed for.
    func prefetchOlder() {
        guard feed.hasOlder, let anchor = feed.olderAnchor else { return }
        olderRun = 0
        olderFailure = nil
        wantsOlder = true
        fetch(anchor: anchor, older: true, quiet: true)
    }

    /// Called by the poll and by a fleet event for this session. Quiet: it does not touch
    /// `phase`, because a background poll that fails must not replace a screen full of
    /// conversation with an error — the connection banner on the list already says the phone
    /// is offline, and this screen's content is still the last thing the Mac said.
    ///
    /// There is no `hasNewer` to gate this on and there must not be: forwards, `hasMore` is a
    /// fact about the instant the file was read, so a screen that stopped polling on it would
    /// stop following a live agent.
    func loadNewer() {
        // The first fetch is not a poll, whatever triggered it: an opening screen with
        // nothing on it has to show a spinner and has to explain a refusal.
        guard feed.hasLoadedAnything else { return loadLatest() }
        fetch(anchor: feed.newerAnchor, older: false, quiet: true)
    }

    /// Hand a composed message to the Mac.
    ///
    /// **Validated here as well as on the Mac, and the two are not redundant.** The Mac's
    /// check is the guarantee — a client is not trusted to have checked anything — and this
    /// one is the difference between a composer that will not send and a round trip that
    /// comes back with an error for something the phone already knew.
    ///
    /// **The outbox is filed with `PromptText.value`, never the raw field text.**
    /// `PromptOutbox.reconcile` matches on exact string equality and `PromptText` strips
    /// trailing newlines before sending, so filing the raw string would file an entry no turn
    /// could ever match: a row that sits there telling the reader their message never landed
    /// when it did.
    ///
    /// **The deadline is the same fifteen seconds a fetch gets, and it matters more here.**
    /// `FleetConnector` answers `.disconnected` synchronously when there is no socket and
    /// drains its tables when one dies — but a HALF-open socket, a phone that lost its
    /// network path without a FIN, reports nothing at all until the TCP retransmit horizon,
    /// which is minutes. A fetch that vanishes leaves a spinner. A prompt that vanishes
    /// leaves a person believing they told an agent something.
    ///
    /// **It does not retry, and the entry it leaves says so.** A timeout cannot distinguish
    /// "the Mac never got it" from "the Mac got it and the ack was lost", and the second is
    /// where a silent retry types the message twice into a live session. The token would make
    /// a retry safe — `SessionStore.submitPrompt` dedupes on it — but only by resending the
    /// SAME token, and a token whose first send may still be sitting in a queue on the Mac is
    /// a resend nobody can reason about. So the row stays visible and the human decides.
    func send(_ raw: String) {
        guard let text = PromptText(raw) else { return }
        let token = UUID()
        outbox.add(id: token, text: text.value, alreadyShowing: feed.items)

        // Armed BEFORE the send, because the send can complete before it returns:
        // `FleetConnector.send(_:then:)` answers `.disconnected` synchronously by design, the
        // same asymmetry `fetch` arms its own deadline ahead of. Armed afterwards, this task
        // would outlive an entry that is already failed and fire over the top of the reason
        // the reader is looking at.
        let timeout = self.timeout
        promptDeadlines[token] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self,
                  self.promptDeadlines.removeValue(forKey: token) != nil
            else { return }
            self.outbox.fail(token, Self.noConfirmation)
        }

        fleet.sendPrompt(.prompt(id: sessionID, token: token, text: text.value)) {
            [weak self] result in
            // The deadline is claimed here, exactly as `claim(_:)` claims a fetch's: whichever
            // of the answer and the deadline gets here first wins, and the loser finds nothing
            // filed and does nothing.
            guard let self, let deadline = self.promptDeadlines.removeValue(forKey: token)
            else { return }
            deadline.cancel()
            switch result {
            case .success:
                self.outbox.accept(token)
                // The one fetch this send causes. `loadNewer` has no other caller in this app
                // — see its own comment, which describes a poll that does not exist — so
                // without this the transcript that would retire the entry is never re-read
                // and the outbox row sits there until the reader leaves the screen.
                self.loadNewer()
            case .failure(let error):
                self.outbox.fail(token, Self.promptMessage(for: error))
            }
        }
    }

    /// How long a blocked screen waits between asking again for the record that says what it
    /// is blocked ON, and how many times.
    ///
    /// Backs off, and is bounded. A `var` only so a test can shorten it — nothing in the app
    /// assigns it.
    @ObservationIgnored var promptRetries: [Duration] = [
        .milliseconds(900), .milliseconds(1_500), .seconds(3), .seconds(5), .seconds(8),
    ]

    /// Keep asking, while a blocked session has nothing to show for it.
    ///
    /// **The race, and why one retry was not enough.** claude writes its status file and its
    /// transcript by independent paths, so `waiting` can reach the phone before the record
    /// naming what it is waiting on. The screen used to cover that with a single deferred
    /// fetch — and when that one lost, nothing fired again: a waiting session emits no further
    /// activity change, the busy poll runs only while `busy`, and `.onChange(of:activity)`
    /// needs a change that never comes. The session sat saying "Waiting for you" with no card
    /// under it for as long as it stayed blocked. Intermittent by construction, which is why
    /// it was reported as "sometimes".
    ///
    /// **The condition is the card, not a count**, and that is what keeps this cheap. Most of
    /// the time the record is already in the feed when `waiting` arrives, and this returns
    /// having asked for nothing at all. When it is not, this stops the moment the card can be
    /// drawn rather than running its schedule out.
    ///
    /// **And it gives up.** A blocked session can sit for an hour, so a record that never
    /// arrives — a codex tab, a body this build cannot parse — must not become a poll that
    /// runs for the life of the screen. That objection is why the original was a single shot;
    /// the answer is a bound, not one attempt.
    func chaseBlockedPrompt(agent: String?, activity: String?) async {
        for delay in promptRetries {
            guard blocked(agent: agent, activity: activity) == nil else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            loadNewer()
        }
    }

    /// The reader has read a failure and wants the row gone.
    func dismiss(_ id: UUID) { outbox.dismiss(id) }

    /// The screen appeared or went away. Reported so the Mac can show, beside the tab, that a
    /// phone is on this conversation.
    func viewing(_ isViewing: Bool) { fleet.viewing(isViewing ? sessionID : nil) }

    /// What this session is blocked on, or nil.
    ///
    /// **Derived, never fetched.** `OpenPrompt.find` is the same function the Mac runs over the
    /// same transcript — shared in `FleetKit` precisely so the two cannot drift — and it runs
    /// here over `feed.items`, which the history channel has already delivered. That is why
    /// this feature adds no request, no reply frame and no event: a question appearing is an
    /// `activity` change (already pushed) plus records (already fetched on that change), and a
    /// question being answered on the Mac is a `tool_result` arriving on the next fetch.
    ///
    /// A function of `agent` and `activity` rather than a stored property, so it cannot go
    /// stale: the screen passes the live `WireSession` fields it is already reading. Both are
    /// `find`'s to judge — including whether this Mac can answer for that agent at all, which
    /// is why a codex tab is blocked on nothing here however it is drawn elsewhere.
    func blocked(agent: String?, activity: String?) -> OpenPrompt? {
        OpenPrompt.find(in: feed.items, agent: agent, activity: activity)
    }

    /// Answer the dialog `call` names.
    ///
    /// One in flight at a time, and on a permission dialog that guard is the difference between
    /// one decision and two. A state left over from a different call does not block this one —
    /// see `AnswerState`.
    /// Answer a whole set of questions in one command.
    ///
    /// One send, one token, one decision — the Mac walks the dialog and commits at the end, so
    /// there is no state here for "half answered". The same in-flight guard as `answer`: one
    /// dialog, one decision.
    func answerSet(_ selections: [[AnswerSelection]], to call: String) {
        answer(.answers(selections), to: call)
    }

    func answer(_ answer: PromptAnswer, to call: String) {
        guard answerInFlight == nil else { return }
        let token = UUID()
        answerInFlight = token
        answerState = .sent(call: call)

        // Armed BEFORE the send, because the send can complete before it returns:
        // `FleetConnector.send(_:then:)` answers `.disconnected` synchronously by design, the
        // same asymmetry `fetch` and `send(_:)` both arm ahead of.
        let timeout = self.timeout
        answerDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.claimAnswer(token) else { return }
            self.answerState = .failed(call: call, Self.noAnswerConfirmation)
        }

        fleet.answerPrompt(
            .answerPrompt(id: sessionID, token: token, call: call, answer: answer)
        ) { [weak self] result in
            guard let self, self.claimAnswer(token) else { return }
            switch result {
            case .success:
                // Stays `.sent`. What retires the card is the transcript — so pull it, for the
                // same reason `send(_:)` does: the Mac emits no frame when a Return lands.
                self.loadNewer()
            case .failure(let error):
                self.answerState = .failed(call: call, Self.answerMessage(for: error))
            }
        }
    }

    /// Whichever of the ack and the deadline arrives first wins; the loser finds nothing filed
    /// and does nothing. The same rule, and the same reason, as `claim(_:)`.
    private func claimAnswer(_ token: UUID) -> Bool {
        guard answerInFlight == token else { return false }
        answerInFlight = nil
        answerDeadline?.cancel()
        answerDeadline = nil
        return true
    }

    private func fetch(anchor: TimelineAnchor, older: Bool, quiet: Bool = false) {
        // Guards every fetch. Two overlapping requests would both be computed from the same
        // cursor, so the second would re-fetch what the first had already added.
        //
        // A refused BACKWARD fetch needs nothing remembered here: `wantsOlder` already says
        // the runway is short, and `drain` re-issues it from whatever `olderAnchor` has
        // become by then. A refused forward one is owed back — see `deferredNewer`.
        guard inFlight == nil else {
            if !older { deferredNewer = true }
            return
        }
        lastFetch += 1
        let fetch = lastFetch
        inFlight = fetch
        if older { isLoadingOlder = true }
        if !quiet, !feed.hasLoadedAnything { phase = .loading }

        // **The deadline, and it is not belt-and-braces.** Exactly-once delivery rests on the
        // socket eventually reporting an error, and on a half-open connection — a phone that
        // loses its network path without a FIN — nothing reports one: neither `FleetClient`
        // nor `FleetConnector` runs a liveness timer (`autoReplyPing` only *answers* pings),
        // so a pending request can sit for the TCP retransmit horizon, which is minutes. The
        // spinner lives in `phase`, so without this it is a spinner with no end and no
        // explanation — the precise failure this whole channel was built to avoid — and
        // worse, `inFlight` would never clear, so every later poll and every prefetch would
        // be silently refused for the life of the screen.
        //
        // Armed BEFORE the request is issued, because the request can complete before it
        // returns (`.disconnected` does, synchronously, by design). That completion cancels
        // this task and may start another fetch in the same frame; arming afterwards would
        // overwrite the new fetch's deadline with this dead one's.
        let timeout = self.timeout
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.claim(fetch) else { return }
            if older {
                self.olderFailure = "Your Mac didn't answer in time."
                self.wantsOlder = false
            } else if !quiet {
                self.phase = .failed("Your Mac didn't answer in time.")
            }
            // A timeout frees the slot exactly as an answer does, so whatever was owed on it
            // is owed now. Without this a forward fetch deferred behind a prefetch that then
            // timed out is never issued again, and the screen quietly stops following.
            self.drain()
        }

        fleet.timelinePage(
            .timeline(session: sessionID, anchor: anchor, limit: TimelineLimits.defaultLimit)
        ) { [weak self] result in
            guard let self, self.claim(fetch) else { return }
            switch result {
            case .success(let page):
                self.feed.merge(page)
                // The transcript is the only thing that confirms a sent message reached the
                // agent — see `PromptOutbox`. Done here rather than in `send` because the page
                // that holds it can arrive from any fetch: the `loadNewer` an ack triggers,
                // a reader scrolling, or a return to a screen kept in `FleetModel`.
                self.outbox.reconcile(with: self.feed.items)
                self.phase = .idle
                // A reset emptied the feed: the transcript these cursors came from is gone,
                // so start again from the end rather than leaving a blank screen that will
                // never fill in. `newerAnchor` is `.latest` again by itself now.
                if page.reset { return self.loadLatest() }
                if older {
                    self.olderRun += 1
                    self.olderFailure = nil
                } else if self.chase(page, from: anchor, quiet: quiet) {
                    // The forward chase took the slot; whatever else is owed waits for it.
                    return
                }
                self.drain()
            case .failure(let error):
                if older {
                    // Quiet in `phase`, loud where the missing history is. The runway stops
                    // here rather than spending its remaining pages on a link that just
                    // refused one — the reader's next scroll is what asks again.
                    self.olderFailure = Self.message(for: error)
                    self.wantsOlder = false
                } else if !quiet {
                    self.phase = Self.phase(for: error, hasItems: !self.feed.items.isEmpty)
                }
                self.drain()
            }
        }
    }

    /// Whether `fetch` is still the one being waited on, taking the wait with it if so.
    ///
    /// Both the answer and the deadline race through here and exactly one of them wins. The
    /// loser is dropped whole — including a perfectly good page that arrived a second after
    /// its deadline. Merging it instead would put content on screen while `phase` says the
    /// fetch failed, and a `reset` in that page would empty a feed that a newer fetch is
    /// already reading into. One round trip is the cost, and the poll re-issues it.
    private func claim(_ fetch: Int) -> Bool {
        guard inFlight == fetch else { return false }
        inFlight = nil
        isLoadingOlder = false
        deadline?.cancel()
        deadline = nil
        return true
    }

    /// Keep pulling forwards while the Mac says there is more, so the feed reaches the live
    /// edge instead of stopping one page short of it.
    ///
    /// A page is capped at `TimelineLimits.defaultLimit` records and `maxPageBytes`, so a
    /// screen returned to after a long turn is several pages behind, and one `.after` fetch
    /// would show the conversation ending in the middle with nothing to say it had. There is
    /// no affordance for that either — there is nothing in this screen a reader can touch to
    /// ask for what comes *after* what they hold, and the poll only runs while the session is
    /// busy. So it is chased here.
    ///
    /// **Only `.after`, because `hasMore` means different things in the two directions.** On
    /// a `.before` or a `.latest` page it reports what precedes `start` — `TimelineReader`
    /// budgets those from their oldest end — so chasing one would fetch forwards on the
    /// strength of a fact about the other end of the file, and backwards paging is the
    /// reader's own gesture besides: it must never run away from them.
    ///
    /// Terminates because `end` strictly advances. `TranscriptPager.forwards` reports
    /// `hasMore` as `end < size` and returns `end == cursor` with `hasMore` false when there
    /// is no complete record to hand over, so a chase cannot spin on a cursor that has not
    /// moved — and the progress guard here says so rather than trusting it from a file away.
    /// Returns whether it issued a fetch, because the caller has other work owed on the same
    /// slot and must not start a second one on top of this.
    @discardableResult
    private func chase(
        _ page: TimelinePage, from anchor: TimelineAnchor, quiet: Bool
    ) -> Bool {
        guard case .after(let cursor) = anchor, page.hasMore, page.end > cursor else {
            return false
        }
        fetch(anchor: .after(page.end), older: false, quiet: quiet)
        return true
    }

    /// The one place a freed slot decides what runs next.
    ///
    /// **Order is the policy: the live edge first, the runway second.** A forward fetch is
    /// owed when the reader is being shown a session that is still moving, or when a message
    /// they sent is waiting for the transcript to confirm it; more history is owed to a
    /// scroll that has not happened yet. Draining in the other order would hold a live turn
    /// off screen for up to `prefetchPages` round trips.
    ///
    /// Nothing is lost by that ordering: `wantsOlder` outlives the forward fetch, so the
    /// runway resumes from `olderAnchor` when that one lands, one page further along than it
    /// would have been.
    ///
    /// Terminates because every path either clears the flag it acted on or advances
    /// `olderRun`, and `fetch` re-enters here only through a completion.
    private func drain() {
        if deferredNewer {
            deferredNewer = false
            return loadNewer()
        }
        guard wantsOlder else { return }
        guard olderRun < Self.prefetchPages, feed.hasOlder, let anchor = feed.olderAnchor
        else { return wantsOlder = false }
        fetch(anchor: anchor, older: true, quiet: true)
    }

    /// Which screen a refusal puts up.
    ///
    /// **`unreadable` on an empty screen is the one that is not a failure.** It is what the Mac
    /// answers for a transcript that does not exist yet, which is every session from the moment
    /// it is created until its agent takes a first turn — so it needs an empty state, not a
    /// warning and a retry.
    ///
    /// **With a conversation already on screen the same code means the opposite** and stays a
    /// failure: a transcript the phone has already read cannot un-exist, so `unreadable` there
    /// is a file that has become unreadable, and calling that "not started yet" would tell the
    /// reader their session never began while its own history sits above the message.
    static func phase(for error: FleetRequestError, hasItems: Bool) -> Phase {
        if case .server(let code) = error, code == "unreadable", !hasItems { return .notStarted }
        return .failed(message(for: error))
    }

    /// Copy, not a code. Each of these is a different thing for the reader to do about it,
    /// which is why the wire distinguishes them at all.
    ///
    /// Internal rather than private so the mapping can be asserted directly, the same way
    /// `FleetModel.message(for:)` is: several of these codes need a Mac in a state no test
    /// on this side can put it in.
    static func message(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac."
        case .server(let code):
            switch code {
            case "unknown_session":
                return "This session is no longer open on your Mac."
            case "no_transcript":
                return "This agent doesn't keep a transcript, so there's nothing to show."
            case "unreadable":
                return "Nothing here yet — this session hasn't taken its first turn."
            default:
                return "Your Mac couldn't read this session (\(code))."
            }
        }
    }

    /// Deliberately not "try again": a retry after a timeout is the one action that can type
    /// the message twice. See `send(_:)`.
    static let noConfirmation =
        "Your Mac didn't confirm this. Check the conversation before sending it again."

    /// The Mac accepted this and ran out of time to type it.
    ///
    /// Worded as a fact about the Mac rather than an error, because nothing went wrong: the
    /// tab stayed busy for longer than the message stayed worth saying. It ends with what to
    /// do, because unlike every other failure here the message is genuinely gone and only the
    /// reader can decide whether it still applies.
    static let expired =
        "Your Mac stayed busy and didn't send this in time. Send it again if it still applies."

    /// A queued prompt the Mac dropped when its window closed. See `FleetEvent.promptExpired`.
    func promptExpired(_ token: UUID) { outbox.fail(token, Self.expired) }

    /// Copy for a prompt that did not land.
    ///
    /// **Deliberately NOT `message(for:)`.** The same wire code means a different thing on
    /// this channel: `unknown_session` on a fetch is "there is nothing to read", and on a
    /// prompt it is "the thing you were talking to is gone and your words did not reach it".
    /// Internal rather than private so the mapping can be asserted directly, the same way
    /// `message(for:)` is: several of these need a Mac in a state no test here can produce.
    static func promptMessage(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac, so this wasn't sent."
        case .server(let code):
            switch code {
            case "unknown_session":
                return "This session is no longer open on your Mac."
            case "unsupported_agent":
                return "Flight Deck can only type into a Claude session from here."
            case "not_running":
                return "There's no agent running in this tab right now."
            case PromptText.Rejection.tooLong.rawValue:
                return "That's longer than \(PromptText.maxCharacters) characters."
            case PromptText.Rejection.controlCharacters.rawValue:
                return "That text has characters Flight Deck won't type into a terminal."
            case PromptText.Rejection.empty.rawValue:
                return "There was nothing to send."
            default:
                return "Your Mac wouldn't send this (\(code))."
            }
        }
    }

    /// Deliberately not "try again": a retry after a timeout is the one action that can press
    /// Return twice in a live terminal — and on a permission dialog, approve twice. Same
    /// ruling, same wording discipline, as `noConfirmation`: the retry is conditioned on the
    /// reader looking at the terminal first, and there is no control on the card that offers
    /// one.
    static let noAnswerConfirmation =
        "Your Mac didn't confirm this. Check the terminal before answering again."

    /// Copy for an answer that did not land. **Deliberately not `promptMessage(for:)`** — the
    /// same wire code means a different thing on this channel, and `prompt_changed` has no
    /// meaning on that one at all.
    static func answerMessage(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac, so this wasn't sent."
        case .server(let code):
            switch code {
            case "prompt_changed":
                return "Your Mac has moved on from this."
            case "not_waiting":
                return "Your Mac isn't waiting on anything right now."
            case "unreadable_screen":
                return "Flight Deck couldn't read your Mac's screen. Try again in a moment."
            case "unanswerable":
                return "This one has to be answered on your Mac."
            case "unsupported_agent":
                return "Flight Deck can only answer a Claude session from here."
            case "unknown_session":
                return "This session is no longer open on your Mac."
            default:
                return "Your Mac wouldn't answer this (\(code))."
            }
        }
    }
}
