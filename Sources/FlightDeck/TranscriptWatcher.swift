import Foundation

/// Tails one session's Claude transcript and reports the newest `customTitle`.
///
/// `claude` creates the transcript slightly after launch, so the watcher polls for the
/// file and only then starts reading. Reads are incremental: only bytes appended since
/// the last read are parsed. A missing file is not an error — it just means `claude`
/// isn't running, and the sidebar name stays a local label.
///
/// **Threading.** The read and the JSON parse are the expensive half and do not touch
/// actor state, so `poll()` runs them off the main actor and hops back only to apply the
/// result. That split matters because transcript lines are large — one assistant record
/// carries entire tool inputs and results — and the parse used to land on the main thread
/// at exactly the moment an agent was streaming output. `drain()` keeps the whole thing
/// synchronous for tests.
///
/// **Scheduling.** This type owns no timer. `SessionStore` drives every watcher from a
/// single `WatchClock`, so N tabs cost one wakeup rather than N — see that type.
@MainActor
final class TranscriptWatcher {
    private let sessionID: UUID
    /// Readable so `SessionStore` can expose which transcript a tab is actually tailing
    /// (`watchedTranscriptURL(of:)`); immutable, so a watcher is replaced rather than
    /// re-pointed when the tab's conversation or transcript directory changes. Those are
    /// the only two things that move a transcript: the project a tab is filed under does
    /// not feed this path at all, and `SessionStore.moveSession` deliberately leaves
    /// watchers alone.
    let url: URL
    private let onTitle: (String) -> Void
    private let onSubagentCount: (Int) -> Void
    /// Reports conversation text to the search index. A genuine optional, not a defaulted
    /// no-op: `Scan.read` checks `onMessages != nil` and skips
    /// `TranscriptExtractor.messages(inObject:)` entirely when nothing is subscribed, so a
    /// watcher built without it truly does no extra work rather than building an array
    /// nobody reads.
    private let onMessages: (([IndexedMessage]) -> Void)?

    /// Outstanding top-level `Agent` tool_use ids. Cleared at every turn boundary, which
    /// is what makes a miscount from attaching mid-turn self-correcting rather than
    /// permanent.
    private var outstandingAgents: Set<String> = []

    private var offset: UInt64 = 0
    /// Whether the position to start reading from has been decided yet. See `Scan.read`.
    private var hasChosenStart = false

    /// The clock this watcher is registered with, if any. Nil in tests, which call
    /// `drain()` directly.
    private weak var clock: WatchClock?
    private var isPolling = false

    /// `onSubagentCount` defaults to a no-op so title-only call sites are unaffected.
    /// `onMessages` defaults to nil rather than a no-op closure — see the property above —
    /// so its absence is something `Scan.read` can observe and act on.
    init(
        sessionID: UUID,
        url: URL,
        clock: WatchClock? = nil,
        onTitle: @escaping (String) -> Void,
        onSubagentCount: @escaping (Int) -> Void = { _ in },
        onMessages: (([IndexedMessage]) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.url = url
        self.clock = clock
        self.onTitle = onTitle
        self.onSubagentCount = onSubagentCount
        self.onMessages = onMessages
    }

    func start() {
        clock?.add(self) { [weak self] in self?.poll() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// One scheduled pass: reads and parses off the main actor, applies on it.
    ///
    /// Re-entrancy is guarded rather than queued. A pass that outlives its tick means the
    /// file is big enough that the *next* tick has nothing useful to add — it would read
    /// from a stale offset — so dropping it is both cheaper and more correct than letting
    /// two passes interleave over one `offset`.
    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        let url = self.url
        let sessionID = self.sessionID
        let offset = self.offset
        let hasChosenStart = self.hasChosenStart
        let wantsMessages = onMessages != nil

        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                Scan.read(
                    url: url,
                    offset: offset,
                    hasChosenStart: hasChosenStart,
                    sessionID: sessionID,
                    wantsMessages: wantsMessages
                )
            }.value

            guard let self else { return }
            self.apply(scan)
            self.isPolling = false
        }
    }

    /// Reads everything appended since the last call and reports the last title found.
    /// Synchronous so tests need no expectations.
    func drain() {
        apply(
            Scan.read(
                url: url,
                offset: offset,
                hasChosenStart: hasChosenStart,
                sessionID: sessionID,
                wantsMessages: onMessages != nil
            )
        )
    }

    /// Folds a scan's events into the watcher's state and fires the callbacks.
    /// Everything here is cheap and main-actor-bound; the expensive half is `Scan.read`.
    private func apply(_ scan: Scan) {
        hasChosenStart = scan.hasChosenStart
        offset = scan.offset

        var lastTitle: String?
        var countChanged = false

        for event in scan.events {
            switch event {
            case .title(let title):
                lastTitle = title
            case .agentStarted(let id):
                if outstandingAgents.insert(id).inserted { countChanged = true }
            case .agentFinished(let id):
                if outstandingAgents.remove(id) != nil { countChanged = true }
            case .turnEnded:
                if !outstandingAgents.isEmpty {
                    outstandingAgents.removeAll()
                    countChanged = true
                }
            }
        }

        if let lastTitle { onTitle(lastTitle) }
        if countChanged { onSubagentCount(outstandingAgents.count) }
        if !scan.messages.isEmpty { onMessages?(scan.messages) }
    }
}

/// The result of one look at a transcript: how far reading got, and what it found.
///
/// Deliberately pure and `Sendable` — no actor state, no callbacks — so the read and the
/// JSON parse can run off the main actor and only the fold back into watcher state has to
/// return to it.
struct Scan: Sendable {
    var offset: UInt64
    var hasChosenStart: Bool
    var events: [ClaudeSession.TranscriptEvent] = []
    /// Conversation text found in this pass, for the search index.
    ///
    /// Collected here rather than in a second reader because this pass has already paid for
    /// the two expensive parts — the file read and the JSON parse — and transcript lines are
    /// large enough (a single assistant record carries whole tool inputs and results) that
    /// doing either of them twice would be the most expensive thing in the app.
    var messages: [IndexedMessage] = []

    /// Reads and parses everything appended after `offset`.
    ///
    /// Returns the caller's own position unchanged when there is nothing to do (no new
    /// bytes, no complete line), which makes "no change" a cheap no-op rather than a
    /// special case at the call site.
    ///
    /// `wantsMessages` gates `TranscriptExtractor.messages(inObject:)`, not just whether
    /// `messages` ends up read: without the gate a watcher with no `onMessages` subscriber
    /// would still pay for extraction on every line, for nothing. Each line is JSON-decoded
    /// exactly once regardless — `ClaudeSession.events(inObject:)` and
    /// `TranscriptExtractor.messages(inObject:)` both take the same already-parsed object,
    /// rather than each re-parsing the line themselves.
    static func read(
        url: URL,
        offset: UInt64,
        hasChosenStart: Bool,
        sessionID: UUID,
        wantsMessages: Bool
    ) -> Scan {
        let tail = TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart)
        var result = Scan(offset: tail.offset, hasChosenStart: tail.hasChosenStart)
        for line in tail.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            result.events += ClaudeSession.events(inObject: obj, sessionID: sessionID)
            if wantsMessages {
                result.messages += TranscriptExtractor.messages(
                    inObject: obj, conversationID: sessionID.uuidString.lowercased()
                )
            }
        }
        return result
    }
}
