import Foundation
import SwiftUI

/// What the overlay binds to: the query, the ranked results, and the highlighted row.
///
/// **Two clocks, on purpose.** Name matching is in-memory over a few hundred candidates, so
/// it runs on the keystroke with no debounce — the list responds instantly. Transcript
/// matching goes to SQLite, so it waits 90 ms, which turns a fast typist's six keystrokes
/// into one query.
///
/// **Why that split is safe.** `SearchRanker` puts transcript hits in the last tier
/// unconditionally, so results arriving late can only append *below* what is drawn. Combined
/// with tracking selection by result id rather than by row index, the highlighted row cannot
/// be shoved out from under a user who is already reaching for Return.
@MainActor
final class SearchModel: ObservableObject {
    /// How long transcript matching waits behind the last keystroke. Long enough to collapse
    /// a burst of typing into one query, short enough that pausing to read feels immediate.
    static let transcriptDebounce: Duration = .milliseconds(90)

    /// How many transcript hits BM25 selects before recency reorders them (§7).
    static let transcriptLimit = 200

    @Published var query: String = "" { didSet { queryChanged(from: oldValue) } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedID: SearchResult.ID?
    @Published private(set) var indexingProgress: SearchIndexBuilder.Progress?

    private let index: SearchIndex
    private let projects: () -> [String]
    private var candidates: [NameCandidate] = []
    /// The transcript hits currently merged in. Cleared whenever the query changes, so a
    /// previous query's evidence can never survive under a new one.
    private var transcripts: [TranscriptHit] = []
    private var debounceTask: Task<Void, Never>?

    init(index: SearchIndex, projects: @escaping () -> [String]) {
        self.index = index
        self.projects = projects
    }

    /// The names to match against — sessions, projects, and conversations from the index.
    /// Pushed in by the owner rather than pulled from `SessionStore`, which keeps this type
    /// testable without a store.
    func candidatesChanged(_ candidates: [NameCandidate]) {
        self.candidates = candidates
        rerank()
    }

    func indexingProgressChanged(_ progress: SearchIndexBuilder.Progress?) {
        indexingProgress = progress
    }

    func open() {
        query = ""
        rerank()
    }

    func close() {
        debounceTask?.cancel()
        debounceTask = nil
        transcripts = []
        query = ""
        results = []
        selectedID = nil
    }

    /// Arrow-key movement. Clamps rather than wraps: with eight rows visible, wrapping from
    /// the top of a 200-result list to its bottom is disorienting, and the top is where the
    /// best match already is.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { selectedID = nil; return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    func activateSelection() -> SearchResult? {
        results.first { $0.id == selectedID } ?? results.first
    }

    private func queryChanged(from old: String) {
        guard query != old else { return }
        // Dropped immediately, not when the replacement arrives: otherwise a query with no
        // transcript hits leaves the previous query's hits on screen until it returns.
        transcripts = []
        rerank()
        scheduleTranscriptSearch()
    }

    private func scheduleTranscriptSearch() {
        debounceTask?.cancel()
        guard let match = FTS5Query.match(for: query) else { return }
        let projects = self.projects()
        let limit = Self.transcriptLimit

        debounceTask = Task { [weak self, index] in
            try? await Task.sleep(for: Self.transcriptDebounce)
            // The common case: superseded while still waiting out the debounce. Caught here,
            // this query never reaches SQLite at all — which is what actually keeps a fast
            // typist's six keystrokes down to one query, not the cancellation below.
            guard !Task.isCancelled else { return }

            // Off the main actor: the query itself is sub-millisecond on a warm index, but
            // it can contend with a backfill's writer, and blocking the main actor there
            // would stutter the panel's height animation. `Task.detached` does NOT inherit
            // this task's cancellation, so a query that is already running past this point
            // runs to completion in SQLite regardless of what is typed next — there is no
            // clean Swift 5 equivalent for synchronous work that would abort it. The guard
            // below only stops a stale result from being *applied*; it cannot stop the
            // search itself. That is still enough: a stale result can never overwrite the
            // screen, so the highlighted row can never be shoved out from under someone
            // reaching for Return, even though a superseded-mid-query search is not aborted.
            let hits = await Task.detached(priority: .userInitiated) {
                (try? index.search(match, projects: projects, limit: limit)) ?? []
            }.value

            guard !Task.isCancelled, let self else { return }
            self.transcripts = hits
            self.rerank()
        }
    }

    private func rerank() {
        results = SearchRanker.rank(names: candidates, query: query, transcripts: transcripts)
        // Selection is held by identity across reranks, so a late-arriving batch of
        // transcript hits leaves the highlighted row exactly where it was. It only resets
        // when the row it named is genuinely gone — which is what a changed query does.
        if selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }
}
