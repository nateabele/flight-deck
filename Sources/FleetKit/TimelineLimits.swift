import Foundation

/// Every size this feature is bounded by, in one place, so the whole budget can be read at
/// once and a change moves one line rather than five.
///
/// The numbers are a phone's budget, not a terminal's: a page is bulk transfer over a
/// possibly-cellular link, and the spec (§6) is explicit that history "must not be pushed
/// unasked". These are what "asked for" costs.
public enum TimelineLimits {
    /// Per-item body cap. Beyond this the text is cut and `Body.truncatedBytes` records what
    /// was dropped, so a client can say "showing the first 64 KB of 210 KB" rather than
    /// silently presenting a partial file read as a whole one.
    public static let maxItemBytes = 65_536

    /// A page stops accumulating records once the bodies it already holds exceed this — but
    /// never before it holds one. See `TimelineReader`: a page that can come back empty
    /// because its first record is oversized makes backwards pagination stall forever on
    /// that record, with no way for a client to get past it.
    public static let maxPageBytes = 131_072

    /// Source **records** per page, not items: one assistant record can carry text, thinking
    /// and three tool calls, so `TimelinePage.items.count` is routinely larger than this.
    public static let defaultLimit = 40

    /// A client asking for more is clamped rather than refused — a limit is a hint about
    /// what a screen wants, and refusing the request would turn a mildly greedy client into
    /// a broken one.
    public static let maxLimit = 200

    /// Bytes read per pager pass. A page whose `limit` records do not fit in one window
    /// comes back short; the client simply pages again from the cursor it was given.
    public static let window = 524_288

    /// The WebSocket receive cap, applied on both ends.
    ///
    /// **`ws_options.h` documents the default as 0, which means no receive limit at all.**
    /// That was harmless while every frame was a snapshot or a status delta and is not now:
    /// this plan is the first thing to put bulk on the socket, and an unbounded frame is an
    /// unbounded allocation on a phone. Comfortably above `maxPageBytes` even after JSON
    /// escaping doubles a worst-case body.
    public static let maximumMessageSize = 4_194_304
}
