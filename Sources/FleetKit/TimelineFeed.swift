import Foundation

/// What a session screen holds while it pages, as a value type.
///
/// In `FleetKit` rather than in the phone app for the reason `FleetModel`'s doc comment
/// gives: the iOS target's suite runs only on a booted simulator, so anything worth testing
/// belongs where the macOS unit suite can reach it too. This is the part worth testing — the
/// merge, the dedupe, and the two cursors — and the app's `@Observable` shell over it is
/// glue. The same division `FleetSnapshot.apply(_:)` and `FleetModel` already use.
///
/// **The failure this type exists to prevent is a phone that silently skips a record or
/// shows one twice.** Both look like rendering bugs and neither is one, so all four
/// invariants live here where a test can hold them: items are ordered oldest-first whatever
/// order the pages arrived in, an id is held once, each cursor only ever widens, and
/// `hasOlder` is only ever answered by a page fetched upwards.
///
/// **It holds no `seq` and must never be wired to one.** A `TimelinePage` carries none
/// (`TimelineFrames`), and the resume point a reconnect uses belongs to `FleetConnector`'s
/// event stream. Scrolling up is a history read; it cannot move where a reconnect resumes.
public struct TimelineFeed: Equatable, Sendable {
    /// **Oldest first, always** — `items[0]` is the top of the screen and `items.last` is the
    /// newest thing the agent said — whichever direction the page that delivered them was
    /// fetched in. `TimelinePage.items` arrives in file order for every anchor, including
    /// `.before`, so a merge never has to reverse anything; what it has to do is put an older
    /// page's items *above* what is already held rather than below.
    public private(set) var items: [TimelineItem] = []

    /// The `start` of the oldest page held. `nil` until something is loaded.
    ///
    /// **A pager boundary, carried verbatim, never derived from `items.first`.** When the
    /// oldest boundary in a page is a blank line, `start` names the blank and the first
    /// record begins a byte later — so recomputing this from an item's own offset shifts the
    /// cursor past that byte, and the next page up never returns the record behind it.
    /// `TranscriptPage.start` and `TimelineReader` refuse the same arithmetic in the same
    /// words, and this is the third and last place it could have crept back in.
    public private(set) var oldest: Int?

    /// The `end` of the newest page held — the offset just past the last record, and a line
    /// boundary. `nil` until something is loaded. Verbatim, for the reason `oldest` gives.
    public private(set) var newest: Int?

    /// Whether anything precedes `oldest`.
    ///
    /// **Purely about the TOP of the feed.** `TimelinePage.hasMore` reports only the
    /// direction its page was fetched in, so a page arriving at the bottom says nothing about
    /// this and letting one overwrite it is how a feed starts offering to load older items
    /// above a top it has already reached.
    public private(set) var hasOlder = false

    public init() {}

    /// Whether anything has been fetched at all. Distinguishes "still loading" from "this
    /// conversation is empty", which are the same empty `items` and two different screens.
    ///
    /// True after the first non-`reset` merge even when that page carried no items: a page
    /// always carries cursors, and an empty first page is a real answer about a real file.
    public var hasLoadedAnything: Bool { oldest != nil }

    /// What to ask for to page up. `nil` when nothing has been loaded — the screen asks for
    /// `.latest` then — and the screen must also check `hasOlder` before using it, because a
    /// feed sitting at the top of the transcript still has a perfectly good `oldest`.
    public var olderAnchor: TimelineAnchor? { oldest.map { .before($0) } }

    /// What to ask for to pick up whatever has been appended. `.latest` before anything is
    /// loaded, which is exactly what opening a session wants.
    ///
    /// There is deliberately no `hasNewer` beside `hasOlder`. Forwards, `hasMore` is a fact
    /// about the file *at the moment it was read* — false means "that request would return
    /// nothing right now", not "the conversation is over" — so a screen that stopped polling
    /// on it would stop following a live agent. Backwards it is a permanent fact about a
    /// file that only grows at the other end, which is why only that direction is stored.
    public var newerAnchor: TimelineAnchor { newest.map { .after($0) } ?? .latest }

    /// Fold one page in. Idempotent: merging the same page twice leaves the feed identical.
    public mutating func merge(_ page: TimelinePage) {
        // The transcript this feed's cursors came from is gone — truncated, or replaced. Item
        // ids ARE byte offsets, so every id held now names a different record: merging would
        // interleave two conversations under matching ids, which reads as corruption rather
        // than staleness. Discard everything, and let the screen start again from `.latest`
        // — which `newerAnchor` answers by itself once `newest` is nil again.
        guard !page.reset else {
            self = TimelineFeed()
            return
        }

        // Both decided BEFORE the cursors widen, and decided from the CURSORS rather than
        // from the items: an empty page carries nothing to compare and is the ordinary result
        // of a poll that found no new records.
        let isFirstPage = !hasLoadedAnything
        let isOlder = oldest.map { page.start < $0 } ?? false

        items = Self.merging(items, page.items)

        // Each cursor only ever widens. A page fetched above must not drag `newest` back, and
        // one fetched below must not drag `oldest` forward — either would have the next fetch
        // re-request a range the feed already holds, forever.
        oldest = min(oldest ?? page.start, page.start)
        newest = max(newest ?? page.end, page.end)

        // Believed only for a page fetched upwards, or for the very first page, which is also
        // the top of everything the feed knows. See `hasOlder`.
        if isOlder || isFirstPage { hasOlder = page.hasMore }
    }

    /// Two lists of items in file order, folded into one, in file order, with an id held once.
    ///
    /// **A merge by position, not a prepend or an append.** Prepending an older page and
    /// appending a newer one is right for the two anchors a screen actually issues, and it is
    /// silently wrong the moment a third page lands between two ranges already held — a reply
    /// arriving out of order, or a `.latest` fetched over a feed that had scrolled away from
    /// the bottom. The result there is the conversation's beginning underneath its end, which
    /// on screen reads as the agent answering before it was asked and gets chased in the view
    /// layer. Ordering by where each record IS costs one linear pass and cannot be wrong.
    ///
    /// Linear in what is held, which matters because the poll merges into this every couple
    /// of seconds and a long session runs to thousands of items.
    private static func merging(
        _ held: [TimelineItem], _ page: [TimelineItem]
    ) -> [TimelineItem] {
        guard !page.isEmpty else { return held }
        // `TimelinePage.items` is documented as file order for every anchor, so this sort is
        // ordinarily a no-op. It is here because the alternative to re-establishing the
        // precondition is assuming it: a page that ever arrived out of order would leave
        // `items` permanently unsorted, and every merge after it wrong. Bounded by
        // `TimelineLimits.maxLimit` records, so the cost is not on the poll's critical path.
        let incoming = page.sorted { order(of: $0.id) < order(of: $1.id) }
        guard !held.isEmpty else { return incoming }

        var merged: [TimelineItem] = []
        merged.reserveCapacity(held.count + incoming.count)
        var h = held.startIndex
        var i = incoming.startIndex
        while h < held.endIndex, i < incoming.endIndex {
            let there = order(of: held[h].id)
            let here = order(of: incoming[i].id)
            if there < here {
                merged.append(held[h])
                h += 1
            } else if here < there {
                merged.append(incoming[i])
                i += 1
            } else if held[h].id == incoming[i].id {
                // Re-delivered. Replaced rather than skipped: a body cut short by one page's
                // budget and delivered whole by another must not lose to arrival order.
                merged.append(incoming[i])
                h += 1
                i += 1
            } else {
                // Same order key, different id — reachable only for two ids this build cannot
                // parse (see `order(of:)`). Keep both, held first, rather than dropping one.
                merged.append(held[h])
                h += 1
            }
        }
        merged.append(contentsOf: held[h...])
        merged.append(contentsOf: incoming[i...])
        return merged
    }

    /// Where a record sits in the file, from its id — `"<offset>#<index>"`, the one rule
    /// `TimelineItem.identifier(offset:index:)` states.
    ///
    /// **This is an ORDERING key and never a cursor.** It says which of two records comes
    /// first; it does not say where to read from next, and `oldest`/`newest` are the page's
    /// own boundaries precisely because an item's offset is not one. Sorting by it is safe
    /// where paging by it is not.
    ///
    /// An id this build cannot parse sorts last, next to whatever else it cannot parse. That
    /// case means a newer Mac changed the id format, which breaks ordering however it is
    /// handled; sorting rather than trapping keeps the same promise `TimelineItem.Kind`'s
    /// `.unknown` makes — a page from a newer Mac renders, badly, instead of nothing at all.
    private static func order(of id: String) -> (offset: Int, index: Int) {
        guard let hash = id.firstIndex(of: "#"),
              let offset = Int(id[id.startIndex..<hash]),
              let index = Int(id[id.index(after: hash)...])
        else { return (.max, .max) }
        return (offset, index)
    }
}
