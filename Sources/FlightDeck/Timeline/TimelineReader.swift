import FleetKit
import Foundation

enum TimelineReadFailure: Error, Equatable, Sendable {
    /// The transcript could not be read as one, and the client should say "no history" and be
    /// free to ask again. Ordinary rather than exceptional, and it deliberately covers two
    /// states that are worth telling apart in a log and not on a screen:
    ///
    /// - **There is no file.** A claude tab that has not taken its first turn has none, and
    ///   `claude` creates one only when it first has something to persist.
    /// - **There is a file and it holds no line boundary** within the pager's scan budget —
    ///   a record still being written, or something that is not a JSONL transcript at all.
    ///
    /// Folding them together costs a distinction; not folding them costs more. The only other
    /// answer available for the second state is an empty page, which is byte-identical to the
    /// one a genuinely empty transcript produces, so a phone would render "this conversation
    /// is empty" over readable history with nothing to retry and nothing to log. See
    /// `TranscriptPager.lastBoundary`.
    case unreadable
}

/// Composes a page: which lines (`TranscriptPager`), what they mean (the agent's mapper), and
/// how much of it a phone gets (`TimelineLimits`).
///
/// Pure apart from the file read and free of actor state, so it runs off the main actor —
/// `TimelineService` dispatches it exactly the way `TranscriptWatcher` dispatches `Scan.read`,
/// and for the same reason: transcript records are large, and parsing them on the main thread
/// at the moment an agent is producing output is a visible stall.
enum TimelineReader: Sendable {
    static func page(
        session: UUID, agent: AgentID, url: URL, anchor: TimelineAnchor, limit: Int
    ) -> Result<TimelinePage, TimelineReadFailure> {
        // Clamped at BOTH ends, here. Downward because a limit is a hint about what a screen
        // wants and refusing an over-eager client turns a mildly greedy request into a broken
        // one — `TimelineLimits.maxLimit` says so. Upward because `FleetRequest` decodes
        // `limit` off the wire as a bare `Int` with no floor, and zero or less is a page that
        // cannot make progress: no records, and a cursor that has not moved.
        //
        // `TranscriptPager` holds the same floor, and that is defence in depth rather than a
        // duplicate: it is the layer where a negative traps, this is the layer that owns what
        // a request means, and neither is entitled to assume the other still clamps.
        let limit = min(max(limit, 1), TimelineLimits.maxLimit)
        guard let source = TranscriptPager.page(url: url, anchor: anchor, limit: limit) else {
            return .failure(.unreadable)
        }
        if source.reset {
            // Nothing to map and nothing to budget: every offset the client holds names a
            // different record now, so the page carries the signal and no content.
            return .success(TimelinePage(
                session: session, items: [], start: source.start, end: source.end,
                hasMore: false, reset: true
            ))
        }

        // Mapped per line, keeping each line's items together, because the budget below drops
        // whole RECORDS. Half a record on screen — a tool call with no result, an assistant
        // message missing its second paragraph — is worse than one fewer record.
        let mapper = self.mapper(for: agent)
        let mapped: [(line: SourceLine, items: [TimelineItem])] = source.lines.map {
            ($0, mapper($0.text, $0.offset).map(capped))
        }

        // Backwards anchors trim the oldest end and move `start`; forwards trims the newest
        // and moves `end`. The direction matters: a client scrolling up wants what is nearest
        // the cursor it gave, and trimming the wrong end would hand it a gap it can never
        // close because the cursor it is told to use has already moved past the hole.
        let fromOldest: Bool
        switch anchor {
        case .latest, .before: fromOldest = true
        case .after: fromOldest = false
        }
        let kept = withinBudget(mapped, droppingFromOldest: fromOldest)
        let dropped = kept.count < mapped.count

        // **The pager's cursors, carried verbatim, unless the budget moved that end.**
        // Never recomputed from `items`: when the oldest boundary in a pager page is a blank
        // line, `start` names the blank and the first record begins a byte later, so deriving
        // the cursor from the first item shifts it past that byte and the next page up never
        // returns it. `TranscriptPage.start` documents this.
        //
        // When the budget did drop from an end, that end must move with what it dropped, or
        // the page claims a byte range wider than the records it carries and the next request
        // from that cursor re-serves what the client already has.
        let start = dropped && fromOldest ? (kept.first?.line.offset ?? source.end) : source.start
        // `+ 1` is the `\n` the pager stripped: `SourceLine.text` is the line's bytes minus
        // exactly its terminator, so this is the boundary just past the last record kept.
        let end = dropped && !fromOldest
            ? (kept.last.map { $0.line.offset + $0.line.text.utf8.count + 1 } ?? source.start)
            : source.end
        return .success(TimelinePage(
            session: session,
            items: kept.flatMap(\.items),
            start: start,
            end: end,
            // `hasMore` accounts for what the BUDGET dropped as well as for what the pager
            // could not reach: a page that silently shed three records while reporting "that
            // is everything" is a conversation with a hole in it, and the whole file fitting
            // in one pager window is exactly when that happens.
            hasMore: source.hasMore || dropped,
            reset: false
        ))
    }

    private static func mapper(for agent: AgentID) -> (String, Int) -> [TimelineItem] {
        switch agent {
        case .claude: return ClaudeTimelineMapper.items(inLine:at:)
        case .codex: return CodexTimelineMapper.items(inRolloutLine:at:)
        }
    }

    /// Cuts an oversized body and records what was dropped, so a client can say "showing the
    /// first 64 KB of 210 KB" rather than presenting a partial file read as a whole one.
    ///
    /// Cut on a UTF-8 **character** boundary, not a byte one: slicing bytes and decoding would
    /// substitute a replacement character for a split scalar, and a body that ends in U+FFFD
    /// looks like corrupted output rather than a truncation.
    ///
    /// **What this leaves behind for the phone**: a `.toolCall`'s `text` is pretty-printed
    /// JSON, and this cuts wherever the cap lands — mid-object, mid-string, mid-escape — so a
    /// truncated tool input is no longer parseable. That is accepted rather than worked
    /// around (the alternative is dropping the tail to the last valid boundary, which throws
    /// away more of the input than the cap asked for), and it is stated on
    /// `TimelineItem.Body.text` because the client is where it has to be obeyed: render the
    /// text, never parse it.
    ///
    /// Only `text` is cut. `summary` is bounded at its source instead — see `cost(of:)`.
    private static func capped(_ item: TimelineItem) -> TimelineItem {
        let total = item.body.text.utf8.count
        guard total > TimelineLimits.maxItemBytes else { return item }
        var kept = ""
        var bytes = 0
        for character in item.body.text {
            let width = String(character).utf8.count
            if bytes + width > TimelineLimits.maxItemBytes { break }
            kept.append(character)
            bytes += width
        }
        var item = item
        item.body.text = kept
        item.body.truncatedBytes = total - bytes
        return item
    }

    /// What a record costs against the page budget, **stated as a rule rather than a list**
    /// because the list will grow: every `Body` field whose length the SOURCE RECORD decides.
    /// Today that is `text` and `summary`. It is not `tool`, `callID` or `at`, which are the
    /// agent's own short identifiers, and a new field is in this sum if a long enough record
    /// can make it long.
    ///
    /// `summary` is why the rule is written down. It is bounded at its source
    /// (`ToolInputSummary.maxSummaryBytes`) and NOT by `capped` above, so it escapes the
    /// per-item cap entirely — counting only `text` would let 200 previews add 40 KB to a page
    /// that reported itself inside a 128 KB budget.
    ///
    /// Counted after `capped`, so the budget measures what actually goes on the wire.
    private static func cost(of items: [TimelineItem]) -> Int {
        items.reduce(0) { $0 + $1.body.text.utf8.count + ($1.body.summary?.utf8.count ?? 0) }
    }

    /// Keeps records until the bodies exceed the page budget — **but never returns none.**
    ///
    /// The `isEmpty` check is the whole point of this function existing separately. Without
    /// it, one record whose items outweigh the budget produces an empty page with the same
    /// cursor the client already had, and backwards paging stalls on that record forever with
    /// no way past it. One oversized page beats a conversation with an impassable wall in it.
    ///
    /// It takes a multi-item record to reach that: `maxItemBytes` is half of `maxPageBytes`,
    /// so no single item can outweigh the budget alone — three 64 KB text blocks in one
    /// assistant record can, and that is an ordinary long reply rather than a pathological
    /// file.
    private static func withinBudget(
        _ records: [(line: SourceLine, items: [TimelineItem])], droppingFromOldest: Bool
    ) -> [(line: SourceLine, items: [TimelineItem])] {
        var kept: [(line: SourceLine, items: [TimelineItem])] = []
        var bytes = 0
        for record in droppingFromOldest ? records.reversed() : records {
            let cost = cost(of: record.items)
            if bytes + cost > TimelineLimits.maxPageBytes, !kept.isEmpty { break }
            bytes += cost
            kept.append(record)
        }
        return droppingFromOldest ? kept.reversed() : kept
    }
}
