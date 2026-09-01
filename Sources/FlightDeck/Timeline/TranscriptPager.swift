import FleetKit
import Foundation

/// One line of a transcript, and where it was.
///
/// The offset is what makes an item addressable — `TimelineItem.id` is built from it — so it
/// travels with the text rather than being recomputed by whoever consumes the page. The text
/// is the line's bytes verbatim, minus only the `\n` that ended it: a stray `\r` stays, both
/// because `TailReader` leaves one alone for the same file and because JSON treats it as
/// whitespace, so the mapper downstream never sees the difference.
struct SourceLine: Equatable, Sendable {
    let offset: Int
    let text: String
}

/// One look at a byte range of a transcript.
struct TranscriptPage: Equatable, Sendable {
    var lines: [SourceLine] = []
    /// The offset of the first line's boundary. `.before(start)` is the next page up.
    ///
    /// **Not necessarily `lines.first?.offset`.** A blank line is a boundary that carries no
    /// record, so a page whose oldest boundary is one starts a byte before its first line.
    /// Carry this value through verbatim — recomputing it from the first item drops those
    /// bytes and reopens the gap the cursor exists to close.
    var start: Int
    /// The offset just past the last line. `.after(end)` picks up what has been appended.
    ///
    /// Always a line boundary — the byte after a `\n` — never the file size, because the
    /// writer appends while this reads and the file's last bytes are routinely half a record.
    var end: Int
    /// Whether there is more **in the direction that was asked for**, and safe to page on:
    /// false always means a request from this page's cursor would return nothing.
    ///
    /// Backwards that is `start > 0`. Forwards it is `end < size`, which is true only when
    /// records were left behind — a page that hands back nothing (`end == cursor`, the
    /// ordinary state of a file whose last record is still being written) reports false, so
    /// a client that pages while `hasMore` cannot spin re-issuing the identical request on
    /// every poll. Forwards progress comes from being told the file changed, not from this.
    var hasMore: Bool
    /// The file this cursor came from is gone. See `TimelinePage.reset`.
    var reset: Bool = false
}

/// Reads an arbitrary byte window of an append-only JSONL file, backwards or forwards.
///
/// Agent-agnostic and JSON-free on purpose: the byte arithmetic is the part that is easy to
/// get subtly wrong and impossible to eyeball, so it is separated from anything that would
/// need a fixture to exercise. `TimelineReader` composes this with a mapper.
///
/// Not `TailReader`, and not an extension of it: that type is a forward-only tail with a
/// caller-held `offset` and a truncation policy, which is the right shape for a watcher and
/// cannot seek backwards. Three of its hard-won rules are reproduced here because they are
/// properties of the file rather than of the tail — never consume a trailing partial line,
/// treat a shrinking file as a replacement, and decide where a read starts explicitly.
enum TranscriptPager {
    /// `nil` means the file could not be read as a transcript: it would not open — which for
    /// a claude tab before its first turn is the ordinary state, not an error — or it opened
    /// and holds no line boundary to page from. Neither may be rendered as an empty
    /// conversation. A file that opens and holds *nothing* is an empty page, not `nil`; see
    /// `lastBoundary`.
    ///
    /// `window` and `maxScan` are parameters so tests can use values small enough to write
    /// a fixture across; production takes both from `TimelineLimits`.
    ///
    /// **An anchor arrives from the phone and is executed, so both its bounds are checked
    /// here.** `TimelineAnchor` decodes a cursor as a plain `Int` with no floor, and a
    /// negative one reaches a `UInt64` conversion that *traps* — `try?` does not catch a
    /// trap, so an unchecked cursor is a remote kill of the Mac app, not a wrong answer.
    static func page(
        url: URL,
        anchor: TimelineAnchor,
        limit: Int,
        window: Int = TimelineLimits.window,
        maxScan: Int = TimelineLimits.window * 16
    ) -> TranscriptPage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)

        // A limit of zero or less cannot make progress: no lines come back and the cursor
        // does not move, so a client paging while `hasMore` would re-issue the identical
        // request forever. Clamped up rather than refused, and clamped HERE rather than at
        // the caller: `TimelineLimits.maxLimit` describes clamping a greedy client *down*,
        // and the natural `min(limit, maxLimit)` leaves 0 and -1 exactly as they were. Same
        // rule `maxPageBytes` states for pages — always emit at least one record.
        let limit = max(1, limit)

        switch anchor {
        case .latest:
            // `nil` rather than a boundary of 0: a file with no line boundary in it is not a
            // transcript this can page, and the empty page is already spoken for. See
            // `lastBoundary`.
            guard let boundary = lastBoundary(handle, size: size, window: window, maxScan: maxScan)
            else { return nil }
            return backwards(handle, from: boundary, limit: limit,
                             window: window, maxScan: maxScan)
        // `0...size`, so a cursor exactly at the end is a client that is up to date rather
        // than one holding a stale cursor: there is a real page above it, and `.after` of it
        // is legitimately empty.
        case .before(let cursor):
            guard (0...size).contains(cursor) else { return reset(at: size) }
            return backwards(handle, from: cursor, limit: limit, window: window, maxScan: maxScan)
        case .after(let cursor):
            guard (0...size).contains(cursor) else { return reset(at: size) }
            return forwards(handle, from: cursor, size: size, limit: limit,
                            window: window, maxScan: maxScan)
        // `.before` and `.after` back to back about one pivot, not a third reading path.
        // `forwards(from: cursor)` already includes the record that BEGINS at `cursor` — the
        // same record `backwards(from: cursor)` stops immediately short of, because its
        // window only ever covers bytes strictly before `cursor` — so the pivot is owned by
        // the forward half alone and appears exactly once. Splitting `limit` unevenly in the
        // forward half's favour (`limit - limit / 2` against `limit / 2`) is what keeps the
        // pivot itself inside the count for a `limit` of 1, where the backward half's share
        // of records to KEEP is zero.
        case .around(let cursor):
            guard (0...size).contains(cursor) else { return reset(at: size) }
            let share = limit / 2
            // `backwards` documents its own precondition as `limit` already clamped to at
            // least 1 by `page` — it needs one full boundary to prove a line is whole, even
            // to answer "is there anything here at all". A `share` of zero would break that
            // precondition and come back `hasMore: false` unconditionally, which is a lie the
            // moment something actually precedes the pivot: `TranscriptPage.hasMore` documents
            // backwards as meaning exactly `start > 0`, and `.around` owes it the same meaning.
            // So the probe always asks for at least one boundary; only what gets KEPT is
            // limited to `share`.
            let probe = backwards(handle, from: cursor, limit: max(1, share),
                                  window: window, maxScan: maxScan)
            let earlier = share > 0 ? probe : TranscriptPage(
                start: cursor, end: cursor,
                // The probe's own record is not kept — the pivot's half of the budget claimed
                // none — but finding one at all is proof something precedes the pivot, which
                // is the only question being asked at `share == 0`.
                hasMore: !probe.lines.isEmpty
            )
            let later = forwards(handle, from: cursor, size: size, limit: limit - share,
                                 window: window, maxScan: maxScan)
            return TranscriptPage(
                lines: earlier.lines + later.lines,
                start: earlier.start,
                end: later.end,
                // What precedes `start` — the merged page's oldest boundary is the backward
                // half's own, so its `hasMore` already answers the merged question.
                hasMore: earlier.hasMore
            )
        }
    }

    /// A cursor that is not an offset into this file. Past the end means the transcript was
    /// truncated or replaced by a shorter one, so every byte offset the client holds now
    /// names a different record; below zero means a cursor no page ever handed out. Both get
    /// the same answer, because both leave the client's offsets meaningless.
    ///
    /// A shrink is the only replacement this can see, and that gap is `TailReader`'s too: a
    /// same-size-or-larger file at the same path reads as an ordinary continuation. Closing
    /// it would mean a cursor that carried an identity — inode, or size at issue — and
    /// `TimelineAnchor` is documented as a plain byte offset the client only ever echoes.
    private static func reset(at size: Int) -> TranscriptPage {
        // No lines and no `hasMore`: the client's next move is to discard and re-fetch
        // `.latest`, not to page from a cursor that has already been declared meaningless.
        TranscriptPage(start: size, end: size, hasMore: false, reset: true)
    }

    private static let newline = UInt8(ascii: "\n")

    /// The offset just past the file's last newline — the end of the last COMPLETE line.
    ///
    /// Not the file size. The writer appends while this reads, so a read can land mid-write,
    /// and treating the size as a boundary hands a client half a record and then moves the
    /// cursor past it, losing that record for good.
    ///
    /// Bounded like every other scan here: a file whose last `maxScan` bytes hold no newline
    /// at all is not a JSONL transcript this can page, and answering "nothing" beats reading
    /// backwards through a gigabyte to prove it.
    ///
    /// **`nil` when there is no boundary to find**, which is the answer `TimelineReader` maps
    /// to `unreadable` — showable and retryable. Returning 0 instead would make an unpageable
    /// file byte-identical to an empty one — no lines, `start` and `end` 0, `hasMore` and
    /// `reset` false — so a client would render "this conversation is empty" over history it
    /// simply could not reach, with nothing to retry and nothing to log. The cost of `nil` is
    /// that it folds together with "there is no transcript file yet"; both render as "no
    /// history", and neither states falsely and unretryably that the conversation is empty.
    ///
    /// A file of zero bytes is the one honest 0: it has no records, and offset 0 is the only
    /// position it has.
    private static func lastBoundary(
        _ handle: FileHandle, size: Int, window: Int, maxScan: Int
    ) -> Int? {
        var end = size
        while end > 0, size - end < maxScan {
            let start = max(0, end - window)
            guard let data = read(handle, from: start, count: end - start) else { return nil }
            if let index = data.lastIndex(of: newline) {
                return start + data.distance(from: data.startIndex, to: index) + 1
            }
            end = start
        }
        return size == 0 ? 0 : nil
    }

    /// Reads backwards in window-sized chunks until it holds `limit + 1` line boundaries, or
    /// reaches the start of the file, or exceeds `maxScan`.
    ///
    /// `limit + 1`, not `limit`: the extra boundary is what proves the oldest line in the
    /// buffer is whole rather than a fragment the window happened to cut.
    private static func backwards(
        _ handle: FileHandle, from end: Int, limit: Int, window: Int, maxScan: Int
    ) -> TranscriptPage {
        // The top of the file. `limit` is clamped to at least 1 by `page`, and `suffix(limit)`
        // below is safe for any value it did not clamp, so no branch here can hand back a
        // page that reports more while offering no way to reach it.
        guard end > 0, limit > 0 else {
            return TranscriptPage(start: end, end: end, hasMore: false)
        }
        var scanned = end
        var buffer = Data()
        var boundaries = 0
        while scanned > 0, boundaries <= limit, buffer.count < maxScan {
            let chunkStart = max(0, scanned - window)
            // A short read would leave a hole between the chunk and the buffer it is being
            // prepended to, and every offset after it would be wrong by the size of the
            // hole. Stopping with what is already known to be contiguous is the only safe
            // answer; the page simply comes back shorter.
            guard let chunk = read(handle, from: chunkStart, count: scanned - chunkStart),
                  chunk.count == scanned - chunkStart
            else { break }
            boundaries += chunk.reduce(into: 0) { $0 += $1 == newline ? 1 : 0 }
            buffer = chunk + buffer
            scanned = chunkStart
        }

        // Where a whole line can start inside the buffer: one past every newline in it, plus
        // byte 0 itself but ONLY when the scan reached the top of the file. Anything else at
        // the front is the record the window cut through, and returning it would hand a
        // client a fragment with an offset that says it is whole.
        let breaks = newlines(in: buffer)
        guard let last = breaks.last else {
            return TranscriptPage(start: end, end: end, hasMore: false)
        }
        let pageEnd = scanned + last + 1
        var starts = breaks.map { scanned + $0 + 1 }.filter { $0 < pageEnd }
        if scanned == 0 { starts.insert(0, at: 0) }

        // The scan spent its whole budget inside one record without reaching a line that
        // starts within it. Report nothing further reachable rather than inviting a retry
        // that will make the same journey — and rather than reading an unbounded file into
        // memory, which is the alternative.
        guard let first = starts.suffix(limit).first else {
            return TranscriptPage(start: end, end: end, hasMore: false)
        }
        let lines = split(buffer.dropFirst(first - scanned).prefix(pageEnd - first), from: first)
        return TranscriptPage(lines: lines, start: first, end: pageEnd, hasMore: first > 0)
    }

    /// Reads forward from a cursor, which is always a boundary a previous page handed out.
    ///
    /// No guard on `cursor == size` or on a degenerate `limit`: the loop below runs zero
    /// times for the first and the cut is written to be safe for the second, so both fall out
    /// as the same empty, `hasMore`-false page rather than as a branch that has to agree with
    /// one thirty lines away.
    private static func forwards(
        _ handle: FileHandle, from cursor: Int, size: Int, limit: Int, window: Int, maxScan: Int
    ) -> TranscriptPage {
        var buffer = Data()
        var scanned = cursor
        var boundaries = 0
        // Widens only while nothing whole has been found — one window covers any ordinary
        // page. It is the same progress rule `backwards` uses, for the mirror-image reason:
        // a record larger than the window would otherwise pin the cursor in front of itself
        // forever, with every poll rereading the same bytes and returning nothing.
        while scanned < size, boundaries == 0, buffer.count < maxScan {
            guard let chunk = read(handle, from: scanned, count: min(window, size - scanned))
            else { break }
            boundaries += chunk.reduce(into: 0) { $0 += $1 == newline ? 1 : 0 }
            buffer += chunk
            scanned += chunk.count
        }

        let breaks = newlines(in: buffer)
        guard !breaks.isEmpty else {
            // No complete record here: the cursor is at the end, or the writer is mid-record,
            // or the record is longer than the scan budget. `hasMore` is false for all three
            // because all three hand back nothing — and the middle one is the ORDINARY state
            // of a file being written, so reporting more here would have a client re-issuing
            // the identical request on every poll for as long as claude takes to finish a
            // record. It also keeps this indistinguishable-to-the-client state from being
            // answered two different ways.
            return TranscriptPage(start: cursor, end: cursor, hasMore: false)
        }
        // Cut at the `limit`-th newline rather than trimming decoded lines: `end` is then
        // byte arithmetic all the way down, and cannot drift when a line's bytes and its
        // String's bytes disagree — which they do the moment a record is not valid UTF-8 and
        // decoding substitutes U+FFFD.
        //
        // `max(1, limit)` is the "at least one record" floor, held HERE rather than borrowed
        // from `page`'s clamp, because this is the expression that would die: a negative
        // limit traps `prefix` ("Can't take a prefix of negative length") and underflows a
        // subscript, and neither is a thing to leave to a guard in another function. Clamped
        // against `breaks.count` on the other side, so the index is always in range.
        let end = cursor + breaks[min(max(1, limit), breaks.count) - 1] + 1
        return TranscriptPage(
            lines: split(buffer.prefix(end - cursor), from: cursor),
            start: cursor, end: end,
            // Exact when records were dropped for the limit or the window stopped short.
            // Also true when all that remains is a partial line, which costs the client one
            // empty round trip — once, not once per poll, because that empty page reports
            // false. See `hasMore`.
            hasMore: end < size
        )
    }

    private static func read(_ handle: FileHandle, from offset: Int, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        // `UInt64(offset)` TRAPS on a negative offset, and `try?` does not catch a trap. The
        // cursor that reaches here started as an `Int` on the wire, so the conversion is
        // checked; `page`'s bounds guard means this can only fire if a future caller finds
        // another way in.
        guard let start = UInt64(exactly: offset) else { return nil }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else { return nil }
        return data
    }

    /// Positions of every newline, relative to the start of `data`. Counted rather than
    /// subscripted so a `Data` slice's non-zero indices cannot leak into an offset.
    private static func newlines(in data: Data) -> [Int] {
        var found: [Int] = []
        var index = 0
        for byte in data {
            if byte == newline { found.append(index) }
            index += 1
        }
        return found
    }

    /// Splits on newlines, carrying each line's absolute offset. Empty lines are dropped —
    /// a JSONL file's blank line carries no record — but their bytes still advance the
    /// offset, which is why this counts rather than joining.
    private static func split(_ data: Data, from base: Int) -> [SourceLine] {
        var lines: [SourceLine] = []
        var offset = base
        for piece in data.split(separator: newline, omittingEmptySubsequences: false) {
            let text = String(decoding: piece, as: UTF8.self)
            if !text.isEmpty { lines.append(SourceLine(offset: offset, text: text)) }
            offset += piece.count + 1
        }
        // `omittingEmptySubsequences: false` yields a trailing empty piece for data that ends
        // in a newline, which the emptiness check above already dropped. What it does NOT
        // drop is a final piece with no newline after it — and every caller here has already
        // cut its buffer at a boundary, so that case cannot arise.
        return lines
    }
}
