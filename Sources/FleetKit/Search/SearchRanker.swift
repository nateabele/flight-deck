import Foundation

/// Merges the two halves of search into the one list the overlay draws.
///
/// **The rules, in order.** Match quality tiers the list; within a tier an open session beats
/// a closed conversation; then the most recently active thing wins. That is the whole
/// ordering, and it is deliberately not a blended score: BM25 and fuzzy-subsequence scores
/// are not on the same scale, and any constant that mixed them — "open sessions get +N" —
/// would be a magic number nobody could defend. Putting openness *below* match quality is
/// what makes it a tiebreak: a closed conversation that matches better still wins.
///
/// **Where BM25 went.** It still decides *membership* in the transcript tier — the index
/// applies `LIMIT 200` ordered by BM25, so relevance chooses which 200 of possibly thousands
/// of matches are worth showing. This type then orders those conversations by how closely
/// their snippets match the typed text (`TranscriptMatch`), then openness, then recency.
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

        // Automated groups last. This is done HERE, in the group ordering, and not by leaning
        // on `MatchTier`'s `<`: the grouped block is appended whole below the sorted name
        // matches (see the return statement), so the tier a grouped row carries never reaches
        // a comparator. Partitioning the groups is what actually moves them, and doing it at
        // group granularity is what keeps a conversation's continuation rows adjacent to the
        // heading row they belong to.
        //
        // Within each partition: how well the shown text matches what was typed, then whether
        // the conversation has a tab open, then recency. Open-before-closed sits BELOW match
        // quality on purpose — it decides between conversations matching the same words the
        // same way, and never lets an open tab's scattered hit outrank a closed conversation
        // that holds the exact phrase.
        let open = openConversations(in: names)
        let typed = TranscriptMatch.normalized(query)
        let groups: [[TranscriptHit]] = order
            .compactMap { byConversation[$0] }
            .map { hits in
                // Judged over the rows that will be SHOWN, so the evidence for a group's place
                // is on screen rather than in a match the cap dropped.
                (hits: hits, match: TranscriptMatch.best(of: hits.prefix(maxMatchesPerConversation), for: typed))
            }
            .sorted { lhs, rhs in
                guard let a = lhs.hits.first, let b = rhs.hits.first else { return false }
                let aAutomated = a.provenance == TranscriptHit.automatedProvenance
                let bAutomated = b.provenance == TranscriptHit.automatedProvenance
                if aAutomated != bAutomated { return !aAutomated }
                if lhs.match != rhs.match { return lhs.match < rhs.match }
                let aOpen = open.contains(a.conversationID)
                let bOpen = open.contains(b.conversationID)
                if aOpen != bOpen { return aOpen }
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
                return a.conversationID < b.conversationID
            }
            .map(\.hits)

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
                    // The row's own label must be honest about what it is, even though the
                    // comparator above is not what placed it — see the group-sort comment.
                    tier: hit.provenance == TranscriptHit.automatedProvenance ? .automated : .transcript,
                    recency: hit.timestamp,
                    highlightedRanges: [],
                    snippet: hit.snippet,
                    conversationID: hit.conversationID,
                    isContinuation: position > 0,
                    offset: hit.offset,
                    agent: hit.agent, workingDirectory: hit.workingDirectory,
                    transcriptPath: hit.transcriptPath
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

    /// The conversation ids that have a tab in the deck right now.
    ///
    /// Both ends' session candidates carry their pinned conversation id — the desk from the
    /// session itself, the phone from `WireConversationCatalogue.sessionConversations`. The
    /// tab-id fallback is for a candidate built without one: a claude tab starts pinned to its
    /// own id, so that is the right guess when nothing better is known.
    private static func openConversations(in names: [NameCandidate]) -> Set<String> {
        Set(names.compactMap { candidate in
            guard case .session(let tab) = candidate.kind else { return nil }
            return candidate.conversationID ?? tab.uuidString.lowercased()
        })
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
            snippet: nil, conversationID: candidate.conversationID,
            agent: candidate.agent, transcriptPath: candidate.transcriptPath
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

/// How closely a transcript hit's snippet matches the typed text, as a tier — the transcript
/// counterpart to `MatchTier`'s exact/prefix/fuzzy, and tiered for the same reason: BM25 is
/// not on a scale anything else in the ranker can be compared against, and a blended "open
/// sessions get +N" score would be a constant nobody could defend.
///
/// Judged from the snippet because the snippet is what both ends hold: the phone receives
/// hits over the wire with no access to the index, and the Mac and the phone must order the
/// same hits the same way.
enum TranscriptMatch: Int, Comparable {
    /// The typed words appear together, in order, each one whole.
    case phrase = 0
    /// Together and in order, but the last word only as the start of a longer one — "rename"
    /// inside "renamed", or a word still being typed.
    case phrasePrefix = 1
    /// FTS5 matched every term, but not side by side.
    case scattered = 2

    static func < (lhs: TranscriptMatch, rhs: TranscriptMatch) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Lowercased, sentinels and ellipses stripped, whitespace collapsed to single spaces.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .filter { $0 != SnippetSentinel.open && $0 != SnippetSentinel.close && $0 != "…" }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func best<S: Sequence>(of hits: S, for typed: String) -> TranscriptMatch
    where S.Element == TranscriptHit {
        hits.map { of($0.snippet, for: typed) }.min() ?? .scattered
    }

    static func of(_ snippet: String, for typed: String) -> TranscriptMatch {
        guard !typed.isEmpty else { return .scattered }
        let text = normalized(snippet)
        var best = TranscriptMatch.scattered
        var searchFrom = text.startIndex
        while let found = text.range(of: typed, range: searchFrom..<text.endIndex) {
            // Only a match starting on a word boundary counts — FTS5 matches tokens, so "name"
            // inside "rename" is not what it found. A match ending on one is a whole phrase.
            if isBoundary(text, before: found.lowerBound) {
                if isBoundary(text, after: found.upperBound) { return .phrase }
                best = .phrasePrefix
            }
            searchFrom = text.index(after: found.lowerBound)
        }
        return best
    }

    private static func isBoundary(_ text: String, before index: String.Index) -> Bool {
        index == text.startIndex || !isWordCharacter(text[text.index(before: index)])
    }

    private static func isBoundary(_ text: String, after index: String.Index) -> Bool {
        index == text.endIndex || !isWordCharacter(text[index])
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
