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
public enum SearchRanker {
    public static func rank(
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

        // Transcript hits are GROUPED by conversation, not listed flat.
        //
        // The index answers per message, so a conversation mentioning the query twenty times
        // produced twenty rows, every one carrying the same `name · project` heading — reading as
        // the same session repeated, and crowding every other conversation off screen.
        //
        // Each conversation now contributes at most `maxMatchesPerConversation` adjacent rows:
        // the first carries the heading, the rest are continuations the row view draws indented
        // and headless. They stay separate rows rather than becoming one multi-line row so that
        // arrow-key navigation still steps through individual matches, and so activating any of
        // them is the same one-Return gesture.
        //
        // Order within a group is the order the index returned, which is BM25 relevance — so the
        // heading row is the strongest moment in that conversation, and the cap drops the weakest
        // rather than an arbitrary few.
        var order: [String] = []
        var byConversation: [String: [TranscriptHit]] = [:]
        for hit in transcripts {
            if byConversation[hit.conversationID] == nil { order.append(hit.conversationID) }
            byConversation[hit.conversationID, default: []].append(hit)
        }

        // Groups are ordered by their best hit under the same rules a name match gets: recency
        // decides, with the id as the total-order tiebreak so identical keystrokes cannot
        // reshuffle the list.
        let groups: [[TranscriptHit]] = order
            .compactMap { byConversation[$0] }
            .sorted { lhs, rhs in
                guard let a = lhs.first, let b = rhs.first else { return false }
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
                return a.conversationID < b.conversationID
            }

        var grouped: [SearchResult] = []
        for group in groups {
            // `position`, not `offset` — this is an enumeration index into the group, and
            // `hit.offset` two lines below is a byte offset into the transcript. Both are
            // legitimately named `offset` on their own, so this file is the one place they
            // would sit beside each other under the same name if either kept it.
            for (position, hit) in group.prefix(maxMatchesPerConversation).enumerated() {
                grouped.append(SearchResult(
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
                    conversationID: hit.conversationID,
                    isContinuation: position > 0,
                    offset: hit.offset
                ))
            }
        }

        // Names are sorted; the grouped block is appended whole. Sorting everything together
        // would interleave conversations and break the grouping, and it is safe to append
        // because `.transcript` is unconditionally the last tier — the property that also lets
        // late-arriving results append below the highlighted row without moving it.
        return results.sorted(by: byTierThenRecency) + grouped
    }

    /// How many matches one conversation may contribute before the rest are dropped.
    ///
    /// Three is deliberately small. The point of showing more than one is evidence that the
    /// conversation is the right one; past a few, extra matches stop informing that judgement and
    /// start pushing other conversations out of the visible rows.
    public static let maxMatchesPerConversation = 3

    private static func byTierThenRecency(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        // Sessions before projects at equal tier: the deck is session-centric, and activating a
        // result opens a session either way, so a session is the likelier intent when both names
        // match equally well.
        if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        // Total order. Without this, two candidates identical in tier and timestamp sort
        // unstably and the list reshuffles between identical keystrokes — exactly the jitter
        // the stable-selection property exists to prevent.
        return lhs.id < rhs.id
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
