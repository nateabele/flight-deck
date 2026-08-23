import FleetKit
import Foundation
import Observation

/// The one thing a session screen needs from the fleet: a page, or a reason there is not one.
///
/// A protocol over `FleetModel`'s single method rather than `FleetModel` itself, for exactly
/// one reason: `FleetModel`'s connector is private and answers nothing without a real socket,
/// a real pairing and a real Mac, so a screen model that took the concrete type could not
/// have a single phase transition asserted — and the phases below are where a spinner gets
/// stuck and where an error gets swallowed. One method wide and `AnyObject`-bound, so it adds
/// no seam the app can drift into using for anything else.
@MainActor
protocol TimelinePaging: AnyObject {
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
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
        case failed(String)
    }

    let sessionID: UUID

    private(set) var feed = TimelineFeed()
    private(set) var phase = Phase.idle
    /// Whether a page fetched upwards is in flight, so the scroll trigger cannot fire five
    /// times while the first one is still reading.
    private(set) var isLoadingOlder = false

    @ObservationIgnored private let fleet: any TimelinePaging
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

    /// `timeout` is injectable so `SessionTimelineModelTests` can watch a deadline expire in
    /// milliseconds rather than in fifteen seconds. Nothing in the app passes it.
    init(sessionID: UUID, fleet: any TimelinePaging, timeout: Duration = .seconds(15)) {
        self.sessionID = sessionID
        self.fleet = fleet
        self.timeout = timeout
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

    /// Called when the top of the list comes into view.
    ///
    /// **Both conditions, and `hasOlder` is the one that stops the fetch.** `olderAnchor` is
    /// non-nil at the top of history too — a feed sitting on the first record still has a
    /// perfectly good `oldest` — so checking only the cursor would re-request the same first
    /// page forever, with a spinner on the row every time.
    func loadOlder() {
        guard feed.hasOlder, let anchor = feed.olderAnchor else { return }
        fetch(anchor: anchor, older: true)
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

    private func fetch(anchor: TimelineAnchor, older: Bool, quiet: Bool = false) {
        // Guards every fetch. Two overlapping requests would both be computed from the same
        // cursor, so the second would re-fetch what the first had already added.
        guard inFlight == nil else { return }
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
        // worse, `inFlight` would never clear, so every later poll and every "Load earlier"
        // tap would be silently refused for the life of the screen.
        //
        // Armed BEFORE the request is issued, because the request can complete before it
        // returns (`.disconnected` does, synchronously, by design). That completion cancels
        // this task and may start another fetch in the same frame; arming afterwards would
        // overwrite the new fetch's deadline with this dead one's.
        let timeout = self.timeout
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.claim(fetch) else { return }
            guard !quiet else { return }
            self.phase = .failed("Your Mac didn't answer in time.")
        }

        fleet.timelinePage(
            .timeline(session: sessionID, anchor: anchor, limit: TimelineLimits.defaultLimit)
        ) { [weak self] result in
            guard let self, self.claim(fetch) else { return }
            switch result {
            case .success(let page):
                self.feed.merge(page)
                self.phase = .idle
                // A reset emptied the feed: the transcript these cursors came from is gone,
                // so start again from the end rather than leaving a blank screen that will
                // never fill in. `newerAnchor` is `.latest` again by itself now.
                if page.reset { return self.loadLatest() }
                self.chase(page, from: anchor, quiet: quiet)
            case .failure(let error):
                guard !quiet else { return }
                self.phase = .failed(Self.message(for: error))
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
    /// no affordance for that either — "Load earlier" is at the top, and the poll only runs
    /// while the session is busy. So it is chased here.
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
    private func chase(_ page: TimelinePage, from anchor: TimelineAnchor, quiet: Bool) {
        guard case .after(let cursor) = anchor, page.hasMore, page.end > cursor else { return }
        fetch(anchor: .after(page.end), older: false, quiet: quiet)
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
}
