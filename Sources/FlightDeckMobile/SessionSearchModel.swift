import FleetKit
import Foundation
import Observation

/// Fetches transcript hits for a query, from wherever they actually live.
///
/// A protocol over `FleetModel` rather than `FleetModel` itself, for the same reason
/// `TimelinePaging` and `PromptSending` already are: a model that took the concrete type
/// could not be stood up in a test without a socket, a pairing and a real Mac — and the
/// transitions worth asserting here (a stale reply discarded, `.disconnected` producing a
/// footer rather than silence) are exactly the ones no real link produces on demand.
@MainActor
protocol TranscriptSearching: AnyObject {
    func searchTranscripts(
        query: String, limit: Int,
        then completion: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void
    )
}

/// What the search field binds to: the query, the merged results, and a footer for anything
/// the results alone cannot say.
///
/// **Two clocks, on purpose — mirroring the desktop's `SearchModel`.** Name matching runs in
/// memory over a few hundred candidates, so it happens on the keystroke with no debounce:
/// the list responds instantly, and it keeps working with the Mac asleep. Transcript
/// matching is a round trip to the Mac, so it waits `transcriptDebounce` behind the last
/// keystroke, which collapses a burst of typing into one request instead of one per letter.
///
/// **Why the split is safe, and more so than on the desktop.** `SearchRanker` puts
/// transcript hits in the last tier unconditionally, so a reply arriving late can only ever
/// append *below* what is already drawn — never reorder it. On the desktop that protects the
/// row someone is reaching for with Return; on a touch screen it protects something more
/// literal: a finger already descending on a row. A result set that reordered under a tap is
/// a mis-tap, and there is no equivalent of noticing a highlight move before committing.
@MainActor
@Observable
final class SessionSearchModel {
    /// How long transcript matching waits behind the last keystroke. The same constant as
    /// the desktop's `SearchModel.transcriptDebounce`, and it now buys a socket round trip
    /// rather than a local SQLite query.
    static let transcriptDebounce: Duration = .milliseconds(90)

    var query: String = "" { didSet { queryChanged(from: oldValue) } }
    private(set) var results: [SearchResult] = []
    private(set) var footer: Footer?

    /// What the results alone cannot say: that the phone is not asking, that the Mac is
    /// still reading, or that it asked and genuinely found nothing.
    enum Footer: Equatable {
        /// Not connected, named for the Mac so the line reads as a fact about this link
        /// rather than an accusation. The name results above it are real and complete for
        /// what they cover — only the transcript half is missing.
        ///
        /// **Never rendered as `.empty`.** A disconnected phone is in no position to make a
        /// claim about the corpus — the same class of quiet lie the stale-fleet banner
        /// exists to prevent.
        case offline(String)
        /// Carried on a search reply during the Mac's one-time backfill, mirroring the
        /// desktop's footer: a search that silently returns less than it should is worse
        /// than one that admits it is still reading.
        case indexing(done: Int, total: Int)
        /// Only shown once the Mac has genuinely answered and found nothing — never inferred
        /// from silence.
        case empty
    }

    private let transport: any TranscriptSearching
    private let macName: String
    private var candidates: [NameCandidate] = []
    /// The transcript hits currently merged in. Cleared on every query change — dropped
    /// immediately rather than when the replacement arrives, which is what stops a previous
    /// query's evidence surviving under a new one.
    private var transcripts: [TranscriptHit] = []
    private var debounceTask: Task<Void, Never>?

    init(transport: any TranscriptSearching, macName: String) {
        self.transport = transport
        self.macName = macName
    }

    /// The names to match against — sessions, projects and past conversations, flattened by
    /// `PhoneSearchCandidates`. Pushed in by the owner rather than pulled from `FleetModel`
    /// directly, which keeps this type testable without a fleet.
    func candidatesChanged(_ candidates: [NameCandidate]) {
        self.candidates = candidates
        rerank()
    }

    private func queryChanged(from old: String) {
        guard query != old else { return }
        // Dropped immediately, not when the replacement arrives: otherwise a query with no
        // transcript hits of its own would leave the previous query's hits — and its footer
        // — on screen until its own reply lands.
        transcripts = []
        footer = nil
        rerank()
        scheduleTranscriptSearch()
    }

    private func scheduleTranscriptSearch() {
        debounceTask?.cancel()
        // A query FTS5 cannot match — empty, or whitespace only — has nothing to ask the Mac
        // for. Sending it anyway would cost a round trip for a reply the Mac itself would
        // answer with zero hits (see `FleetService`'s own guard on this same expression).
        guard FTS5Query.match(for: query) != nil else { return }
        let query = self.query
        let limit = SearchLimits.maxHits

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.transcriptDebounce)
            // The common case: superseded while still waiting out the debounce, caught here
            // before a request is even issued — what actually keeps a fast typist's several
            // keystrokes down to one request.
            guard !Task.isCancelled, let self else { return }

            self.transport.searchTranscripts(query: query, limit: limit) { [weak self] result in
                guard let self else { return }
                // A reply for a query that is no longer current is discarded outright, not
                // merged — the phone's version of the desktop's cancellation, and what keeps
                // a superseded query's evidence from ever landing under a new one.
                //
                // Detection is by QUERY VALUE, not request identity — there is no per-request
                // token here. That is sufficient rather than merely convenient: if a user
                // types "rena", deletes to "ren", and retypes "rena" inside one debounce
                // window, the still-outstanding first reply is accepted for the second
                // request too. That is harmless because `rerank()` is a pure function of the
                // CURRENT `query` and `transcripts` — accepting a by-value-current reply
                // yields exactly what a fresh request for the identical string would produce,
                // at the cost of one redundant round trip the debounce would otherwise have
                // sent anyway.
                guard self.query == query else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Result<WireSearchHits, FleetRequestError>) {
        switch result {
        case .success(let hits):
            transcripts = hits.hits
            rerank()
            if let indexing = hits.indexing {
                footer = .indexing(done: indexing.done, total: indexing.total)
            } else if results.isEmpty {
                footer = .empty
            } else {
                footer = nil
            }
        case .failure:
            // Every refusal — `.disconnected` and everything else the socket can say — gets
            // the same footer. A phone that could not reach the Mac is in no position to
            // distinguish "not connected" from any other refusal in a way a person could act
            // on differently, and both leave it equally unable to claim the corpus is empty.
            footer = .offline(macName)
        }
    }

    private func rerank() {
        results = SearchRanker.rank(names: candidates, query: query, transcripts: transcripts)
    }
}
