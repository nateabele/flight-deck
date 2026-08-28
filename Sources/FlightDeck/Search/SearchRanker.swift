import Foundation

/// Merges the two halves of search into the one list the overlay draws.
///
/// **The two rules, in order.** Match quality tiers the list; within a tier the most
/// recently active thing wins. That is the whole ordering, and it is deliberately not a
/// blended score: BM25 and fuzzy-subsequence scores are not on the same scale, and any
/// constant that mixed them would be a magic number nobody could defend.
///
/// **Where BM25 went.** It still decides *membership* in the transcript tier — the index
/// applies `LIMIT 200` ordered by BM25, so relevance chooses which 200 of possibly thousands
/// of matches are worth showing. This type then orders those 200 by recency. Relevance
/// selects; recency orders.
///
/// **The property this preserves.** Transcript hits are always the last tier, so results
/// arriving late from the debounced index query can only ever append *below* what is already
/// on screen. The highlighted row can never be shoved out from under the user by results
/// landing — which is why `SearchModel` can track selection by identity and have it hold.
enum SearchRanker {
    static func rank(
        names: [NameCandidate], query: String, transcripts: [TranscriptHit]
    ) -> [SearchResult] {
        // Nothing typed: the deck, most recent first. Projects are left out because a list
        // of every project is not what ⌘K-Return means, and transcripts because an empty
        // query gives FTS5 nothing to match — see `FTS5Query.match` returning nil.
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return names
                .filter { if case .session = $0.kind { return true } else { return false } }
                .sorted(by: recencyThenID)
                .map { SearchResult(candidate: $0, tier: .exact, ranges: []) }
        }

        var results: [SearchResult] = names.compactMap { candidate in
            guard let match = NameMatcher.score(candidate.name, against: query) else { return nil }
            return SearchResult(candidate: candidate, tier: match.tier, ranges: match.matchedRanges)
        }

        results += transcripts.map { hit in
            SearchResult(
                // `hit.rowID` is `message.id`, unique per row unlike `(conversationID,
                // timestamp)` — see the `TranscriptHit.rowID` doc comment for why that
                // pair collides.
                id: "\(hit.conversationID)#\(hit.rowID)",
                kind: .conversation(hit.conversationID),
                title: hit.conversationName,
                projectName: URL(fileURLWithPath: hit.projectPath).lastPathComponent,
                projectPath: hit.projectPath,
                tier: .transcript,
                recency: hit.timestamp,
                highlightedRanges: [],
                snippet: hit.snippet,
                conversationID: hit.conversationID
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            // Sessions before projects at equal tier: the deck is session-centric, and
            // activating a result opens a session either way, so a session is the likelier
            // intent when both names match equally well.
            if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            // Total order. Without this, two candidates identical in tier and timestamp sort
            // unstably and the list reshuffles between identical keystrokes — exactly the
            // jitter the stable-selection property exists to prevent.
            return lhs.id < rhs.id
        }
    }

    private static func recencyThenID(_ lhs: NameCandidate, _ rhs: NameCandidate) -> Bool {
        lhs.lastActivity != rhs.lastActivity ? lhs.lastActivity > rhs.lastActivity : lhs.id < rhs.id
    }
}

private extension SearchResult {
    init(candidate: NameCandidate, tier: MatchTier, ranges: [Range<String.Index>]) {
        self.init(
            id: candidate.id, kind: candidate.kind, title: candidate.name,
            projectName: candidate.projectName, projectPath: candidate.projectPath,
            tier: tier, recency: candidate.lastActivity, highlightedRanges: ranges,
            snippet: nil, conversationID: candidate.conversationID
        )
    }

    /// Sessions, then projects, then conversations. Only consulted within a tier.
    var kindRank: Int {
        switch kind {
        case .session: return 0
        case .project: return 1
        case .conversation: return 2
        }
    }
}
